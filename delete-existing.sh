#!/bin/bash
set -euo pipefail

# Safe Deletion Script for Jupiter Production Infrastructure
# This script safely deletes existing manual infrastructure in dependency order
# while protecting development resources and providing comprehensive logging.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="ap-southeast-2"
ENVIRONMENT="prod"
LOG_FILE="/tmp/jupiter-deletion-$(date +%Y%m%d-%H%M%S).log"

# Critical resource protection - NEVER touch these
PROTECTED_PATTERNS=("jupiter-dev" "dev-" "development" "-dev" "test-" "-test")

# Known production resource IDs from extraction
KNOWN_PROD_INSTANCES=(
    "i-0f8e2200184c63d79"  # NAT Primary
    "i-062e7fdf899b8554b"  # NAT Secondary
    "i-0190e6ba8be9ce74e"  # FRP Primary
    "i-03df852442dab30b6"  # Signaling Primary
    "i-02a2d0a2f54935e39"  # CoTURN Primary
    "i-0533efff0632e9ae5"  # ThingsBoard Primary
    "i-0ca120477092fe234"  # FRP Backup
    "i-0e5ee075e7ff48a1c"  # Signaling Backup
    "i-0564013330e9d1d82"  # ThingsBoard Backup
    "i-0671810b57b99cdbe"  # CoTURN Backup
    "i-0efcd6b792dacc67e"  # NAT Backup
)

KNOWN_LOAD_BALANCERS=(
    "arn:aws:elasticloadbalancing:ap-southeast-2:390402573034:loadbalancer/app/prod-alb/015a587dac5d00ae"
    "arn:aws:elasticloadbalancing:ap-southeast-2:390402573034:loadbalancer/net/prod-nlb/1c52172f4ccbd103"
)

KNOWN_VPC_ID="vpc-0aacde99094554473"

# Logging functions
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }
warning() { log "WARNING" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

# Resource protection function
is_protected_resource() {
    local resource_name="$1"
    for pattern in "${PROTECTED_PATTERNS[@]}"; do
        if [[ "$resource_name" == *"$pattern"* ]]; then
            return 0  # Protected
        fi
    done
    return 1  # Not protected
}

# Confirmation function
confirm_deletion() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="${3:-N/A}"
    
    if is_protected_resource "$resource_name" || is_protected_resource "$resource_id"; then
        error "PROTECTED RESOURCE DETECTED: $resource_type $resource_id ($resource_name)"
        error "This resource matches a protection pattern and will NOT be deleted"
        return 1
    fi
    
    info "Planning to delete: $resource_type"
    info "  ID: $resource_id"
    info "  Name: $resource_name"
    return 0
}

# Wait for resource deletion
wait_for_deletion() {
    local check_command="$1"
    local resource_type="$2"
    local max_wait="${3:-300}"  # 5 minutes default
    
    info "Waiting for $resource_type deletion to complete..."
    local count=0
    while eval "$check_command" >/dev/null 2>&1; do
        if [ $count -ge $max_wait ]; then
            warning "$resource_type deletion timeout after ${max_wait}s"
            return 1
        fi
        sleep 10
        count=$((count + 10))
        info "Still waiting... (${count}s/${max_wait}s)"
    done
    success "$resource_type deleted successfully"
    return 0
}

# Pre-deletion safety checks
pre_deletion_checks() {
    info "=== PRE-DELETION SAFETY CHECKS ==="
    
    info "Verifying AWS credentials..."
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS CLI not configured"
        exit 1
    fi
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    info "AWS Account: $account_id"
    
    info "Scanning for development resources..."
    local dev_instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=dev,development,test" \
                  "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value}' \
        --output text)
    
    if [[ -n "$dev_instances" ]]; then
        warning "Development resources found:"
        echo "$dev_instances"
        warning "These will be PROTECTED from deletion"
    fi
    
    info "Identifying production resources for deletion..."
    local prod_instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
                  "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,State:State.Name}' \
        --output table)
    
    info "Production instances found:"
    echo "$prod_instances"
    
    success "Pre-deletion checks completed"
}

# Step 1: Remove instances from load balancer target groups
step1_deregister_targets() {
    info "=== STEP 1: DEREGISTER TARGETS FROM LOAD BALANCERS ==="
    
    # Get all target groups
    local target_groups=$(aws elbv2 describe-target-groups \
        --region "$AWS_REGION" \
        --query 'TargetGroups[?starts_with(TargetGroupName, `prod-`)].TargetGroupArn' \
        --output text)
    
    if [[ -z "$target_groups" ]]; then
        info "No production target groups found"
        return 0
    fi
    
    for tg_arn in $target_groups; do
        info "Processing target group: $tg_arn"
        
        # Get healthy targets
        local targets=$(aws elbv2 describe-target-health \
            --target-group-arn "$tg_arn" \
            --region "$AWS_REGION" \
            --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id' \
            --output text)
        
        if [[ -n "$targets" ]]; then
            for target_id in $targets; do
                local target_name=$(aws ec2 describe-instances \
                    --instance-ids "$target_id" \
                    --region "$AWS_REGION" \
                    --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' \
                    --output text 2>/dev/null || echo "unknown")
                
                if confirm_deletion "Target" "$target_id" "$target_name"; then
                    info "Deregistering target $target_id from target group"
                    aws elbv2 deregister-targets \
                        --target-group-arn "$tg_arn" \
                        --targets Id="$target_id" \
                        --region "$AWS_REGION"
                    success "Target $target_id deregistered"
                fi
            done
        else
            info "No healthy targets found in target group"
        fi
    done
    
    success "Target deregistration completed"
}

# Step 2: Stop all production instances
step2_stop_instances() {
    info "=== STEP 2: STOP PRODUCTION INSTANCES ==="
    
    local running_instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    
    if [[ -z "$running_instances" ]]; then
        info "No running production instances found"
        return 0
    fi
    
    for instance_id in $running_instances; do
        local instance_name=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' \
            --output text 2>/dev/null || echo "unknown")
        
        if confirm_deletion "Instance" "$instance_id" "$instance_name"; then
            info "Stopping instance: $instance_id ($instance_name)"
            aws ec2 stop-instances \
                --instance-ids "$instance_id" \
                --region "$AWS_REGION" >/dev/null
            success "Instance $instance_id stop initiated"
        fi
    done
    
    # Wait for all instances to stop
    if [[ -n "$running_instances" ]]; then
        info "Waiting for instances to stop..."
        aws ec2 wait instance-stopped \
            --instance-ids $running_instances \
            --region "$AWS_REGION" || warning "Some instances may still be stopping"
    fi
    
    success "All production instances stopped"
}

# Step 3: Delete load balancers
step3_delete_load_balancers() {
    info "=== STEP 3: DELETE LOAD BALANCERS ==="
    
    # Delete Application Load Balancers
    local albs=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[?starts_with(LoadBalancerName, `prod-`)].{Arn:LoadBalancerArn,Name:LoadBalancerName}' \
        --output text)
    
    while IFS=$'\t' read -r arn name; do
        if [[ -n "$arn" ]] && confirm_deletion "Application Load Balancer" "$arn" "$name"; then
            info "Deleting ALB: $name"
            aws elbv2 delete-load-balancer \
                --load-balancer-arn "$arn" \
                --region "$AWS_REGION"
            success "ALB deletion initiated: $name"
        fi
    done <<< "$albs"
    
    # Delete Network Load Balancers  
    local nlbs=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[?Type==`network` && starts_with(LoadBalancerName, `prod-`)].{Arn:LoadBalancerArn,Name:LoadBalancerName}' \
        --output text)
    
    while IFS=$'\t' read -r arn name; do
        if [[ -n "$arn" ]] && confirm_deletion "Network Load Balancer" "$arn" "$name"; then
            info "Deleting NLB: $name"
            aws elbv2 delete-load-balancer \
                --load-balancer-arn "$arn" \
                --region "$AWS_REGION"
            success "NLB deletion initiated: $name"
        fi
    done <<< "$nlbs"
    
    # Wait for load balancers to be deleted
    info "Waiting for load balancers to be fully deleted..."
    sleep 30
    
    success "Load balancer deletion completed"
}

# Step 4: Terminate EC2 instances
step4_terminate_instances() {
    info "=== STEP 4: TERMINATE EC2 INSTANCES ==="
    
    local all_prod_instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
                  "Name=instance-state-name,Values=stopped,running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    
    if [[ -z "$all_prod_instances" ]]; then
        info "No production instances found for termination"
        return 0
    fi
    
    for instance_id in $all_prod_instances; do
        local instance_name=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' \
            --output text 2>/dev/null || echo "unknown")
        
        if confirm_deletion "Instance" "$instance_id" "$instance_name"; then
            info "Terminating instance: $instance_id ($instance_name)"
            aws ec2 terminate-instances \
                --instance-ids "$instance_id" \
                --region "$AWS_REGION" >/dev/null
            success "Instance $instance_id termination initiated"
        fi
    done
    
    # Wait for termination
    if [[ -n "$all_prod_instances" ]]; then
        info "Waiting for instance termination to complete..."
        aws ec2 wait instance-terminated \
            --instance-ids $all_prod_instances \
            --region "$AWS_REGION" || warning "Some instances may still be terminating"
    fi
    
    success "All production instances terminated"
}

# Step 5: Delete security groups
step5_delete_security_groups() {
    info "=== STEP 5: DELETE SECURITY GROUPS ==="
    
    # Get production security groups (excluding default)
    local security_groups=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
        --query 'SecurityGroups[?GroupName!=`default`].{Id:GroupId,Name:GroupName}' \
        --output text)
    
    if [[ -z "$security_groups" ]]; then
        info "No production security groups found"
        return 0
    fi
    
    # Delete security groups (may need multiple passes due to dependencies)
    local max_attempts=5
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        info "Security group deletion attempt $attempt/$max_attempts"
        local deleted_count=0
        
        while IFS=$'\t' read -r sg_id sg_name; do
            if [[ -n "$sg_id" ]] && confirm_deletion "Security Group" "$sg_id" "$sg_name"; then
                if aws ec2 delete-security-group \
                    --group-id "$sg_id" \
                    --region "$AWS_REGION" 2>/dev/null; then
                    success "Deleted security group: $sg_id ($sg_name)"
                    ((deleted_count++))
                else
                    warning "Could not delete security group: $sg_id ($sg_name) - may have dependencies"
                fi
            fi
        done <<< "$security_groups"
        
        if [[ $deleted_count -eq 0 ]]; then
            break
        fi
        
        # Refresh the list for next attempt
        security_groups=$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=tag:Environment,Values=prod,production" \
            --query 'SecurityGroups[?GroupName!=`default`].{Id:GroupId,Name:GroupName}' \
            --output text)
        
        if [[ -z "$security_groups" ]]; then
            break
        fi
        
        ((attempt++))
        sleep 10
    done
    
    success "Security group deletion completed"
}

# Step 6: Release Elastic IPs
step6_release_elastic_ips() {
    info "=== STEP 6: RELEASE ELASTIC IPS ==="
    
    # Get production Elastic IPs
    local eips=$(aws ec2 describe-addresses \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
        --query 'Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp,Name:Tags[?Key==`Name`]|[0].Value}' \
        --output text)
    
    if [[ -z "$eips" ]]; then
        info "No production Elastic IPs found"
        return 0
    fi
    
    while IFS=$'\t' read -r allocation_id public_ip name; do
        if [[ -n "$allocation_id" ]] && confirm_deletion "Elastic IP" "$allocation_id" "$name ($public_ip)"; then
            info "Releasing Elastic IP: $public_ip ($name)"
            aws ec2 release-address \
                --allocation-id "$allocation_id" \
                --region "$AWS_REGION"
            success "Elastic IP released: $public_ip"
        fi
    done <<< "$eips"
    
    success "Elastic IP release completed"
}

# Step 7: Delete NAT instances and networking
step7_delete_networking() {
    info "=== STEP 7: DELETE NETWORKING COMPONENTS ==="
    
    # Delete route tables (except main)
    local route_tables=$(aws ec2 describe-route-tables \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$KNOWN_VPC_ID" \
                  "Name=tag:Environment,Values=prod,production" \
        --query 'RouteTables[?Associations[0].Main!=`true`].{Id:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value}' \
        --output text)
    
    while IFS=$'\t' read -r rt_id rt_name; do
        if [[ -n "$rt_id" ]] && confirm_deletion "Route Table" "$rt_id" "$rt_name"; then
            info "Deleting route table: $rt_id ($rt_name)"
            
            # First disassociate from subnets
            local associations=$(aws ec2 describe-route-tables \
                --route-table-ids "$rt_id" \
                --region "$AWS_REGION" \
                --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
                --output text)
            
            for assoc_id in $associations; do
                aws ec2 disassociate-route-table \
                    --association-id "$assoc_id" \
                    --region "$AWS_REGION" 2>/dev/null || true
            done
            
            aws ec2 delete-route-table \
                --route-table-id "$rt_id" \
                --region "$AWS_REGION" || warning "Could not delete route table $rt_id"
            success "Route table deleted: $rt_id"
        fi
    done <<< "$route_tables"
    
    # Delete subnets
    local subnets=$(aws ec2 describe-subnets \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$KNOWN_VPC_ID" \
                  "Name=tag:Environment,Values=prod,production" \
        --query 'Subnets[].{Id:SubnetId,Name:Tags[?Key==`Name`]|[0].Value}' \
        --output text)
    
    while IFS=$'\t' read -r subnet_id subnet_name; do
        if [[ -n "$subnet_id" ]] && confirm_deletion "Subnet" "$subnet_id" "$subnet_name"; then
            info "Deleting subnet: $subnet_id ($subnet_name)"
            aws ec2 delete-subnet \
                --subnet-id "$subnet_id" \
                --region "$AWS_REGION" || warning "Could not delete subnet $subnet_id"
            success "Subnet deleted: $subnet_id"
        fi
    done <<< "$subnets"
    
    # Delete Internet Gateway
    local igw_id=$(aws ec2 describe-internet-gateways \
        --region "$AWS_REGION" \
        --filters "Name=attachment.vpc-id,Values=$KNOWN_VPC_ID" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text)
    
    if [[ "$igw_id" != "None" ]] && [[ -n "$igw_id" ]]; then
        if confirm_deletion "Internet Gateway" "$igw_id" "prod-igw"; then
            info "Detaching and deleting Internet Gateway: $igw_id"
            aws ec2 detach-internet-gateway \
                --internet-gateway-id "$igw_id" \
                --vpc-id "$KNOWN_VPC_ID" \
                --region "$AWS_REGION" || true
            aws ec2 delete-internet-gateway \
                --internet-gateway-id "$igw_id" \
                --region "$AWS_REGION" || warning "Could not delete IGW $igw_id"
            success "Internet Gateway deleted: $igw_id"
        fi
    fi
    
    success "Networking components deletion completed"
}

# Step 8: Delete VPC
step8_delete_vpc() {
    info "=== STEP 8: DELETE VPC ==="
    
    if confirm_deletion "VPC" "$KNOWN_VPC_ID" "prod-vpc"; then
        info "Deleting VPC: $KNOWN_VPC_ID"
        
        # Wait a bit for dependencies to clear
        sleep 30
        
        if aws ec2 delete-vpc \
            --vpc-id "$KNOWN_VPC_ID" \
            --region "$AWS_REGION"; then
            success "VPC deleted: $KNOWN_VPC_ID"
        else
            warning "Could not delete VPC $KNOWN_VPC_ID - may have remaining dependencies"
            info "Check for remaining ENIs, NAT gateways, or other attached resources"
        fi
    fi
    
    success "VPC deletion completed"
}

# Step 9: Cleanup Route53 records (optional)
step9_cleanup_route53() {
    info "=== STEP 9: CLEANUP ROUTE53 RECORDS (OPTIONAL) ==="
    
    warning "Route53 hosted zones contain DNS records that may be needed"
    warning "Skipping automatic Route53 cleanup to prevent service disruption"
    
    info "Manual Route53 cleanup (if desired):"
    echo "  1. Remove A records pointing to deleted load balancers"
    echo "  2. Clean up SSL validation records for deleted certificates"
    echo "  3. Remove health check records for deleted resources"
    
    info "Route53 cleanup skipped"
}

# Verification step
step10_verify_deletion() {
    info "=== STEP 10: VERIFY DELETION COMPLETION ==="
    
    info "Checking for remaining production resources..."
    
    # Check instances
    local remaining_instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
                  "Name=instance-state-name,Values=running,stopped,stopping" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    
    if [[ -n "$remaining_instances" ]]; then
        warning "Remaining instances found: $remaining_instances"
    else
        success "✓ No remaining production instances"
    fi
    
    # Check load balancers
    local remaining_lbs=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[?starts_with(LoadBalancerName, `prod-`)].LoadBalancerName' \
        --output text)
    
    if [[ -n "$remaining_lbs" ]]; then
        warning "Remaining load balancers found: $remaining_lbs"
    else
        success "✓ No remaining production load balancers"
    fi
    
    # Check security groups
    local remaining_sgs=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod,production" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text)
    
    if [[ -n "$remaining_sgs" ]]; then
        warning "Remaining security groups found: $remaining_sgs"
    else
        success "✓ No remaining production security groups"
    fi
    
    success "Deletion verification completed"
}

# Main execution function
main() {
    local start_time=$(date +%s)
    
    info "Starting safe deletion of Jupiter production infrastructure"
    info "Log file: $LOG_FILE"
    
    pre_deletion_checks
    
    warning "This will DELETE all production infrastructure!"
    read -p "Type 'DELETE PRODUCTION' to confirm: " -r
    if [[ $REPLY != "DELETE PRODUCTION" ]]; then
        info "Deletion cancelled"
        exit 0
    fi
    
    info "Beginning infrastructure deletion in dependency order..."
    
    step1_deregister_targets
    step2_stop_instances
    step3_delete_load_balancers
    step4_terminate_instances
    step5_delete_security_groups
    step6_release_elastic_ips
    step7_delete_networking
    step8_delete_vpc
    step9_cleanup_route53
    step10_verify_deletion
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    success "=== INFRASTRUCTURE DELETION COMPLETED ==="
    success "Duration: ${minutes}m ${seconds}s"
    success "Log saved to: $LOG_FILE"
    
    info "Next steps:"
    echo "  1. Review deletion log for any warnings"
    echo "  2. Proceed with new infrastructure deployment"
    echo "  3. Run './orchestrate.sh' to deploy automated infrastructure"
}

# Command line help
case "${1:-}" in
    --help|-h)
        echo "Safe Deletion Script for Jupiter Production Infrastructure"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --dry-run      Show what would be deleted without executing"
        echo ""
        echo "This script safely deletes infrastructure in dependency order:"
        echo "  1. Deregister targets from load balancers"
        echo "  2. Stop all EC2 instances"
        echo "  3. Delete load balancers"
        echo "  4. Terminate EC2 instances"
        echo "  5. Delete security groups"
        echo "  6. Release Elastic IPs"
        echo "  7. Delete networking components"
        echo "  8. Delete VPC"
        echo "  9. Optional Route53 cleanup"
        echo "  10. Verify deletion completion"
        echo ""
        echo "PROTECTION: Resources matching dev/test patterns are protected"
        exit 0
        ;;
    --dry-run)
        warning "DRY RUN MODE - No resources will be deleted"
        info "Would delete the following resource types:"
        echo "  • Load balancer targets"
        echo "  • Application and Network Load Balancers"  
        echo "  • EC2 instances with Environment=prod"
        echo "  • Production security groups"
        echo "  • Elastic IPs tagged for production"
        echo "  • Route tables and subnets"
        echo "  • Internet Gateway"
        echo "  • Production VPC"
        exit 0
        ;;
esac

# Execute main deletion process
main