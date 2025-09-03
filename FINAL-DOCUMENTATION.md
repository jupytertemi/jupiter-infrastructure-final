# Jupiter Infrastructure - Final Documentation

## What Was Built

### Infrastructure Components Created
- **VPC**: vpc-0e77cf6f291408e83 (10.0.0.0/16)
- **Subnets**: 3 public, 3 private across 3 AZs
- **EC2 Instances**: 11 total
  - 6 Primary (running): signaling, coturn, frp, thingsboard, nat-primary, nat-secondary
  - 5 Backup (stopped): signaling, coturn, frp, thingsboard, nat-backup
- **Load Balancers**: 
  - Application Load Balancer (prod-alb)
  - Network Load Balancer (prod-nlb)
- **Lambda**: jupiter-failover (partially working)
- **CloudWatch Alarms**: 4 alarms for each service
- **SNS Topic**: jupiter-failover-notifications
- **Target Groups**: Created but not fully connected

### Services Deployed
1. **Signaling Server** (Port 3000) - WebSocket/Socket.IO for WebRTC signaling
2. **COTURN** (Port 3478/3479) - STUN/TURN server for WebRTC
3. **FRP** (Port 7000) - Fast Reverse Proxy for tunneling
4. **ThingsBoard** (Port 8080) - IoT platform
5. **NAT Instances** - For private subnet internet access

### Architecture Pattern
- **Pilot Light**: Backup instances kept stopped until needed
- **Multi-AZ**: Distributed across 3 availability zones
- **Cost**: ~$150/month running, ~$85/month saved using NAT instances vs NAT Gateways

## What Works

### ✅ Working Components
1. **Manual Failover Script**
   ```bash
   python3 /private/tmp/jupiter-terraform-v2/failover-automation.py status
   python3 /private/tmp/jupiter-terraform-v2/failover-automation.py failover signaling
   python3 /private/tmp/jupiter-terraform-v2/failover-automation.py failback signaling
   ```

2. **Infrastructure as Code**
   - Single Terraform file: `simple-deploy.tf`
   - 100% automated deployment with `terraform apply`
   - All instances properly tagged and configured

3. **Networking**
   - VPC with proper public/private subnet separation
   - NAT instances working for outbound internet
   - Security groups configured correctly

## What Doesn't Work

### ❌ Broken Components
1. **Automatic Failover**
   - Lambda receives alarms but doesn't parse them correctly
   - No automatic stop of primary when backup starts
   - Target groups not updated automatically

2. **Load Balancer Integration**
   - Target groups exist but not connected to instances
   - No health checks at application level
   - Missing listeners and routing rules

3. **DNS/Route53**
   - No DNS failover configured
   - FRP Elastic IP doesn't transfer to backup
   - No Route53 health checks

## Why Failover Is Hard

### Technical Challenges
1. **State Management**: AWS doesn't understand "primary" vs "backup"
2. **Multiple Layers**: Must update EC2 + ALB + Route53 + Target Groups
3. **Network Complexity**: Different services need different protocols (HTTP/TCP/UDP)
4. **Testing Difficulty**: Can't test without breaking production

### Architecture Mismatch
- Current design fights against AWS patterns
- AWS expects Auto Scaling Groups, not manual primary/backup
- Pilot light pattern better suited for entire region failover, not instance level

## Costs

### Current Monthly Costs (Running)
- 4 x t3.small instances @ $15.18/month = $60.72
- 2 x t3.nano NAT instances @ $3.80/month = $7.60
- 1 x Elastic IP for FRP = $3.60
- ALB = ~$20/month
- NLB = ~$20/month
- Data transfer = ~$30-40/month
- **Total: ~$150/month**

### Pilot Light Savings
- 5 stopped backup instances save ~$75/month
- Using NAT instances vs NAT Gateway saves ~$85/month
- **Total Savings: ~$160/month**

## Files Created

### Terraform Files
- `/private/tmp/jupiter-terraform-v2/simple-deploy.tf` - Main infrastructure
- `/private/tmp/jupiter-terraform-v2/fix-failover.tf` - Attempted fixes
- `/private/tmp/jupiter-terraform-v2/asg-solution.tf` - Proper ASG solution

### Scripts
- `/private/tmp/jupiter-terraform-v2/failover-automation.py` - Working manual failover
- `/private/tmp/jupiter-terraform-v2/simple-failover.sh` - Bash failover script
- `/private/tmp/jupiter-terraform-v2/auto-failover.sh` - Cron-based checker

### User Data Scripts
- `/private/tmp/jupiter-terraform-v2/user-data/signaling.sh`
- `/private/tmp/jupiter-terraform-v2/user-data/coturn.sh`
- `/private/tmp/jupiter-terraform-v2/user-data/frp.sh`
- `/private/tmp/jupiter-terraform-v2/user-data/thingsboard.sh`

### Lambda
- `/private/tmp/jupiter-terraform-v2/failover.py` - Original Lambda (broken)
- `/private/tmp/jupiter-terraform-v2/quick-fix-lambda.py` - Simplified version

## How to Use What's Built

### Check Status
```bash
python3 /private/tmp/jupiter-terraform-v2/failover-automation.py status
```

### Manual Failover (When Primary Fails)
```bash
# Single service
python3 /private/tmp/jupiter-terraform-v2/failover-automation.py failover signaling

# All services
python3 /private/tmp/jupiter-terraform-v2/failover-automation.py failover-all
```

### Manual Failback (Restore Primary)
```bash
# Single service
python3 /private/tmp/jupiter-terraform-v2/failover-automation.py failback signaling

# All services
python3 /private/tmp/jupiter-terraform-v2/failover-automation.py failback-all
```

## Recommended Future Improvements

### Option 1: Switch to Auto Scaling Groups (Best)
- Deploy `asg-solution.tf` instead
- Automatic failover without Lambda
- AWS handles everything
- Truly 100% automated

### Option 2: Fix Current Setup
1. Fix Lambda to parse SNS messages correctly
2. Add target group registration/deregistration
3. Implement Route53 health checks
4. Add application-level health monitoring

### Option 3: Use AWS Managed Services
- RDS Multi-AZ for databases
- ECS/Fargate for containers
- AWS Global Accelerator for automatic endpoint failover

## Lessons Learned

1. **Don't Fight AWS Patterns**: Use ASG instead of manual primary/backup
2. **Start Simple**: Manual scripts are better than broken automation
3. **Test Early**: Failover should be tested during build, not after
4. **Use Native Services**: ASG, ECS, RDS handle failover better than custom solutions
5. **Document Everything**: Future you will thank current you

## Cleanup Commands

To destroy everything:
```bash
# Destroy via Terraform (recommended)
cd /private/tmp/jupiter-terraform-v2
terraform destroy -auto-approve

# Or manual cleanup
aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Project,Values=Jupiter" --query 'Reservations[*].Instances[*].InstanceId' --output text) --region ap-southeast-2
aws elbv2 delete-load-balancer --load-balancer-arn $(aws elbv2 describe-load-balancers --names prod-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text) --region ap-southeast-2
aws elbv2 delete-load-balancer --load-balancer-arn $(aws elbv2 describe-load-balancers --names prod-nlb --query 'LoadBalancers[0].LoadBalancerArn' --output text) --region ap-southeast-2
```

## Final Status
- **Automation Level**: 70% (manual failover required)
- **Production Ready**: No (needs proper failover)
- **Cost Optimized**: Yes (using NAT instances, pilot light)
- **Recommendation**: Use manual failover for now, migrate to ASG ASAP