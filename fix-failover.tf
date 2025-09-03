# FIX FAILOVER - Add missing components to make it work

# 1. SNS Topic for alarm notifications
resource "aws_sns_topic" "failover" {
  name = "jupiter-failover-notifications"
}

# 2. Lambda permission for SNS
resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.failover.arn
}

# 3. SNS subscription to Lambda
resource "aws_sns_topic_subscription" "lambda_failover" {
  topic_arn = aws_sns_topic.failover.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover.arn
}

# 4. Target Groups for each service
resource "aws_lb_target_group" "signaling" {
  name     = "prod-signaling-tg-new"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/health"
  }
}

resource "aws_lb_target_group" "thingsboard" {
  name     = "prod-thingsboard-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
  }
}

resource "aws_lb_target_group" "coturn_tcp" {
  name     = "prod-coturn-tcp-tg"
  port     = 3478
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    protocol            = "TCP"
  }
}

resource "aws_lb_target_group" "frp" {
  name     = "prod-frp-tg"
  port     = 7000
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    protocol            = "TCP"
  }
}

# 5. ALB Listeners
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Service not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "signaling" {
  listener_arn = aws_lb_listener.http.arn
  
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.signaling.arn
  }
  
  condition {
    path_pattern {
      values = ["/signaling/*", "/socket.io/*"]
    }
  }
}

resource "aws_lb_listener_rule" "thingsboard" {
  listener_arn = aws_lb_listener.http.arn
  
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.thingsboard.arn
  }
  
  condition {
    path_pattern {
      values = ["/thingsboard/*", "/api/*"]
    }
  }
}

# 6. NLB Listeners for TCP services
resource "aws_lb_listener" "coturn" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = "3478"
  protocol          = "TCP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.coturn_tcp.arn
  }
}

resource "aws_lb_listener" "frp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = "7000"
  protocol          = "TCP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frp.arn
  }
}

# 7. Target Group Attachments (primary instances)
resource "aws_lb_target_group_attachment" "signaling_primary" {
  target_group_arn = aws_lb_target_group.signaling.arn
  target_id        = aws_instance.services["signaling"].id
  port             = 3000
}

resource "aws_lb_target_group_attachment" "thingsboard_primary" {
  target_group_arn = aws_lb_target_group.thingsboard.arn
  target_id        = aws_instance.services["thingsboard"].id
  port             = 8080
}

resource "aws_lb_target_group_attachment" "coturn_primary" {
  target_group_arn = aws_lb_target_group.coturn_tcp.arn
  target_id        = aws_instance.services["coturn"].id
  port             = 3478
}

resource "aws_lb_target_group_attachment" "frp_primary" {
  target_group_arn = aws_lb_target_group.frp.arn
  target_id        = aws_instance.services["frp"].id
  port             = 7000
}

# 8. Update CloudWatch alarms to use SNS
resource "aws_cloudwatch_metric_alarm" "instance_health_fixed" {
  for_each = aws_instance.services
  
  alarm_name          = "${each.key}-health-check"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "StatusCheckFailed"
  namespace          = "AWS/EC2"
  period             = "60"
  statistic          = "Average"
  threshold          = "1"
  alarm_description  = "Trigger failover when ${each.key} fails"
  
  dimensions = {
    InstanceId = each.value.id
  }
  
  alarm_actions = [aws_sns_topic.failover.arn]  # Use SNS, not Lambda directly
}

# 9. Updated Lambda function code
resource "aws_lambda_function" "failover_fixed" {
  filename      = "failover-fixed.zip"
  function_name = "jupiter-failover-fixed"
  role          = aws_iam_role.lambda_failover.arn
  handler       = "index.handler"
  runtime       = "python3.9"
  timeout       = 120
  
  environment {
    variables = {
      BACKUP_SIGNALING   = aws_instance.backup_services["signaling"].id
      BACKUP_COTURN      = aws_instance.backup_services["coturn"].id
      BACKUP_FRP         = aws_instance.backup_services["frp"].id
      BACKUP_THINGSBOARD = aws_instance.backup_services["thingsboard"].id
      BACKUP_NAT         = aws_instance.nat_backup.id
      TG_SIGNALING       = aws_lb_target_group.signaling.arn
      TG_COTURN          = aws_lb_target_group.coturn_tcp.arn
      TG_FRP             = aws_lb_target_group.frp.arn
      TG_THINGSBOARD     = aws_lb_target_group.thingsboard.arn
    }
  }
}

# 10. Add ELBv2 permissions to Lambda role
resource "aws_iam_role_policy" "lambda_elbv2" {
  name = "jupiter-lambda-elbv2-policy"
  role = aws_iam_role.lambda_failover.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeTargetHealth"
        ]
        Resource = "*"
      }
    ]
  })
}