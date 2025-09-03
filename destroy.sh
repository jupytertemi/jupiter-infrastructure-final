#!/bin/bash
set -e

echo "=================================="
echo "Jupiter Infrastructure Destruction"
echo "=================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}WARNING: This will destroy ALL infrastructure!${NC}"
echo "This includes:"
echo "  - All EC2 instances"
echo "  - Load balancers"
echo "  - VPC and networking"
echo "  - DNS records"
echo ""
read -p "Type 'destroy-jupiter' to confirm: " CONFIRM

if [ "$CONFIRM" != "destroy-jupiter" ]; then
    echo "Destruction cancelled."
    exit 0
fi

echo -e "${YELLOW}Creating backup of current state...${NC}"
terraform state pull > terraform.state.backup.$(date +%Y%m%d-%H%M%S).json

echo -e "${YELLOW}Destroying infrastructure...${NC}"
terraform destroy -auto-approve

echo -e "${GREEN}Infrastructure destroyed.${NC}"
echo ""
echo "Note: The following may still exist:"
echo "  - S3 backend bucket"
echo "  - DynamoDB lock table"
echo "  - EC2 key pair"
echo "  - Route53 hosted zone"
echo ""
echo "To remove these, run: ./cleanup-all.sh"
