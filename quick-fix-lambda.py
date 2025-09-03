#!/usr/bin/env python3
"""
SIMPLIFIED LAMBDA - Just stop primary and start backup
No fancy parsing, just make it work
"""
import boto3
import json
import os

ec2 = boto3.client('ec2', region_name='ap-southeast-2')

def handler(event, context):
    print(f"Event: {json.dumps(event)}")
    
    # Try to get service name from anywhere in the event
    event_str = json.dumps(event).lower()
    
    services = ['signaling', 'coturn', 'frp', 'thingsboard']
    triggered_service = None
    
    for service in services:
        if service in event_str:
            triggered_service = service
            break
    
    if not triggered_service:
        print("No service found in event")
        return {'statusCode': 200, 'body': 'No service identified'}
    
    print(f"Failover triggered for: {triggered_service}")
    
    # Get the backup instance ID from environment
    backup_id = os.environ.get(f'BACKUP_{triggered_service.upper()}')
    if not backup_id:
        print(f"No backup ID for {triggered_service}")
        return {'statusCode': 404, 'body': f'No backup for {triggered_service}'}
    
    try:
        # Find and stop primary
        primary = ec2.describe_instances(
            Filters=[
                {'Name': 'tag:Name', 'Values': [f'{triggered_service}-primary']},
                {'Name': 'instance-state-name', 'Values': ['running']}
            ]
        )
        
        if primary['Reservations']:
            primary_id = primary['Reservations'][0]['Instances'][0]['InstanceId']
            print(f"Stopping primary: {primary_id}")
            ec2.stop_instances(InstanceIds=[primary_id])
        
        # Start backup
        print(f"Starting backup: {backup_id}")
        ec2.start_instances(InstanceIds=[backup_id])
        
        return {
            'statusCode': 200,
            'body': json.dumps(f'Failover complete for {triggered_service}')
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }