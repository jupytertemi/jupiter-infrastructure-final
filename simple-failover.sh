#!/bin/bash
# Simple failover script - no bullshit

SERVICE=$1
ACTION=$2

if [ -z "$SERVICE" ] || [ -z "$ACTION" ]; then
    echo "Usage: $0 <service> <failover|failback>"
    echo "Services: signaling, coturn, frp, thingsboard"
    exit 1
fi

REGION="ap-southeast-2"

# Get instance IDs
PRIMARY=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${SERVICE}-primary" --query 'Reservations[0].Instances[0].InstanceId' --output text --region $REGION)
BACKUP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${SERVICE}-backup" --query 'Reservations[0].Instances[0].InstanceId' --output text --region $REGION)

if [ "$ACTION" == "failover" ]; then
    echo "Failing over $SERVICE..."
    echo "Stopping primary: $PRIMARY"
    aws ec2 stop-instances --instance-ids $PRIMARY --region $REGION
    
    echo "Starting backup: $BACKUP"
    aws ec2 start-instances --instance-ids $BACKUP --region $REGION
    
    echo "Waiting 30s for startup..."
    sleep 30
    
    echo "Failover complete"
    
elif [ "$ACTION" == "failback" ]; then
    echo "Failing back $SERVICE..."
    echo "Stopping backup: $BACKUP"
    aws ec2 stop-instances --instance-ids $BACKUP --region $REGION
    
    echo "Starting primary: $PRIMARY"
    aws ec2 start-instances --instance-ids $PRIMARY --region $REGION
    
    echo "Waiting 30s for startup..."
    sleep 30
    
    echo "Failback complete"
else
    echo "Invalid action. Use 'failover' or 'failback'"
    exit 1
fi

# Show status
aws ec2 describe-instances --instance-ids $PRIMARY $BACKUP --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],InstanceId,State.Name]' --output table --region $REGION