#!/bin/bash
set -euo pipefail

# Rollback Script for Jupiter Infrastructure
# This script provides multiple rollback strategies for failed deployments:
# 1. Restore from backup if deployment fails
# 2. Clean up partial deployments
# 3. Emergency infrastructure recovery
# 4. State restoration from backups

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="ap-southeast-2"
ENVIRONMENT="prod"
BACKUP_S3_BUCKET="jupiter-infrastructure-backups"
LOG_FILE="/tmp/jupiter-rollback-$(date +%Y%m%d-%H%M%S).log"

# Rollback options
ROLLBACK_TYPE=""
BACKUP_LOCATION=""
FORCE_ROLLBACK=false
DRY_RUN=false

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
critical() { log "CRITICAL" "${RED}💀 $*${NC}"; }

# Banner
show_banner() {
    echo -e "${RED}"
    cat << 'EOF'
╦ ╦╔═╗╦ ╦╦╔╦╗╔═╗╦═╗  ╦═╗╔═╗╦  ╦  ╔╗ ╔═╗╔═╗╦╔═
║ ║║  ║ ║║ ║ ║╣ ╠╦╝  ╠╦╝║ ║║  ║  ╠╩╗╠═╣║  ╠╩╗
╚═╝╚═╝╚═╝╩ ╩ ╚═╝╩╚═  ╩╚═╚═╝╩═╝╩═╝╚═╝╩ ╩╚═╝╩ ╩
        Emergency Recovery System
EOF
    echo -e "${NC}"
}

# Check if we're in a failed state
detect_failure_state() {
    info "=== FAILURE STATE DETECTION ==="
    
    local terraform_state_exists=false
    local partial_deployment=false
    local infrastructure_broken=false
    
    # Check Terraform state
    if [[ -f "terraform.tfstate" ]]; then
        terraform_state_exists=true
        local resource_count=$(terraform show -json 2>/dev/null | jq '.values.root_module.resources | length' 2>/dev/null || echo "0")
        info "Terraform state exists with $resource_count resources"
    fi
    
    # Check for partial AWS resources
    local partial_instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "0")
    
    local partial_lbs=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query 'length(LoadBalancers[?starts_with(LoadBalancerName, `prod-`)])' --output text 2>/dev/null || echo "0")
    
    if [[ $partial_instances -gt 0 ]] || [[ $partial_lbs -gt 0 ]]; then
        partial_deployment=true
        warning "Partial deployment detected: $partial_instances instances, $partial_lbs load balancers"
    fi
    
    # Check for broken infrastructure
    local failed_instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" \
                  "Name=instance-state-name,Values=terminated,terminating" \
        --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "0")
    
    if [[ $failed_instances -gt 0 ]]; then
        infrastructure_broken=true
        error "Infrastructure failure detected: $failed_instances failed instances"
    fi
    
    # Determine rollback strategy
    if [[ "$infrastructure_broken" == "true" ]]; then
        ROLLBACK_TYPE="emergency"
        error "EMERGENCY ROLLBACK REQUIRED"
    elif [[ "$partial_deployment" == "true" ]]; then
        ROLLBACK_TYPE="cleanup"
        warning "CLEANUP ROLLBACK REQUIRED"
    elif [[ "$terraform_state_exists" == "true" ]]; then
        ROLLBACK_TYPE="terraform"
        info "TERRAFORM ROLLBACK AVAILABLE"
    else
        ROLLBACK_TYPE="manual"
        warning "MANUAL ROLLBACK REQUIRED"
    fi
    
    info "Detected rollback type: $ROLLBACK_TYPE"
}

# Find available backups
find_available_backups() {
    info "=== SEARCHING FOR AVAILABLE BACKUPS ==="
    
    # Check for local backup location file
    if [[ -f ".last-backup-location" ]]; then
        BACKUP_LOCATION=$(cat .last-backup-location)
        info "Found recent backup location: $BACKUP_LOCATION"
    fi
    
    # List S3 backups
    info "Searching S3 for available backups..."
    local s3_backups=$(aws s3 ls "s3://$BACKUP_S3_BUCKET/" --recursive | grep -E "(pre-migration|infrastructure|state)" | sort -r | head -10 || echo "")
    
    if [[ -n "$s3_backups" ]]; then
        success "Available backups found:"
        echo "$s3_backups" | while read -r line; do
            echo "  • $line"
        done
    else
        warning "No S3 backups found in bucket: $BACKUP_S3_BUCKET"
    fi
    
    # Check for Terraform state backups
    if aws s3 ls "s3://$BACKUP_S3_BUCKET/terraform-state/" >/dev/null 2>&1; then
        local state_backups=$(aws s3 ls "s3://$BACKUP_S3_BUCKET/terraform-state/" --recursive | head -5)
        if [[ -n "$state_backups" ]]; then
            success "Terraform state backups available:"
            echo "$state_backups"
        fi
    fi
}

# Terraform rollback
rollback_terraform() {
    info "=== TERRAFORM ROLLBACK ==="
    
    warning "This will destroy all Terraform-managed resources"
    if [[ "$FORCE_ROLLBACK" != "true" ]]; then
        read -p "Continue with Terraform rollback? (type 'ROLLBACK' to confirm): " -r
        if [[ $REPLY != "ROLLBACK" ]]; then
            info "Terraform rollback cancelled"
            return 0
        fi
    fi
    
    # Backup current state before rollback
    local rollback_backup="s3://$BACKUP_S3_BUCKET/rollback-states/pre-rollback-$(date +%Y%m%d-%H%M%S)"
    if [[ -f "terraform.tfstate" ]]; then
        info "Backing up current state before rollback..."
        aws s3 cp terraform.tfstate "$rollback_backup-terraform.tfstate" || warning "Could not backup current state"
    fi
    
    # Terraform destroy
    info "Destroying Terraform infrastructure..."
    if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY RUN: Would run 'terraform destroy'"
        return 0
    fi
    
    if terraform destroy -auto-approve; then
        success "Terraform infrastructure destroyed successfully"
        
        # Clean up state files
        if [[ -f "terraform.tfstate" ]]; then
            mv terraform.tfstate "terraform.tfstate.destroyed.$(date +%Y%m%d-%H%M%S)"
            success "Terraform state archived"
        fi
        
        if [[ -f "terraform.tfstate.backup" ]]; then
            mv terraform.tfstate.backup "terraform.tfstate.backup.destroyed.$(date +%Y%m%d-%H%M%S)"
        fi
        
        # Clean up plan files
        rm -f deployment.plan terraform.plan
        
        success "Terraform rollback completed"
    else
        error "Terraform destroy failed"
        warning "Manual cleanup may be required"
        return 1
    fi
}

# Cleanup partial deployment
rollback_cleanup() {
    info "=== CLEANUP PARTIAL DEPLOYMENT ==="
    
    warning "This will clean up partial deployment resources"
    if [[ "$FORCE_ROLLBACK" != "true" ]]; then
        read -p "Continue with cleanup rollback? (type 'CLEANUP' to confirm): " -r
        if [[ $REPLY != "CLEANUP" ]]; then
            info "Cleanup rollback cancelled"
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY RUN: Would clean up partial resources"
        return 0
    fi
    
    # Use the delete-existing script to clean up
    if [[ -f "./delete-existing.sh" ]]; then
        info "Using delete-existing script for cleanup..."
        chmod +x ./delete-existing.sh
        if ./delete-existing.sh --force; then
            success "Partial deployment cleaned up successfully"
        else
            error "Cleanup script failed"
            warning "Manual cleanup required"
            return 1
        fi
    else
        warning "delete-existing.sh not found, performing manual cleanup"
        manual_cleanup_resources
    fi
    
    # Clean up Terraform state if it exists
    if [[ -f "terraform.tfstate" ]]; then
        warning "Moving Terraform state files..."
        mv terraform.tfstate "terraform.tfstate.cleanup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        mv terraform.tfstate.backup "terraform.tfstate.backup.cleanup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
    
    success "Cleanup rollback completed"
}

# Manual resource cleanup
manual_cleanup_resources() {
    info "=== MANUAL RESOURCE CLEANUP ==="
    
    # Stop and terminate instances
    info "Cleaning up EC2 instances..."
    local prod_instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" \
                  "Name=instance-state-name,Values=running,stopped,stopping" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
    
    if [[ -n "$prod_instances" ]]; then
        warning "Terminating production instances: $prod_instances"
        aws ec2 terminate-instances --instance-ids $prod_instances --region "$AWS_REGION" || warning "Some instances could not be terminated"
        
        # Wait for termination
        info "Waiting for instance termination..."
        aws ec2 wait instance-terminated --instance-ids $prod_instances --region "$AWS_REGION" || warning "Timeout waiting for termination"
    fi
    
    # Delete load balancers
    info "Cleaning up load balancers..."
    local prod_lbs=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query 'LoadBalancers[?starts_with(LoadBalancerName, `prod-`)].LoadBalancerArn' --output text)
    
    for lb_arn in $prod_lbs; do
        if [[ -n "$lb_arn" ]]; then
            warning "Deleting load balancer: $lb_arn"
            aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" --region "$AWS_REGION" || warning "Could not delete LB: $lb_arn"
        fi
    done
    
    # Clean up security groups (with retries for dependencies)
    info "Cleaning up security groups..."
    local max_attempts=5
    for attempt in $(seq 1 $max_attempts); do
        local prod_sgs=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
            --filters "Name=tag:Environment,Values=prod" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
        
        if [[ -z "$prod_sgs" ]]; then
            break
        fi
        
        for sg_id in $prod_sgs; do
            aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" 2>/dev/null || true
        done
        
        sleep 10
    done
    
    success "Manual cleanup completed"
}

# Emergency rollback
rollback_emergency() {
    info "=== EMERGENCY ROLLBACK ==="
    
    critical "EMERGENCY ROLLBACK INITIATED"
    critical "This will attempt to restore infrastructure from backup"
    
    if [[ "$FORCE_ROLLBACK" != "true" ]]; then
        echo ""
        echo -e "${RED}WARNING: This is an emergency rollback procedure${NC}"
        echo -e "${RED}It will attempt to restore infrastructure from the most recent backup${NC}"
        echo ""
        read -p "Continue with EMERGENCY rollback? (type 'EMERGENCY' to confirm): " -r
        if [[ $REPLY != "EMERGENCY" ]]; then
            info "Emergency rollback cancelled"
            return 0
        fi
    fi
    
    # First, try to clean up broken resources
    info "Cleaning up broken infrastructure..."
    manual_cleanup_resources
    
    # Restore from backup if available
    if [[ -n "$BACKUP_LOCATION" ]]; then
        info "Attempting to restore from backup: $BACKUP_LOCATION"
        restore_from_backup "$BACKUP_LOCATION"
    else
        warning "No backup location specified, cannot restore infrastructure"
        warning "Manual restoration required"
        show_manual_restoration_steps
    fi
}

# Restore from backup
restore_from_backup() {
    local backup_path="$1"
    info "=== RESTORING FROM BACKUP: $backup_path ==="
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY RUN: Would restore from backup: $backup_path"
        return 0
    fi
    
    # Download backup files
    local restore_dir="/tmp/jupiter-restore-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$restore_dir"
    
    info "Downloading backup files to: $restore_dir"
    if aws s3 sync "$backup_path/" "$restore_dir/"; then
        success "Backup files downloaded successfully"
    else
        error "Failed to download backup files"
        return 1
    fi
    
    # List what we have
    info "Backup contents:"
    ls -la "$restore_dir/"
    
    # For now, we'll show the restoration steps
    # In a complete implementation, this would include:
    # 1. Parsing the infrastructure backup
    # 2. Recreating resources using AWS CLI or Terraform
    # 3. Validating the restoration
    
    warning "Automatic restoration not yet implemented"
    warning "Use the backup files in $restore_dir to manually restore infrastructure"
    show_manual_restoration_steps
}

# Show manual restoration steps
show_manual_restoration_steps() {
    info "=== MANUAL RESTORATION STEPS ==="
    
    echo ""
    echo -e "${CYAN}Manual restoration procedure:${NC}"
    echo ""
    echo "1. Review backup files for previous infrastructure state"
    echo "2. Recreate VPC and networking components"
    echo "3. Launch NAT instances in public subnets"
    echo "4. Deploy service instances with user data scripts"
    echo "5. Configure load balancers and target groups"
    echo "6. Set up DNS records in Route53"
    echo "7. Validate SSL certificates"
    echo "8. Test all service endpoints"
    echo ""
    echo -e "${YELLOW}Alternative: Use the original manual setup documentation${NC}"
    echo -e "${YELLOW}or wait for infrastructure team to resolve the automation${NC}"
    echo ""
}

# State rollback
rollback_state() {
    info "=== TERRAFORM STATE ROLLBACK ==="
    
    local state_backup_path="s3://$BACKUP_S3_BUCKET/terraform-state/"
    
    info "Searching for Terraform state backups..."
    local available_states=$(aws s3 ls "$state_backup_path" --recursive | sort -r | head -5)
    
    if [[ -z "$available_states" ]]; then
        warning "No Terraform state backups found"
        return 1
    fi
    
    echo "Available state backups:"
    echo "$available_states"
    echo ""
    
    if [[ "$FORCE_ROLLBACK" != "true" ]]; then
        read -p "Enter the backup filename to restore (or 'cancel'): " -r backup_filename
        if [[ "$backup_filename" == "cancel" ]] || [[ -z "$backup_filename" ]]; then
            info "State rollback cancelled"
            return 0
        fi
    else
        # Use the most recent backup
        local backup_filename=$(echo "$available_states" | head -n1 | awk '{print $4}')
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY RUN: Would restore state from: $backup_filename"
        return 0
    fi
    
    # Backup current state
    if [[ -f "terraform.tfstate" ]]; then
        cp terraform.tfstate "terraform.tfstate.pre-rollback.$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Download and restore state
    info "Downloading state backup: $backup_filename"
    if aws s3 cp "${state_backup_path}${backup_filename}" terraform.tfstate; then
        success "Terraform state restored from backup"
        
        info "Refreshing Terraform state..."
        if terraform refresh; then
            success "State rollback completed successfully"
        else
            error "State refresh failed after rollback"
            warning "Manual state verification required"
            return 1
        fi
    else
        error "Failed to download state backup"
        return 1
    fi
}

# Show rollback options
show_rollback_options() {
    echo ""
    echo -e "${CYAN}Available rollback options:${NC}"
    echo ""
    echo "1. terraform  - Destroy Terraform-managed infrastructure (cleanest)"
    echo "2. cleanup    - Clean up partial deployment resources"
    echo "3. emergency  - Emergency rollback with backup restoration"
    echo "4. state      - Rollback Terraform state only"
    echo "5. manual     - Show manual rollback instructions"
    echo ""
}

# Health check after rollback
post_rollback_health_check() {
    info "=== POST-ROLLBACK HEALTH CHECK ==="
    
    # Check for remaining production resources
    local remaining_instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" \
                  "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
    
    local remaining_lbs=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query 'LoadBalancers[?starts_with(LoadBalancerName, `prod-`)].LoadBalancerName' --output text)
    
    if [[ -z "$remaining_instances" ]] && [[ -z "$remaining_lbs" ]]; then
        success "✓ All production resources cleaned up successfully"
        success "✓ Rollback completed - environment is clean"
    else
        warning "⚠ Some resources may still exist:"
        if [[ -n "$remaining_instances" ]]; then
            warning "  Instances: $remaining_instances"
        fi
        if [[ -n "$remaining_lbs" ]]; then
            warning "  Load Balancers: $remaining_lbs"
        fi
        warning "Manual verification and cleanup may be required"
    fi
    
    # Check Terraform state
    if [[ -f "terraform.tfstate" ]]; then
        local resource_count=$(terraform show -json 2>/dev/null | jq '.values.root_module.resources | length' 2>/dev/null || echo "0")
        if [[ "$resource_count" == "0" ]]; then
            success "✓ Terraform state is clean"
        else
            warning "⚠ Terraform state contains $resource_count resources"
        fi
    else
        success "✓ No Terraform state file present"
    fi
}

# Main execution function
main() {
    local start_time=$(date +%s)
    
    show_banner
    info "Jupiter Infrastructure Rollback System"
    info "Log file: $LOG_FILE"
    
    # Detect current state
    detect_failure_state
    find_available_backups
    
    # If no specific rollback type provided, let user choose
    if [[ -z "${1:-}" ]] && [[ "$ROLLBACK_TYPE" != "emergency" ]]; then
        show_rollback_options
        read -p "Select rollback type (1-5): " -r choice
        
        case $choice in
            1|terraform) ROLLBACK_TYPE="terraform" ;;
            2|cleanup) ROLLBACK_TYPE="cleanup" ;;
            3|emergency) ROLLBACK_TYPE="emergency" ;;
            4|state) ROLLBACK_TYPE="state" ;;
            5|manual) ROLLBACK_TYPE="manual" ;;
            *) error "Invalid choice"; exit 1 ;;
        esac
    fi
    
    # Execute rollback based on type
    case "$ROLLBACK_TYPE" in
        terraform)
            rollback_terraform
            ;;
        cleanup)
            rollback_cleanup
            ;;
        emergency)
            rollback_emergency
            ;;
        state)
            rollback_state
            ;;
        manual)
            show_manual_restoration_steps
            ;;
        *)
            error "Unknown rollback type: $ROLLBACK_TYPE"
            exit 1
            ;;
    esac
    
    # Post-rollback health check
    post_rollback_health_check
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    success "=== ROLLBACK COMPLETED ==="
    success "Duration: ${minutes}m ${seconds}s"
    success "Log file: $LOG_FILE"
    
    info "Next steps after rollback:"
    echo "  1. Verify all unwanted resources are removed"
    echo "  2. Review rollback log for any issues"
    echo "  3. Fix infrastructure automation if needed"
    echo "  4. Test deployment again: ./orchestrate.sh"
}

# Command line argument processing
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "Jupiter Infrastructure Rollback Script"
            echo ""
            echo "Usage: $0 [rollback_type] [options]"
            echo ""
            echo "Rollback Types:"
            echo "  terraform   Destroy all Terraform-managed resources"
            echo "  cleanup     Clean up partial deployment"
            echo "  emergency   Emergency rollback with backup restoration"
            echo "  state       Rollback Terraform state only"
            echo "  manual      Show manual rollback instructions"
            echo ""
            echo "Options:"
            echo "  --force         Skip confirmation prompts"
            echo "  --dry-run       Show what would be done without executing"
            echo "  --backup PATH   Specify backup location for restoration"
            echo "  --help, -h      Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 terraform                    # Terraform rollback"
            echo "  $0 emergency --force            # Emergency rollback"
            echo "  $0 cleanup --dry-run            # Preview cleanup"
            echo ""
            exit 0
            ;;
        --force)
            FORCE_ROLLBACK=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --backup)
            BACKUP_LOCATION="$2"
            shift 2
            ;;
        terraform|cleanup|emergency|state|manual)
            ROLLBACK_TYPE="$1"
            shift
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
main "$@"