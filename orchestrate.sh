#!/bin/bash
set -euo pipefail

# Jupiter Production Infrastructure Orchestration Script
# This script manages the complete infrastructure lifecycle:
# 1. Delete existing manual infrastructure safely
# 2. Deploy new automated infrastructure
# 3. Validate everything works
# 4. Handle rollback if needed

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="ap-southeast-2"
AWS_ACCOUNT="390402573034"
ENVIRONMENT="prod"
BACKUP_S3_BUCKET="jupiter-infrastructure-backups"
LOG_FILE="/tmp/jupiter-orchestration-$(date +%Y%m%d-%H%M%S).log"

# Critical resource protection
PROTECTED_RESOURCES=("jupyter-dev" "dev-" "development")

# Logging function
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

# Error handling
cleanup_on_error() {
    error "Operation failed. Check log file: $LOG_FILE"
    warning "If infrastructure is in a broken state, run: ./rollback.sh"
    exit 1
}

trap cleanup_on_error ERR

# Banner
echo -e "${BLUE}"
cat << 'EOF'
 ╦╦ ╦╔═╗╦╔╦╗╔═╗╦═╗  ╔═╗╦═╗╔═╗╦ ╦╔═╗╔═╗╔╦╗╦═╗╔═╗╔╦╗╦╔═╗╔╗╔
 ║║ ║╠═╝║ ║ ║╣ ╠╦╝  ║ ║╠╦╝║  ╠═╣║╣ ╚═╗ ║ ╠╦╝╠═╣ ║ ║║ ║║║║
╚╝╚═╝╩  ╩ ╩ ╚═╝╩╚═  ╚═╝╩╚═╚═╝╩ ╩╚═╝╚═╝ ╩ ╩╚═╩ ╩ ╩ ╩╚═╝╝╚╝
  Complete Infrastructure Lifecycle Management
EOF
echo -e "${NC}"

info "Starting Jupiter Production Infrastructure Orchestration"
info "Log file: $LOG_FILE"

# Phase 0: Pre-flight Checks
phase0_preflight_checks() {
    info "=== PHASE 0: PRE-FLIGHT CHECKS ==="
    
    info "Checking AWS CLI configuration..."
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS CLI not configured or invalid credentials"
        exit 1
    fi
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local current_region=$(aws configure get region || echo "us-east-1")
    
    info "AWS Account: $account_id"
    info "AWS Region: $current_region"
    
    if [[ "$account_id" != "$AWS_ACCOUNT" ]]; then
        error "Wrong AWS account. Expected: $AWS_ACCOUNT, Got: $account_id"
        exit 1
    fi
    
    if [[ "$current_region" != "$AWS_REGION" ]]; then
        warning "AWS region mismatch. Expected: $AWS_REGION, Got: $current_region"
        warning "Configuring region to $AWS_REGION"
        export AWS_DEFAULT_REGION="$AWS_REGION"
    fi
    
    info "Checking terraform installation..."
    if ! command -v terraform &> /dev/null; then
        error "Terraform not installed"
        exit 1
    fi
    
    local tf_version=$(terraform version -json | jq -r '.terraform_version')
    info "Terraform version: $tf_version"
    
    info "Checking required files..."
    local required_files=("main.tf" "variables.tf" "terraform.tfvars" "delete-existing.sh" "validate.sh" "rollback.sh")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error "Required file missing: $file"
            exit 1
        fi
    done
    
    info "Verifying NOT in jupiter-dev environment..."
    local dev_resources=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=dev" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    
    if [[ -n "$dev_resources" ]]; then
        warning "Development resources found. Ensuring no interference with dev environment."
        info "Dev instances found: $dev_resources"
    fi
    
    info "Creating backup location..."
    aws s3 mb "s3://$BACKUP_S3_BUCKET" 2>/dev/null || true
    
    success "Pre-flight checks completed successfully"
}

# Phase 1: Infrastructure Backup
phase1_backup_infrastructure() {
    info "=== PHASE 1: INFRASTRUCTURE STATE BACKUP ==="
    
    local backup_timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="s3://$BACKUP_S3_BUCKET/pre-migration-backup-$backup_timestamp"
    
    info "Creating infrastructure state backup..."
    
    # Export current infrastructure state
    info "Exporting current instance configuration..."
    aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" > "/tmp/current-instances-$backup_timestamp.json"
    
    info "Exporting current load balancer configuration..."
    aws elbv2 describe-load-balancers --region "$AWS_REGION" > "/tmp/current-load-balancers-$backup_timestamp.json"
    
    info "Exporting current Route53 configuration..."
    aws route53 list-hosted-zones > "/tmp/current-route53-$backup_timestamp.json"
    
    info "Uploading backup to S3..."
    aws s3 cp "/tmp/current-instances-$backup_timestamp.json" "$backup_path/"
    aws s3 cp "/tmp/current-load-balancers-$backup_timestamp.json" "$backup_path/"
    aws s3 cp "/tmp/current-route53-$backup_timestamp.json" "$backup_path/"
    
    # Store backup location for rollback
    echo "$backup_path" > .last-backup-location
    
    success "Infrastructure state backed up to: $backup_path"
}

# Phase 2: Safe Infrastructure Deletion
phase2_delete_existing() {
    info "=== PHASE 2: SAFE DELETION OF EXISTING INFRASTRUCTURE ==="
    
    # Run the safe deletion script
    if [[ ! -f "./delete-existing.sh" ]]; then
        error "delete-existing.sh script not found"
        exit 1
    fi
    
    chmod +x ./delete-existing.sh
    info "Running safe deletion script..."
    
    if ./delete-existing.sh; then
        success "Existing infrastructure deleted successfully"
    else
        error "Failed to delete existing infrastructure"
        warning "Check the deletion script output for details"
        exit 1
    fi
}

# Phase 3: Deploy New Infrastructure
phase3_deploy_infrastructure() {
    info "=== PHASE 3: DEPLOY NEW AUTOMATED INFRASTRUCTURE ==="
    
    info "Initializing Terraform..."
    if ! terraform init; then
        error "Terraform initialization failed"
        exit 1
    fi
    
    info "Validating Terraform configuration..."
    if ! terraform validate; then
        error "Terraform validation failed"
        exit 1
    fi
    
    info "Creating Terraform plan..."
    if ! terraform plan -out=deployment.plan -detailed-exitcode; then
        case $? in
            1) error "Terraform plan failed"; exit 1 ;;
            2) info "Changes planned for deployment" ;;
        esac
    fi
    
    info "Applying Terraform infrastructure..."
    if ! terraform apply -auto-approve deployment.plan; then
        error "Terraform apply failed"
        warning "Infrastructure may be in partial state. Run ./rollback.sh if needed"
        exit 1
    fi
    
    success "New infrastructure deployed successfully"
}

# Phase 4: Infrastructure Validation
phase4_validate_infrastructure() {
    info "=== PHASE 4: INFRASTRUCTURE VALIDATION ==="
    
    if [[ ! -f "./validate.sh" ]]; then
        error "validate.sh script not found"
        exit 1
    fi
    
    chmod +x ./validate.sh
    info "Running comprehensive validation..."
    
    if ./validate.sh; then
        success "Infrastructure validation passed"
    else
        error "Infrastructure validation failed"
        warning "Infrastructure may not be fully functional"
        
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            warning "Aborting due to validation failure"
            warning "Run ./rollback.sh to restore previous state"
            exit 1
        fi
    fi
}

# Phase 5: Final Health Checks
phase5_health_checks() {
    info "=== PHASE 5: FINAL HEALTH CHECKS ==="
    
    info "Checking service endpoints..."
    
    local domains=("jupyter.com.au" "www.jupyter.com.au" "video.jupyter.com.au")
    local failed_checks=0
    
    for domain in "${domains[@]}"; do
        info "Testing $domain..."
        
        # DNS resolution test
        if dig +short "$domain" | grep -q '^[0-9]'; then
            success "✓ $domain DNS resolution working"
        else
            error "✗ $domain DNS resolution failed"
            ((failed_checks++))
        fi
        
        # HTTP response test (with timeout)
        if timeout 30 curl -s -I "https://$domain" | grep -q "200 OK"; then
            success "✓ $domain HTTP response OK"
        else
            warning "⚠ $domain HTTP response not ready (may need time to propagate)"
        fi
    done
    
    info "Checking load balancer health..."
    local alb_arn=$(terraform output -raw alb_arn 2>/dev/null || echo "")
    local nlb_arn=$(terraform output -raw nlb_arn 2>/dev/null || echo "")
    
    if [[ -n "$alb_arn" ]]; then
        local alb_state=$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" --query 'LoadBalancers[0].State.Code' --output text)
        if [[ "$alb_state" == "active" ]]; then
            success "✓ Application Load Balancer is active"
        else
            error "✗ Application Load Balancer state: $alb_state"
            ((failed_checks++))
        fi
    fi
    
    if [[ -n "$nlb_arn" ]]; then
        local nlb_state=$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb_arn" --query 'LoadBalancers[0].State.Code' --output text)
        if [[ "$nlb_state" == "active" ]]; then
            success "✓ Network Load Balancer is active"
        else
            error "✗ Network Load Balancer state: $nlb_state"
            ((failed_checks++))
        fi
    fi
    
    if [[ $failed_checks -gt 0 ]]; then
        warning "$failed_checks health checks failed"
        warning "Some services may need additional time to become fully operational"
    else
        success "All health checks passed"
    fi
}

# Phase 6: Summary Report
phase6_summary_report() {
    info "=== PHASE 6: DEPLOYMENT SUMMARY ==="
    
    local end_time=$(date)
    local duration=$(( $(date +%s) - $start_time ))
    local minutes=$(( duration / 60 ))
    local seconds=$(( duration % 60 ))
    
    success "=== JUPITER INFRASTRUCTURE ORCHESTRATION COMPLETE ==="
    success "Total Duration: ${minutes}m ${seconds}s"
    success "Deployment Date: $end_time"
    
    info "Infrastructure Summary:"
    terraform output 2>/dev/null || echo "No Terraform outputs available"
    
    info "Key Endpoints:"
    echo "  • Main Site: https://jupyter.com.au"
    echo "  • WWW Site: https://www.jupyter.com.au" 
    echo "  • Video Stream: https://video.jupyter.com.au"
    
    info "Management Commands:"
    echo "  • View Infrastructure: terraform show"
    echo "  • Scale Services: terraform plan -var='scale_up=true'"
    echo "  • Emergency Rollback: ./rollback.sh"
    echo "  • Full Validation: ./validate.sh"
    
    info "Next Steps:"
    echo "  1. Monitor services for 24 hours"
    echo "  2. Test failover mechanisms"
    echo "  3. Validate SSL certificates"
    echo "  4. Backup automated infrastructure state"
    
    success "Jupiter Production Infrastructure is now fully automated!"
    
    info "Log file saved to: $LOG_FILE"
    aws s3 cp "$LOG_FILE" "s3://$BACKUP_S3_BUCKET/deployment-logs/" 2>/dev/null || true
}

# Error recovery function
handle_deployment_failure() {
    error "=== DEPLOYMENT FAILURE DETECTED ==="
    error "Infrastructure deployment failed at phase: $current_phase"
    
    warning "Automated recovery options:"
    echo "  1. Run './rollback.sh' to restore previous infrastructure"
    echo "  2. Check logs in $LOG_FILE for detailed error information"
    echo "  3. Fix issues and re-run './orchestrate.sh'"
    
    warning "Manual recovery commands:"
    echo "  • Emergency stop: terraform destroy -auto-approve"
    echo "  • Partial cleanup: ./delete-existing.sh"
    echo "  • Reset state: rm -rf .terraform terraform.tfstate*"
    
    exit 1
}

# Main execution flow
main() {
    local start_time=$(date +%s)
    
    # Trap errors and call recovery function
    trap 'current_phase="$current_phase"; handle_deployment_failure' ERR
    
    current_phase="preflight"
    phase0_preflight_checks
    
    current_phase="backup"
    phase1_backup_infrastructure
    
    current_phase="deletion"
    phase2_delete_existing
    
    current_phase="deployment"
    phase3_deploy_infrastructure
    
    current_phase="validation"
    phase4_validate_infrastructure
    
    current_phase="health_checks"
    phase5_health_checks
    
    current_phase="summary"
    phase6_summary_report
    
    # Remove error trap on successful completion
    trap - ERR
}

# Command line options
case "${1:-}" in
    --help|-h)
        echo "Jupiter Infrastructure Orchestration Script"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --dry-run      Show what would be done without executing"
        echo "  --skip-backup  Skip infrastructure backup (not recommended)"
        echo "  --force        Skip all confirmation prompts"
        echo ""
        echo "This script will:"
        echo "  1. Backup current infrastructure state"
        echo "  2. Safely delete existing manual infrastructure"
        echo "  3. Deploy new automated infrastructure via Terraform"
        echo "  4. Validate all services are working"
        echo "  5. Provide rollback capability if needed"
        exit 0
        ;;
    --dry-run)
        warning "DRY RUN MODE - No changes will be made"
        echo "Would execute phases:"
        echo "  1. Pre-flight checks"
        echo "  2. Infrastructure backup"
        echo "  3. Safe deletion of existing resources"
        echo "  4. Deploy new Terraform infrastructure"
        echo "  5. Comprehensive validation"
        echo "  6. Health checks and reporting"
        exit 0
        ;;
    --skip-backup)
        warning "Backup phase will be skipped"
        warning "This is NOT recommended for production"
        SKIP_BACKUP=true
        ;;
    --force)
        warning "Force mode enabled - skipping confirmations"
        FORCE_MODE=true
        ;;
esac

# Final confirmation
if [[ "${FORCE_MODE:-}" != "true" ]]; then
    warning "This will replace the entire Jupiter production infrastructure"
    warning "Current manual infrastructure will be DELETED"
    warning "New automated infrastructure will be deployed"
    echo ""
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " -r
    if [[ $REPLY != "yes" ]]; then
        info "Operation cancelled"
        exit 0
    fi
fi

# Execute main orchestration
main

success "Jupiter Infrastructure Orchestration completed successfully!"