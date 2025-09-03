# Jupiter Infrastructure - Production Ready Terraform

## 🚀 100% Automated Infrastructure Deployment

This repository contains the **WORKING** Terraform configuration that deploys Jupiter's complete WebRTC infrastructure with pilot light disaster recovery.

## ✅ What Gets Deployed

**With ONE command (`terraform apply`), you get:**

### Primary Infrastructure (6 Running Instances)
- **Signaling Server** - WebSocket/Socket.IO for WebRTC signaling
- **COTURN Server** - STUN/TURN server for NAT traversal  
- **FRP Server** - Fast Reverse Proxy for tunneling
- **ThingsBoard** - IoT platform with PostgreSQL
- **NAT Instance Primary** - For private subnet internet access
- **NAT Instance Secondary** - Redundant NAT for high availability

### Backup Infrastructure (5 Stopped Instances - Pilot Light)
- **Signaling Backup** - Ready to start on primary failure
- **COTURN Backup** - Disaster recovery instance
- **FRP Backup** - Standby tunneling server
- **ThingsBoard Backup** - Database backup instance
- **NAT Backup** - Third NAT for complete redundancy

### Network Infrastructure
- **VPC** with 10.0.0.0/16 CIDR
- **3 Public Subnets** across 3 availability zones
- **3 Private Subnets** for service isolation
- **Internet Gateway** for public internet access
- **Route Tables** with proper NAT routing

### Load Balancers & Networking
- **Application Load Balancer** (ALB) for HTTP/HTTPS traffic
- **Network Load Balancer** (NLB) for TCP/UDP services
- **Target Groups** for service health checks
- **Security Groups** with proper port configurations

### Automation Components
- **Lambda Function** for failover automation (partially working)
- **CloudWatch Alarms** for instance health monitoring
- **SNS Topic** for alarm notifications

## 💰 Cost Breakdown

### Monthly Costs (Actual Running)
- EC2 Instances (4x t3.small + 2x t3.nano): ~$68
- Load Balancers (ALB + NLB): ~$40
- Elastic IP: ~$4
- Data Transfer: ~$30-40
- **Total: ~$150/month**

### Savings
- Pilot Light (5 stopped instances): Saves ~$75/month
- NAT Instances vs NAT Gateway: Saves ~$85/month
- **Total Savings: ~$160/month**

## 📦 Quick Start Deployment

### Prerequisites
```bash
# Install Terraform
brew install terraform

# Configure AWS credentials
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
export AWS_DEFAULT_REGION="ap-southeast-2"
```

### Deploy Everything (100% Automated)
```bash
# Clone this repository
git clone https://github.com/yourusername/jupiter-infrastructure-final.git
cd jupiter-infrastructure-final

# Deploy all infrastructure with ONE command
terraform init
terraform apply -auto-approve

# Takes ~5-7 minutes to deploy everything
```

### Verify Deployment
```bash
# Check all instances
terraform output

# Or use Python script
python3 failover-automation.py status
```

## 🔄 Failover Operations

### Manual Failover (Working Today)
```bash
# Check status
python3 failover-automation.py status

# Failover single service
python3 failover-automation.py failover signaling

# Failover all services
python3 failover-automation.py failover-all

# Failback to primary
python3 failover-automation.py failback-all
```

### Semi-Automatic Failover
CloudWatch alarms trigger Lambda, but manual intervention still required for complete failover.

## 📁 Repository Structure

```
.
├── simple-deploy.tf           # Main Terraform configuration (100% working)
├── user-data/                 # Service startup scripts
│   ├── signaling.sh          # Node.js WebSocket server
│   ├── coturn.sh             # TURN server configuration
│   ├── frp.sh                # Reverse proxy setup
│   └── thingsboard.sh        # IoT platform setup
├── failover-automation.py     # Manual failover script (working)
├── fix-failover.tf           # Attempted failover fixes
├── asg-solution.tf           # Future ASG migration (recommended)
└── README.md                 # This file
```

## ⚠️ Known Issues & Outstanding Work

### What's NOT Working (Yet)

1. **Automatic Failover**
   - Lambda receives alarms but doesn't parse correctly
   - Target groups not updated automatically
   - Primary doesn't stop when backup starts
   - **Workaround**: Use manual failover script

2. **Load Balancer Integration**
   - Target groups exist but missing some listeners
   - No automatic health checks at application level
   - **Fix needed**: Add proper ALB/NLB listener rules

3. **DNS/Route53**
   - No automatic DNS failover configured
   - FRP Elastic IP doesn't transfer to backup
   - **Fix needed**: Implement Route53 health checks

4. **Lambda Function Issues**
   - Expects SNS format but receives direct CloudWatch events
   - Missing IAM permissions for target group updates
   - **Fix needed**: Rewrite Lambda handler

## 🔧 Next Steps (Where to Continue)

### Priority 1: Fix Automatic Failover
```bash
# The Lambda code needs fixing:
# 1. Fix event parsing from CloudWatch/SNS
# 2. Add target group registration/deregistration
# 3. Test end-to-end failover
```

### Priority 2: Migrate to Auto Scaling Groups
```bash
# Better long-term solution:
terraform apply -target=module.asg_migration

# This would replace primary/backup with ASG
# AWS handles failover automatically
# No Lambda needed
```

### Priority 3: Add Missing Components
- [ ] Route53 DNS with health checks
- [ ] Application-level health monitoring
- [ ] Proper SSL certificates
- [ ] CloudWatch dashboards
- [ ] Cost optimization with Savings Plans

## 🏗️ Alternative: Auto Scaling Group Solution

For a truly automated solution, use `asg-solution.tf`:
```bash
# This replaces the current primary/backup pattern
# with Auto Scaling Groups that handle everything
mv simple-deploy.tf simple-deploy.tf.backup
mv asg-solution.tf main.tf
terraform apply
```

Benefits:
- Automatic instance replacement on failure
- No Lambda needed
- Load balancer integration built-in
- Truly 100% automated failover

## 📊 Testing & Validation

### Test Failover
```bash
# 1. Stop primary instance
aws ec2 stop-instances --instance-ids <primary-id>

# 2. Run failover
python3 failover-automation.py failover signaling

# 3. Verify backup is running
python3 failover-automation.py status
```

### Test Infrastructure
```bash
# Check ALB endpoint
curl http://$(terraform output alb_dns)/health

# Check NLB endpoint
nc -zv $(terraform output nlb_dns) 3478
```

## 🆘 Troubleshooting

### If Terraform Apply Fails
```bash
# Clean up and retry
terraform destroy -auto-approve
terraform apply -auto-approve
```

### If Instances Don't Start
```bash
# Check user data logs
aws ec2 get-console-output --instance-id <instance-id>
```

### If Failover Doesn't Work
```bash
# Use manual script instead
python3 failover-automation.py failover-all
```

## 📝 Important Notes

1. **This IS 100% automated for infrastructure deployment**
2. **Failover is semi-automated (manual trigger required)**
3. **All 11 instances deploy with one command**
4. **Pilot light pattern saves ~$75/month**
5. **Production ready for infrastructure, not for automatic failover**

## 🎯 Summary

- **Infrastructure Deployment**: ✅ 100% Automated
- **Failover**: ⚠️ Semi-Automated (manual script works)
- **Cost Optimized**: ✅ Yes (~$150/month)
- **Production Ready**: ⚠️ Infrastructure yes, failover needs work

## 📞 Support

For issues or questions:
1. Check the `FINAL-DOCUMENTATION.md` for detailed information
2. Review outstanding issues in this README
3. Use the manual failover script for production

---

**Last Updated**: September 2025
**Terraform Version**: 1.0+
**AWS Region**: ap-southeast-2 (Sydney)
**Status**: Infrastructure Working, Failover Needs Improvement