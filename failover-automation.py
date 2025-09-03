#!/usr/bin/env python3
"""
Simple failover automation for Jupiter infrastructure
No load balancers needed - just stop/start instances
"""
import boto3
import sys
import time

ec2 = boto3.client('ec2', region_name='ap-southeast-2')

def get_instance_id(tag_name):
    """Get instance ID by Name tag"""
    response = ec2.describe_instances(
        Filters=[
            {'Name': 'tag:Name', 'Values': [tag_name]},
            {'Name': 'instance-state-name', 'Values': ['running', 'stopped']}
        ]
    )
    if response['Reservations']:
        return response['Reservations'][0]['Instances'][0]['InstanceId']
    return None

def failover(service):
    """Failover from primary to backup"""
    primary = get_instance_id(f"{service}-primary")
    backup = get_instance_id(f"{service}-backup")
    
    if not primary or not backup:
        print(f"Error: Could not find instances for {service}")
        return False
    
    print(f"Failover {service}:")
    print(f"  Stopping primary: {primary}")
    ec2.stop_instances(InstanceIds=[primary])
    
    print(f"  Starting backup: {backup}")
    ec2.start_instances(InstanceIds=[backup])
    
    # Wait for backup to be running
    waiter = ec2.get_waiter('instance_running')
    print(f"  Waiting for {backup} to start...")
    waiter.wait(InstanceIds=[backup])
    
    print(f"  ✓ Failover complete for {service}")
    return True

def failback(service):
    """Failback from backup to primary"""
    primary = get_instance_id(f"{service}-primary")
    backup = get_instance_id(f"{service}-backup")
    
    if not primary or not backup:
        print(f"Error: Could not find instances for {service}")
        return False
    
    print(f"Failback {service}:")
    print(f"  Stopping backup: {backup}")
    ec2.stop_instances(InstanceIds=[backup])
    
    print(f"  Starting primary: {primary}")
    ec2.start_instances(InstanceIds=[primary])
    
    # Wait for primary to be running
    waiter = ec2.get_waiter('instance_running')
    print(f"  Waiting for {primary} to start...")
    waiter.wait(InstanceIds=[primary])
    
    print(f"  ✓ Failback complete for {service}")
    return True

def status():
    """Show status of all services"""
    services = ['signaling', 'coturn', 'frp', 'thingsboard', 'nat']
    
    print("\nService Status:")
    print("-" * 50)
    
    for service in services:
        primary = get_instance_id(f"{service}-primary")
        backup = get_instance_id(f"{service}-backup")
        
        if primary:
            p_state = ec2.describe_instances(InstanceIds=[primary])['Reservations'][0]['Instances'][0]['State']['Name']
        else:
            p_state = "not found"
            
        if backup:
            b_state = ec2.describe_instances(InstanceIds=[backup])['Reservations'][0]['Instances'][0]['State']['Name']
        else:
            b_state = "not found"
        
        # Special case for NAT which has different naming
        if service == 'nat' and not backup:
            backup = get_instance_id("nat-secondary")
            if backup:
                b_state = ec2.describe_instances(InstanceIds=[backup])['Reservations'][0]['Instances'][0]['State']['Name']
        
        print(f"{service:12} Primary: {p_state:10} Backup: {b_state:10}")
    
    print("-" * 50)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 failover-automation.py <command> [service]")
        print("Commands:")
        print("  status              - Show status of all services")
        print("  failover <service>  - Failover service to backup")
        print("  failback <service>  - Failback service to primary")
        print("  failover-all        - Failover all services")
        print("  failback-all        - Failback all services")
        print("\nServices: signaling, coturn, frp, thingsboard")
        sys.exit(1)
    
    command = sys.argv[1]
    
    if command == "status":
        status()
    elif command == "failover" and len(sys.argv) > 2:
        failover(sys.argv[2])
        status()
    elif command == "failback" and len(sys.argv) > 2:
        failback(sys.argv[2])
        status()
    elif command == "failover-all":
        for service in ['signaling', 'coturn', 'frp', 'thingsboard']:
            failover(service)
        status()
    elif command == "failback-all":
        for service in ['signaling', 'coturn', 'frp', 'thingsboard']:
            failback(service)
        status()
    else:
        print(f"Invalid command: {command}")
        sys.exit(1)