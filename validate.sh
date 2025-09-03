#!/bin/bash
set -euo pipefail

# Comprehensive Validation Script for Jupiter Infrastructure
# This script performs thorough validation of all infrastructure components
# including networking, services, load balancers, DNS, SSL, and health checks.

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
LOG_FILE="/tmp/jupiter-validation-$(date +%Y%m%d-%H%M%S).log"
REPORT_FILE="/tmp/jupiter-validation-report-$(date +%Y%m%d-%H%M%S).json"

# Validation tracking
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Logging functions
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; ((PASSED_CHECKS++)); }
warning() { log "WARNING" "${YELLOW}$*${NC}"; ((WARNING_CHECKS++)); }
error() { log "ERROR" "${RED}$*${NC}"; ((FAILED_CHECKS++)); }
check() { log "CHECK" "${CYAN}$*${NC}"; ((TOTAL_CHECKS++)); }

# JSON report functions
json_start() {
    cat > "$REPORT_FILE" << 'EOF'
{
  "validation_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "prod",
  "region": "ap-southeast-2",
  "categories": {
EOF
}

json_category_start() {
    local category="$1"
    echo "    \"$category\": {" >> "$REPORT_FILE"
    echo "      \"checks\": [" >> "$REPORT_FILE"
}

json_check() {
    local name="$1"
    local status="$2"
    local details="$3"
    cat >> "$REPORT_FILE" << EOF
        {
          "name": "$name",
          "status": "$status",
          "details": "$details",
          "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        },
EOF
}

json_category_end() {
    # Remove trailing comma and close category
    sed -i '$ s/,$//' "$REPORT_FILE"
    echo "      ]" >> "$REPORT_FILE"
    echo "    }," >> "$REPORT_FILE"
}

json_end() {
    # Remove trailing comma and close JSON
    sed -i '$ s/,$//' "$REPORT_FILE"
    cat >> "$REPORT_FILE" << EOF
  },
  "summary": {
    "total_checks": $TOTAL_CHECKS,
    "passed": $PASSED_CHECKS,
    "failed": $FAILED_CHECKS,
    "warnings": $WARNING_CHECKS,
    "success_rate": "$(echo "scale=2; $PASSED_CHECKS * 100 / $TOTAL_CHECKS" | bc -l)%"
  }
}
EOF
}

# Validation Categories

# 1. Infrastructure Validation
validate_infrastructure() {
    info "=== INFRASTRUCTURE VALIDATION ==="
    json_category_start "infrastructure"
    
    # VPC validation
    check "Validating VPC configuration"
    local vpc_id=$(terraform output -raw vpc_id 2>/dev/null || echo "")
    if [[ -n "$vpc_id" ]]; then
        local vpc_state=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --region "$AWS_REGION" \
            --query 'Vpcs[0].State' --output text 2>/dev/null || echo "not-found")
        if [[ "$vpc_state" == "available" ]]; then
            success "✓ VPC is available: $vpc_id"
            json_check "vpc_available" "PASS" "VPC $vpc_id is available"
        else
            error "✗ VPC not available: $vpc_id (state: $vpc_state)"
            json_check "vpc_available" "FAIL" "VPC $vpc_id state: $vpc_state"
        fi
    else
        error "✗ VPC ID not found in Terraform outputs"
        json_check "vpc_available" "FAIL" "VPC ID not found"
    fi
    
    # Subnet validation
    check "Validating subnet configuration"
    local public_subnets=$(terraform output -json public_subnet_ids 2>/dev/null | jq -r '.[]?' || echo "")
    local private_subnets=$(terraform output -json private_subnet_ids 2>/dev/null | jq -r '.[]?' || echo "")
    
    local public_count=$(echo "$public_subnets" | wc -l)
    local private_count=$(echo "$private_subnets" | wc -l)
    
    if [[ $public_count -ge 2 ]] && [[ $private_count -ge 2 ]]; then
        success "✓ Sufficient subnets: $public_count public, $private_count private"
        json_check "subnet_count" "PASS" "Public: $public_count, Private: $private_count"
    else
        error "✗ Insufficient subnets: $public_count public, $private_count private"
        json_check "subnet_count" "FAIL" "Insufficient subnet count"
    fi
    
    # Internet Gateway validation
    check "Validating Internet Gateway"
    if [[ -n "$vpc_id" ]]; then
        local igw_id=$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "None")
        if [[ "$igw_id" != "None" ]] && [[ -n "$igw_id" ]]; then
            success "✓ Internet Gateway attached: $igw_id"
            json_check "internet_gateway" "PASS" "IGW $igw_id attached"
        else
            error "✗ Internet Gateway not found"
            json_check "internet_gateway" "FAIL" "IGW not attached"
        fi
    fi
    
    # NAT instance validation
    check "Validating NAT instances"
    local nat_instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Type,Values=NAT" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].{Id:InstanceId,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress}' \
        --output text)
    
    if [[ -n "$nat_instances" ]]; then
        local nat_count=$(echo "$nat_instances" | wc -l)
        success "✓ NAT instances running: $nat_count"
        json_check "nat_instances" "PASS" "$nat_count NAT instances running"
        
        # Test NAT connectivity
        while IFS=$'\t' read -r instance_id public_ip private_ip; do
            if [[ -n "$instance_id" ]]; then
                check "Testing NAT instance connectivity: $instance_id"
                if ping -c 1 -W 5 "$public_ip" >/dev/null 2>&1; then
                    success "✓ NAT instance reachable: $public_ip"
                    json_check "nat_connectivity_$instance_id" "PASS" "NAT instance $public_ip reachable"
                else
                    warning "⚠ NAT instance not responding to ping: $public_ip"
                    json_check "nat_connectivity_$instance_id" "WARN" "NAT instance $public_ip not responding"
                fi
            fi
        done <<< "$nat_instances"
    else
        error "✗ No NAT instances found"
        json_check "nat_instances" "FAIL" "No NAT instances running"
    fi
    
    json_category_end
}

# 2. Compute Instance Validation
validate_compute() {
    info "=== COMPUTE INSTANCE VALIDATION ==="
    json_category_start "compute"
    
    # Service instances validation
    local services=("thingsboard" "signaling" "coturn" "frp")
    
    for service in "${services[@]}"; do
        check "Validating $service instances"
        local instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
            --filters "Name=tag:Service,Values=$service" "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,PrivateIp:PrivateIpAddress}' \
            --output text)
        
        if [[ -n "$instances" ]]; then
            local instance_count=$(echo "$instances" | wc -l)
            success "✓ $service instances running: $instance_count"
            json_check "${service}_instances" "PASS" "$instance_count instances running"
            
            # Check individual instance health
            while IFS=$'\t' read -r instance_id state private_ip; do
                if [[ -n "$instance_id" ]]; then
                    check "Checking $service instance health: $instance_id"
                    
                    # Check if user data completed
                    local console_output=$(aws ec2 get-console-output --instance-id "$instance_id" --region "$AWS_REGION" \
                        --query 'Output' --output text 2>/dev/null || echo "")
                    
                    if echo "$console_output" | grep -q "startup-complete\|Service started successfully"; then
                        success "✓ $service instance startup completed: $instance_id"
                        json_check "${service}_startup_$instance_id" "PASS" "Startup completed"
                    elif echo "$console_output" | grep -q "error\|failed\|ERROR\|FAILED"; then
                        error "✗ $service instance startup errors detected: $instance_id"
                        json_check "${service}_startup_$instance_id" "FAIL" "Startup errors detected"
                    else
                        warning "⚠ $service instance startup status unclear: $instance_id"
                        json_check "${service}_startup_$instance_id" "WARN" "Startup status unclear"
                    fi
                fi
            done <<< "$instances"
        else
            error "✗ No running $service instances found"
            json_check "${service}_instances" "FAIL" "No running instances"
        fi
    done
    
    # Instance connectivity validation
    check "Validating instance connectivity to private subnets"
    local private_instances=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[?starts_with(SubnetId, `subnet-`)].{Id:InstanceId,PrivateIp:PrivateIpAddress,SubnetId:SubnetId}' \
        --output text)
    
    local reachable_instances=0
    local total_private_instances=0
    
    while IFS=$'\t' read -r instance_id private_ip subnet_id; do
        if [[ -n "$instance_id" ]]; then
            ((total_private_instances++))
            # Try to reach the instance via private IP (from another instance would be ideal)
            # For now, we'll check if the instance responds to status checks
            local status_check=$(aws ec2 describe-instance-status --instance-ids "$instance_id" --region "$AWS_REGION" \
                --query 'InstanceStatuses[0].InstanceStatus.Status' --output text 2>/dev/null || echo "unknown")
            
            if [[ "$status_check" == "ok" ]]; then
                ((reachable_instances++))
                success "✓ Instance status OK: $instance_id ($private_ip)"
                json_check "instance_status_$instance_id" "PASS" "Status check OK"
            else
                warning "⚠ Instance status not OK: $instance_id ($status_check)"
                json_check "instance_status_$instance_id" "WARN" "Status: $status_check"
            fi
        fi
    done <<< "$private_instances"
    
    if [[ $total_private_instances -gt 0 ]]; then
        local success_rate=$(echo "scale=0; $reachable_instances * 100 / $total_private_instances" | bc -l)
        info "Instance connectivity: $reachable_instances/$total_private_instances ($success_rate%)"
    fi
    
    json_category_end
}

# 3. Load Balancer Validation
validate_load_balancers() {
    info "=== LOAD BALANCER VALIDATION ==="
    json_category_start "load_balancers"
    
    # Application Load Balancer validation
    check "Validating Application Load Balancer"
    local alb_arn=$(terraform output -raw alb_arn 2>/dev/null || echo "")
    if [[ -n "$alb_arn" ]]; then
        local alb_state=$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" --region "$AWS_REGION" \
            --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "unknown")
        local alb_dns=$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" --region "$AWS_REGION" \
            --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "unknown")
        
        if [[ "$alb_state" == "active" ]]; then
            success "✓ Application Load Balancer is active"
            json_check "alb_state" "PASS" "ALB active with DNS: $alb_dns"
            
            # Test ALB DNS resolution
            check "Testing ALB DNS resolution"
            if dig +short "$alb_dns" | grep -q '^[0-9]'; then
                success "✓ ALB DNS resolves: $alb_dns"
                json_check "alb_dns_resolution" "PASS" "DNS resolution working"
            else
                error "✗ ALB DNS does not resolve: $alb_dns"
                json_check "alb_dns_resolution" "FAIL" "DNS resolution failed"
            fi
        else
            error "✗ Application Load Balancer not active: $alb_state"
            json_check "alb_state" "FAIL" "ALB state: $alb_state"
        fi
    else
        error "✗ Application Load Balancer ARN not found"
        json_check "alb_state" "FAIL" "ALB ARN not found"
    fi
    
    # Network Load Balancer validation
    check "Validating Network Load Balancer"
    local nlb_arn=$(terraform output -raw nlb_arn 2>/dev/null || echo "")
    if [[ -n "$nlb_arn" ]]; then
        local nlb_state=$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb_arn" --region "$AWS_REGION" \
            --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "unknown")
        local nlb_dns=$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb_arn" --region "$AWS_REGION" \
            --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "unknown")
        
        if [[ "$nlb_state" == "active" ]]; then
            success "✓ Network Load Balancer is active"
            json_check "nlb_state" "PASS" "NLB active with DNS: $nlb_dns"
            
            # Test NLB DNS resolution
            check "Testing NLB DNS resolution"
            if dig +short "$nlb_dns" | grep -q '^[0-9]'; then
                success "✓ NLB DNS resolves: $nlb_dns"
                json_check "nlb_dns_resolution" "PASS" "DNS resolution working"
            else
                error "✗ NLB DNS does not resolve: $nlb_dns"
                json_check "nlb_dns_resolution" "FAIL" "DNS resolution failed"
            fi
        else
            error "✗ Network Load Balancer not active: $nlb_state"
            json_check "nlb_state" "FAIL" "NLB state: $nlb_state"
        fi
    else
        warning "⚠ Network Load Balancer ARN not found (may not be deployed)"
        json_check "nlb_state" "WARN" "NLB ARN not found"
    fi
    
    # Target Group Health validation
    check "Validating Target Group Health"
    local target_groups=$(aws elbv2 describe-target-groups --region "$AWS_REGION" \
        --query 'TargetGroups[?starts_with(TargetGroupName, `prod-`)].TargetGroupArn' --output text)
    
    local healthy_targets=0
    local total_targets=0
    
    for tg_arn in $target_groups; do
        local tg_name=$(aws elbv2 describe-target-groups --target-group-arns "$tg_arn" --region "$AWS_REGION" \
            --query 'TargetGroups[0].TargetGroupName' --output text)
        
        check "Checking target group: $tg_name"
        local health_status=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$AWS_REGION" \
            --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}' --output text)
        
        if [[ -n "$health_status" ]]; then
            while IFS=$'\t' read -r target_id health_state; do
                ((total_targets++))
                if [[ "$health_state" == "healthy" ]]; then
                    ((healthy_targets++))
                    success "✓ Target healthy in $tg_name: $target_id"
                else
                    warning "⚠ Target not healthy in $tg_name: $target_id ($health_state)"
                fi
            done <<< "$health_status"
        else
            warning "⚠ No targets found in target group: $tg_name"
        fi
        
        json_check "target_group_$tg_name" "$([ $healthy_targets -gt 0 ] && echo "PASS" || echo "WARN")" "Health status checked"
    done
    
    if [[ $total_targets -gt 0 ]]; then
        local health_rate=$(echo "scale=0; $healthy_targets * 100 / $total_targets" | bc -l)
        info "Target health: $healthy_targets/$total_targets ($health_rate%)"
        json_check "overall_target_health" "$([ $health_rate -ge 50 ] && echo "PASS" || echo "FAIL")" "Health rate: $health_rate%"
    fi
    
    json_category_end
}

# 4. Service Health Validation
validate_services() {
    info "=== SERVICE HEALTH VALIDATION ==="
    json_category_start "services"
    
    # Get service endpoints from load balancer or direct IPs
    local service_endpoints=()
    
    # Try to get ALB endpoint for web services
    local alb_dns=$(terraform output -raw alb_dns_name 2>/dev/null || \
        aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query 'LoadBalancers[?starts_with(LoadBalancerName, `prod-alb`)].DNSName' --output text 2>/dev/null || echo "")
    
    if [[ -n "$alb_dns" ]]; then
        service_endpoints+=("https://$alb_dns:443")
        service_endpoints+=("http://$alb_dns:80")
    fi
    
    # Test service endpoints
    for endpoint in "${service_endpoints[@]}"; do
        check "Testing service endpoint: $endpoint"
        
        local response_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 "$endpoint" 2>/dev/null || echo "000")
        
        if [[ "$response_code" =~ ^[23][0-9][0-9]$ ]]; then
            success "✓ Service endpoint responding: $endpoint ($response_code)"
            json_check "endpoint_${endpoint//[:\/]/_}" "PASS" "HTTP $response_code"
        elif [[ "$response_code" =~ ^[45][0-9][0-9]$ ]]; then
            warning "⚠ Service endpoint error: $endpoint ($response_code)"
            json_check "endpoint_${endpoint//[:\/]/_}" "WARN" "HTTP $response_code"
        else
            error "✗ Service endpoint not responding: $endpoint"
            json_check "endpoint_${endpoint//[:\/]/_}" "FAIL" "No response"
        fi
    done
    
    # Test specific service health endpoints
    local service_health_endpoints=(
        "thingsboard:8080:/login"
        "signaling:3000:/health"
    )
    
    for service_endpoint in "${service_health_endpoints[@]}"; do
        IFS=':' read -r service port path <<< "$service_endpoint"
        
        # Get instance private IP for this service
        local instance_ip=$(aws ec2 describe-instances --region "$AWS_REGION" \
            --filters "Name=tag:Service,Values=$service" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || echo "")
        
        if [[ -n "$instance_ip" ]] && [[ "$instance_ip" != "None" ]]; then
            check "Testing $service health endpoint: $instance_ip:$port$path"
            
            # Note: This test may fail due to security groups or private network access
            # In production, this would typically be tested from within the VPC
            local health_url="http://$instance_ip:$port$path"
            warning "⚠ Direct instance health check not available from external network"
            json_check "${service}_health_endpoint" "WARN" "Private network access required"
        else
            error "✗ No running instance found for $service"
            json_check "${service}_health_endpoint" "FAIL" "No running instance"
        fi
    done
    
    # Docker container validation (would require SSH access)
    check "Docker container health (requires instance access)"
    warning "⚠ Docker container health checks require SSH access to instances"
    warning "  Manual verification recommended:"
    warning "  • SSH to instances and run: docker ps"
    warning "  • Check container logs: docker logs <container_name>"
    warning "  • Verify service ports: netstat -tulpn"
    
    json_check "docker_containers" "WARN" "Manual verification required"
    
    json_category_end
}

# 5. DNS Validation
validate_dns() {
    info "=== DNS VALIDATION ==="
    json_category_start "dns"
    
    local domains=("jupyter.com.au" "www.jupyter.com.au" "video.jupyter.com.au")
    
    for domain in "${domains[@]}"; do
        check "Validating DNS resolution for: $domain"
        
        # Test DNS resolution
        local resolved_ips=$(dig +short "$domain" 2>/dev/null || echo "")
        if [[ -n "$resolved_ips" ]]; then
            success "✓ $domain resolves to: $(echo $resolved_ips | tr '\n' ', ')"
            json_check "dns_resolution_$domain" "PASS" "Resolves to: $resolved_ips"
            
            # Test if resolved IPs are reachable
            local first_ip=$(echo "$resolved_ips" | head -n1)
            check "Testing connectivity to resolved IP: $first_ip"
            
            if ping -c 3 -W 5 "$first_ip" >/dev/null 2>&1; then
                success "✓ Resolved IP is reachable: $first_ip"
                json_check "dns_connectivity_$domain" "PASS" "IP $first_ip reachable"
            else
                warning "⚠ Resolved IP not responding to ping: $first_ip"
                json_check "dns_connectivity_$domain" "WARN" "IP $first_ip not responding"
            fi
        else
            error "✗ $domain does not resolve"
            json_check "dns_resolution_$domain" "FAIL" "No DNS resolution"
        fi
        
        # Test HTTPS connectivity
        check "Testing HTTPS connectivity for: $domain"
        local https_response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 --max-time 30 "https://$domain" 2>/dev/null || echo "000")
        
        if [[ "$https_response" =~ ^[23][0-9][0-9]$ ]]; then
            success "✓ HTTPS working for $domain (HTTP $https_response)"
            json_check "https_$domain" "PASS" "HTTP $https_response"
        elif [[ "$https_response" =~ ^[45][0-9][0-9]$ ]]; then
            warning "⚠ HTTPS error for $domain (HTTP $https_response)"
            json_check "https_$domain" "WARN" "HTTP $https_response"
        else
            error "✗ HTTPS not working for $domain"
            json_check "https_$domain" "FAIL" "No HTTPS response"
        fi
    done
    
    # Route53 health check validation
    check "Validating Route53 health checks"
    local health_checks=$(aws route53 list-health-checks --region "$AWS_REGION" \
        --query 'HealthChecks[?contains(CallerReference, `prod`) || contains(CallerReference, `jupiter`)].{Id:Id,Status:StatusList.Status}' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$health_checks" ]]; then
        while IFS=$'\t' read -r check_id status; do
            if [[ "$status" == "Success" ]]; then
                success "✓ Health check passing: $check_id"
                json_check "route53_health_check_$check_id" "PASS" "Health check passing"
            else
                warning "⚠ Health check not passing: $check_id ($status)"
                json_check "route53_health_check_$check_id" "WARN" "Status: $status"
            fi
        done <<< "$health_checks"
    else
        info "No Route53 health checks found"
        json_check "route53_health_checks" "INFO" "No health checks configured"
    fi
    
    json_category_end
}

# 6. SSL Certificate Validation
validate_ssl() {
    info "=== SSL CERTIFICATE VALIDATION ==="
    json_category_start "ssl"
    
    local domains=("jupyter.com.au" "www.jupyter.com.au" "video.jupyter.com.au")
    
    for domain in "${domains[@]}"; do
        check "Validating SSL certificate for: $domain"
        
        # Get certificate information
        local cert_info=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            openssl x509 -noout -dates -subject -issuer 2>/dev/null || echo "")
        
        if [[ -n "$cert_info" ]]; then
            success "✓ SSL certificate found for $domain"
            
            # Check certificate validity
            local not_after=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2)
            if [[ -n "$not_after" ]]; then
                local expiry_date=$(date -d "$not_after" +%s 2>/dev/null || echo "0")
                local current_date=$(date +%s)
                local days_until_expiry=$(( (expiry_date - current_date) / 86400 ))
                
                if [[ $days_until_expiry -gt 30 ]]; then
                    success "✓ SSL certificate valid for $domain ($days_until_expiry days remaining)"
                    json_check "ssl_validity_$domain" "PASS" "$days_until_expiry days until expiry"
                elif [[ $days_until_expiry -gt 0 ]]; then
                    warning "⚠ SSL certificate expiring soon for $domain ($days_until_expiry days)"
                    json_check "ssl_validity_$domain" "WARN" "$days_until_expiry days until expiry"
                else
                    error "✗ SSL certificate expired for $domain"
                    json_check "ssl_validity_$domain" "FAIL" "Certificate expired"
                fi
            fi
            
            # Check certificate issuer
            local issuer=$(echo "$cert_info" | grep "issuer=" | cut -d= -f2-)
            if echo "$issuer" | grep -q "Let's Encrypt\|Amazon"; then
                success "✓ SSL certificate from trusted CA: $domain"
                json_check "ssl_issuer_$domain" "PASS" "Trusted CA"
            else
                warning "⚠ SSL certificate issuer unclear: $domain ($issuer)"
                json_check "ssl_issuer_$domain" "WARN" "Issuer: $issuer"
            fi
        else
            error "✗ SSL certificate not accessible for $domain"
            json_check "ssl_validity_$domain" "FAIL" "Certificate not accessible"
        fi
        
        # SSL Labs test simulation (basic checks)
        check "Performing basic SSL security checks for: $domain"
        local ssl_protocols=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            grep -E "Protocol|Cipher" | head -2 || echo "")
        
        if echo "$ssl_protocols" | grep -q "TLSv1\.[23]"; then
            success "✓ Modern TLS protocol supported: $domain"
            json_check "ssl_protocol_$domain" "PASS" "Modern TLS supported"
        else
            warning "⚠ SSL protocol check unclear: $domain"
            json_check "ssl_protocol_$domain" "WARN" "Protocol verification needed"
        fi
    done
    
    # ACM certificate validation
    check "Validating ACM certificates"
    local acm_certs=$(aws acm list-certificates --region "$AWS_REGION" \
        --query 'CertificateSummaryList[?contains(DomainName, `jupyter`)].{Arn:CertificateArn,Domain:DomainName,Status:Status}' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$acm_certs" ]]; then
        while IFS=$'\t' read -r cert_arn domain status; do
            if [[ "$status" == "ISSUED" ]]; then
                success "✓ ACM certificate issued: $domain"
                json_check "acm_cert_$domain" "PASS" "Certificate issued"
            else
                warning "⚠ ACM certificate not issued: $domain ($status)"
                json_check "acm_cert_$domain" "WARN" "Status: $status"
            fi
        done <<< "$acm_certs"
    else
        warning "⚠ No ACM certificates found"
        json_check "acm_certificates" "WARN" "No ACM certificates found"
    fi
    
    json_category_end
}

# 7. Security Validation
validate_security() {
    info "=== SECURITY VALIDATION ==="
    json_category_start "security"
    
    # Security group validation
    check "Validating security group configuration"
    local security_groups=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" \
        --query 'SecurityGroups[].{Id:GroupId,Name:GroupName}' --output text)
    
    local sg_count=0
    while IFS=$'\t' read -r sg_id sg_name; do
        if [[ -n "$sg_id" ]]; then
            ((sg_count++))
            
            # Check for overly permissive rules (0.0.0.0/0 on non-standard ports)
            local open_rules=$(aws ec2 describe-security-groups --group-ids "$sg_id" --region "$AWS_REGION" \
                --query 'SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp==`0.0.0.0/0`] && FromPort!=`80` && FromPort!=`443`].FromPort' \
                --output text 2>/dev/null || echo "")
            
            if [[ -z "$open_rules" ]]; then
                success "✓ Security group properly configured: $sg_name"
                json_check "security_group_$sg_name" "PASS" "No overly permissive rules"
            else
                warning "⚠ Security group has open ports: $sg_name (ports: $open_rules)"
                json_check "security_group_$sg_name" "WARN" "Open ports: $open_rules"
            fi
        fi
    done <<< "$security_groups"
    
    info "Total production security groups: $sg_count"
    
    # IAM role validation
    check "Validating IAM roles and policies"
    local ec2_roles=$(aws iam list-roles \
        --query 'Roles[?contains(RoleName, `prod`) || contains(RoleName, `ec2`)].RoleName' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$ec2_roles" ]]; then
        success "✓ Production IAM roles found: $(echo $ec2_roles | wc -w)"
        json_check "iam_roles" "PASS" "Production roles configured"
    else
        warning "⚠ No production IAM roles found"
        json_check "iam_roles" "WARN" "No production roles found"
    fi
    
    # Check for public instances in private subnets
    check "Validating instance placement security"
    local public_instances_in_private=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=prod" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[?PublicIpAddress && starts_with(SubnetId, `subnet-`)].{Id:InstanceId,Subnet:SubnetId,PublicIp:PublicIpAddress}' \
        --output text)
    
    if [[ -z "$public_instances_in_private" ]]; then
        success "✓ No instances with public IPs in private subnets"
        json_check "instance_placement_security" "PASS" "Proper instance placement"
    else
        warning "⚠ Instances with public IPs found (verify if intentional):"
        echo "$public_instances_in_private"
        json_check "instance_placement_security" "WARN" "Public IPs on instances detected"
    fi
    
    json_category_end
}

# 8. Performance Validation
validate_performance() {
    info "=== PERFORMANCE VALIDATION ==="
    json_category_start "performance"
    
    # Response time validation
    local test_urls=("https://jupyter.com.au" "https://www.jupyter.com.au")
    
    for url in "${test_urls[@]}"; do
        check "Testing response time for: $url"
        
        local response_time=$(curl -s -o /dev/null -w "%{time_total}" --connect-timeout 10 --max-time 30 "$url" 2>/dev/null || echo "999")
        local response_time_ms=$(echo "$response_time * 1000" | bc -l | cut -d. -f1)
        
        if [[ $response_time_ms -lt 2000 ]]; then
            success "✓ Good response time for $url: ${response_time_ms}ms"
            json_check "response_time_$url" "PASS" "${response_time_ms}ms"
        elif [[ $response_time_ms -lt 5000 ]]; then
            warning "⚠ Slow response time for $url: ${response_time_ms}ms"
            json_check "response_time_$url" "WARN" "${response_time_ms}ms"
        else
            error "✗ Very slow or failed response for $url: ${response_time_ms}ms"
            json_check "response_time_$url" "FAIL" "${response_time_ms}ms"
        fi
    done
    
    # Load balancer performance
    check "Validating load balancer performance"
    local alb_metrics=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/ApplicationELB \
        --metric-name TargetResponseTime \
        --dimensions Name=LoadBalancer,Value="$(terraform output -raw alb_arn_suffix 2>/dev/null | cut -d/ -f2-)" \
        --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
        --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
        --period 300 \
        --statistics Average \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    if [[ -n "$alb_metrics" ]]; then
        success "✓ Load balancer metrics available"
        json_check "load_balancer_metrics" "PASS" "Metrics available"
    else
        info "Load balancer metrics not yet available (may be too early)"
        json_check "load_balancer_metrics" "INFO" "Metrics not available"
    fi
    
    json_category_end
}

# Main validation execution
main() {
    local start_time=$(date +%s)
    
    info "Starting comprehensive Jupiter infrastructure validation"
    info "Log file: $LOG_FILE"
    info "Report file: $REPORT_FILE"
    
    json_start
    
    # Execute all validation categories
    validate_infrastructure
    validate_compute
    validate_load_balancers
    validate_services
    validate_dns
    validate_ssl
    validate_security
    validate_performance
    
    json_end
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    # Final summary
    info "=== VALIDATION SUMMARY ==="
    success "Validation completed in ${minutes}m ${seconds}s"
    
    local success_rate=0
    if [[ $TOTAL_CHECKS -gt 0 ]]; then
        success_rate=$(echo "scale=1; $PASSED_CHECKS * 100 / $TOTAL_CHECKS" | bc -l)
    fi
    
    info "Total Checks: $TOTAL_CHECKS"
    success "Passed: $PASSED_CHECKS (${success_rate}%)"
    warning "Warnings: $WARNING_CHECKS"
    error "Failed: $FAILED_CHECKS"
    
    echo ""
    if [[ $FAILED_CHECKS -eq 0 ]] && [[ $WARNING_CHECKS -le 3 ]]; then
        success "🎉 VALIDATION PASSED - Infrastructure is healthy!"
        info "The Jupiter infrastructure is ready for production use"
        echo 0
    elif [[ $FAILED_CHECKS -le 2 ]] && [[ $WARNING_CHECKS -le 10 ]]; then
        warning "⚠️  VALIDATION PASSED WITH WARNINGS"
        warning "Infrastructure is functional but has some issues to address"
        echo 1
    else
        error "❌ VALIDATION FAILED - Critical issues detected"
        error "Infrastructure needs attention before production use"
        echo 2
    fi
    
    info "Detailed validation report: $REPORT_FILE"
    info "Full validation log: $LOG_FILE"
}

# Command line help
case "${1:-}" in
    --help|-h)
        echo "Jupiter Infrastructure Validation Script"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h       Show this help message"
        echo "  --category NAME  Run only specific validation category"
        echo "  --report-only    Generate report file only"
        echo ""
        echo "Validation Categories:"
        echo "  infrastructure   VPC, subnets, NAT instances"
        echo "  compute         EC2 instances and services"
        echo "  load_balancers  ALB and NLB health"
        echo "  services        Service endpoints and health"
        echo "  dns             Domain resolution and routing"
        echo "  ssl             Certificate validation"
        echo "  security        Security groups and IAM"
        echo "  performance     Response times and metrics"
        echo ""
        echo "Exit Codes:"
        echo "  0  All validations passed"
        echo "  1  Validations passed with warnings"
        echo "  2  Critical validations failed"
        exit 0
        ;;
    --category)
        case "$2" in
            infrastructure) validate_infrastructure; exit $? ;;
            compute) validate_compute; exit $? ;;
            load_balancers) validate_load_balancers; exit $? ;;
            services) validate_services; exit $? ;;
            dns) validate_dns; exit $? ;;
            ssl) validate_ssl; exit $? ;;
            security) validate_security; exit $? ;;
            performance) validate_performance; exit $? ;;
            *) error "Unknown category: $2"; exit 1 ;;
        esac
        ;;
    --report-only)
        info "Generating validation report..."
        main > /dev/null
        cat "$REPORT_FILE"
        exit 0
        ;;
esac

# Execute main validation
exit_code=$(main)
exit $exit_code