#!/bin/bash
set -e

echo "=================================="
echo "Jupiter Infrastructure Deployment"
echo "=================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Validate environment
echo -e "${YELLOW}Validating environment...${NC}"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}AWS CLI not found. Please install it first.${NC}"
    exit 1
fi

# Check Terraform
if ! command -v terraform &> /dev/null; then
    echo -e "${YELLOW}Installing Terraform...${NC}"
    wget https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip
    unzip terraform_1.5.7_linux_amd64.zip
    sudo mv terraform /usr/local/bin/
    rm terraform_1.5.7_linux_amd64.zip
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}AWS credentials not configured.${NC}"
    exit 1
fi

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}✓ Environment validated${NC}"
echo "  Region: $REGION"
echo "  Account: $ACCOUNT_ID"

# Create backend bucket if it doesn't exist
BUCKET_NAME="jupiter-terraform-state-${ACCOUNT_ID}"
if ! aws s3 ls "s3://${BUCKET_NAME}" 2>/dev/null; then
    echo -e "${YELLOW}Creating S3 backend bucket...${NC}"
    aws s3 mb "s3://${BUCKET_NAME}" --region ${REGION}
    aws s3api put-bucket-versioning \
        --bucket ${BUCKET_NAME} \
        --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption \
        --bucket ${BUCKET_NAME} \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
    echo -e "${GREEN}✓ Backend bucket created${NC}"
fi

# Create DynamoDB table for state locking
TABLE_NAME="jupiter-terraform-lock"
if ! aws dynamodb describe-table --table-name ${TABLE_NAME} &> /dev/null; then
    echo -e "${YELLOW}Creating DynamoDB lock table...${NC}"
    aws dynamodb create-table \
        --table-name ${TABLE_NAME} \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region ${REGION}
    echo -e "${GREEN}✓ Lock table created${NC}"
fi

# Create key pair if it doesn't exist
KEY_NAME="jupiter-key"
if ! aws ec2 describe-key-pairs --key-names ${KEY_NAME} &> /dev/null 2>&1; then
    echo -e "${YELLOW}Creating EC2 key pair...${NC}"
    aws ec2 create-key-pair \
        --key-name ${KEY_NAME} \
        --query 'KeyMaterial' \
        --output text > ${KEY_NAME}.pem
    chmod 400 ${KEY_NAME}.pem
    echo -e "${GREEN}✓ Key pair created: ${KEY_NAME}.pem${NC}"
fi

# Initialize Terraform with backend config
echo -e "${YELLOW}Initializing Terraform...${NC}"
cat > backend.tf << BACKEND
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "prod/terraform.tfstate"
    region         = "${REGION}"
    encrypt        = true
    dynamodb_table = "${TABLE_NAME}"
  }
}
BACKEND

terraform init -reconfigure

# Create terraform.tfvars if it doesn't exist
if [ ! -f terraform.tfvars ]; then
    cat > terraform.tfvars << TFVARS
aws_region   = "${REGION}"
environment  = "prod"
vpc_cidr     = "10.0.0.0/16"
key_name     = "${KEY_NAME}"
domain_name  = "jupyter.com.au"
alarm_email  = "temi.akinloye@jupyter.com.au"
TFVARS
    echo -e "${GREEN}✓ terraform.tfvars created${NC}"
fi

# Run Terraform plan
echo -e "${YELLOW}Planning infrastructure...${NC}"
terraform plan -out=tfplan

# Confirm deployment
echo -e "${YELLOW}Ready to deploy. This will create:${NC}"
echo "  - 1 VPC with 6 subnets"
echo "  - 2 NAT instances"
echo "  - 4 service instances (signaling, coturn, frp, thingsboard)"
echo "  - 2 load balancers (ALB and NLB)"
echo "  - Route53 DNS records"
echo "  - CloudWatch monitoring"
echo ""
read -p "Deploy now? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

# Apply Terraform
echo -e "${YELLOW}Deploying infrastructure...${NC}"
terraform apply tfplan

# Get outputs
echo -e "${GREEN}=================================="
echo "Deployment Complete!"
echo "==================================${NC}"
terraform output -json | jq .

# Wait for services to start
echo -e "${YELLOW}Waiting for services to initialize (2-3 minutes)...${NC}"
sleep 120

# Validate deployment
echo -e "${YELLOW}Validating deployment...${NC}"

# Check load balancers
ALB_DNS=$(terraform output -raw load_balancer_dns | jq -r .alb)
NLB_DNS=$(terraform output -raw load_balancer_dns | jq -r .nlb)

if curl -s -o /dev/null -w "%{http_code}" https://${ALB_DNS} | grep -q "200\|301\|302"; then
    echo -e "${GREEN}✓ ALB is responding${NC}"
else
    echo -e "${RED}✗ ALB not responding${NC}"
fi

echo -e "${GREEN}=================================="
echo "Infrastructure deployed successfully!"
echo "==================================${NC}"
echo ""
echo "Access points:"
echo "  Main site: https://jupyter.com.au"
echo "  Video service: https://video.jupyter.com.au"
echo "  ThingsBoard: https://jupyter.com.au:8080"
echo ""
echo "To destroy: ./destroy.sh"
