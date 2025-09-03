#!/bin/bash
# CRON-BASED FAILOVER - Runs every minute to check health

REGION="ap-southeast-2"

check_and_failover() {
    SERVICE=$1
    
    # Check if primary is running
    PRIMARY_STATE=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${SERVICE}-primary" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text --region $REGION 2>/dev/null)
    
    # Check if backup is running
    BACKUP_STATE=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${SERVICE}-backup" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text --region $REGION 2>/dev/null)
    
    # If primary is stopped/stopping and backup is stopped, start backup
    if [[ "$PRIMARY_STATE" == "stopped" || "$PRIMARY_STATE" == "stopping" ]] && [[ "$BACKUP_STATE" == "stopped" ]]; then
        echo "$(date): Primary $SERVICE is down, starting backup"
        BACKUP_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=${SERVICE}-backup" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text --region $REGION)
        aws ec2 start-instances --instance-ids $BACKUP_ID --region $REGION
    fi
}

# Check all services
for service in signaling coturn frp thingsboard; do
    check_and_failover $service
done