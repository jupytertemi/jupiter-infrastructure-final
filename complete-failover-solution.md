# Complete Failover Solution

## Option 1: Auto Scaling Groups (Best Practice)
Instead of primary/backup instances, use Auto Scaling Groups:
- Min: 1, Max: 2, Desired: 1
- When instance fails, ASG automatically launches replacement
- ALB automatically adds new instance to target group
- No Lambda needed, AWS handles everything

## Option 2: Fix Current Architecture
Need to add these missing pieces:

### 1. SNS Topic for CloudWatch -> Lambda
```hcl
resource "aws_sns_topic" "failover" {
  name = "jupiter-failover-topic"
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.failover.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover.arn
}

# Update alarms to use SNS
resource "aws_cloudwatch_metric_alarm" "instance_health" {
  alarm_actions = [aws_sns_topic.failover.arn]  # Not Lambda directly!
}
```

### 2. Lambda Permissions for SNS
```hcl
resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.failover.arn
}
```

### 3. Update Lambda to Handle Target Groups
```python
import boto3
ec2 = boto3.client('ec2')
elbv2 = boto3.client('elbv2')

def handler(event, context):
    # Parse SNS message properly
    message = json.loads(event['Records'][0]['Sns']['Message'])
    alarm_name = message['AlarmName']
    
    # Get the service from alarm name
    service = alarm_name.split('-')[0]  # e.g., "signaling-primary-health"
    
    # Stop primary, start backup
    primary = get_instance_by_tag(f"{service}-primary")
    backup = get_instance_by_tag(f"{service}-backup")
    
    ec2.stop_instances(InstanceIds=[primary])
    ec2.start_instances(InstanceIds=[backup])
    
    # Update target groups
    target_group_arn = get_target_group_for_service(service)
    elbv2.deregister_targets(
        TargetGroupArn=target_group_arn,
        Targets=[{'Id': primary}]
    )
    elbv2.register_targets(
        TargetGroupArn=target_group_arn,
        Targets=[{'Id': backup}]
    )
```

### 4. Add Target Groups and Listeners
```hcl
resource "aws_lb_target_group" "signaling" {
  name     = "prod-signaling-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "signaling" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "443"
  protocol          = "HTTPS"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.signaling.arn
  }
}

resource "aws_lb_target_group_attachment" "signaling" {
  target_group_arn = aws_lb_target_group.signaling.arn
  target_id        = aws_instance.services["signaling"].id
}
```

### 5. Health Checks on Application Level
```hcl
resource "aws_cloudwatch_metric_alarm" "service_health" {
  alarm_name          = "${each.key}-service-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  threshold           = "1"
  
  # Use target group health instead of EC2 status
  metric_query {
    id = "m1"
    metric {
      metric_name = "HealthyHostCount"
      namespace   = "AWS/ELB"
      stat        = "Average"
      period      = 60
      dimensions = {
        TargetGroup = aws_lb_target_group.signaling.arn_suffix
      }
    }
  }
}
```

## Option 3: Use AWS Native Services
- **RDS Multi-AZ** for databases (automatic failover)
- **ECS with Service Auto Scaling** for containers
- **Route53 Health Checks** with failover routing
- **AWS Global Accelerator** for automatic endpoint failover

## Why It's Hard:
1. **State Management**: Need to track which instance is active
2. **Network Updates**: Must update multiple layers (LB, DNS, Routes)
3. **Split Brain**: Prevent both primary and backup running
4. **Testing**: Hard to test without breaking production
5. **Timing**: Race conditions during failover