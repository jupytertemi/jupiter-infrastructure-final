import boto3
import json
import os
import time

ec2 = boto3.client('ec2')
elbv2 = boto3.client('elasticloadbalancing')

def handler(event, context):
    """
    Fixed failover handler that actually works
    """
    print(f"Received event: {json.dumps(event)}")
    
    # Parse SNS message
    try:
        sns_message = json.loads(event['Records'][0]['Sns']['Message'])
        alarm_name = sns_message.get('AlarmName', '')
        print(f"Alarm triggered: {alarm_name}")
    except:
        print("Failed to parse SNS message")
        return {'statusCode': 400, 'body': 'Invalid event format'}
    
    # Extract service name from alarm (e.g., "signaling-health-check" -> "signaling")
    service = alarm_name.split('-')[0]
    
    # Get environment variables
    backup_id = os.environ.get(f'BACKUP_{service.upper()}')
    target_group = os.environ.get(f'TG_{service.upper()}')
    
    if not backup_id:
        print(f"No backup instance found for {service}")
        return {'statusCode': 404, 'body': f'No backup for {service}'}
    
    try:
        # 1. Find primary instance
        primary_response = ec2.describe_instances(
            Filters=[
                {'Name': 'tag:Name', 'Values': [f'{service}-primary']},
                {'Name': 'instance-state-name', 'Values': ['running']}
            ]
        )
        
        if not primary_response['Reservations']:
            print(f"Primary instance for {service} not found or not running")
            return {'statusCode': 404, 'body': 'Primary not found'}
        
        primary_id = primary_response['Reservations'][0]['Instances'][0]['InstanceId']
        print(f"Found primary: {primary_id}")
        
        # 2. Stop primary instance
        print(f"Stopping primary instance {primary_id}")
        ec2.stop_instances(InstanceIds=[primary_id])
        
        # 3. Start backup instance
        print(f"Starting backup instance {backup_id}")
        ec2.start_instances(InstanceIds=[backup_id])
        
        # 4. Wait for backup to be running
        waiter = ec2.get_waiter('instance_running')
        print(f"Waiting for {backup_id} to be running...")
        waiter.wait(InstanceIds=[backup_id], WaiterConfig={'Delay': 10, 'MaxAttempts': 12})
        
        # 5. Update target group if exists
        if target_group:
            print(f"Updating target group {target_group}")
            
            # Deregister primary
            try:
                elbv2.deregister_targets(
                    TargetGroupArn=target_group,
                    Targets=[{'Id': primary_id}]
                )
                print(f"Deregistered {primary_id} from target group")
            except Exception as e:
                print(f"Failed to deregister primary: {e}")
            
            # Register backup
            try:
                # Get the port from target group
                tg_info = elbv2.describe_target_groups(TargetGroupArns=[target_group])
                port = tg_info['TargetGroups'][0]['Port']
                
                elbv2.register_targets(
                    TargetGroupArn=target_group,
                    Targets=[{'Id': backup_id, 'Port': port}]
                )
                print(f"Registered {backup_id} to target group on port {port}")
            except Exception as e:
                print(f"Failed to register backup: {e}")
        
        print(f"Failover complete for {service}")
        return {
            'statusCode': 200,
            'body': json.dumps(f'Failover complete for {service}')
        }
        
    except Exception as e:
        print(f"Failover failed: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Failover failed: {str(e)}')
        }