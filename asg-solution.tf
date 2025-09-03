# PROPER SOLUTION - Auto Scaling Groups instead of primary/backup

# Launch template for each service
resource "aws_launch_template" "services" {
  for_each = {
    signaling   = { port = "3000", script = "signaling.sh" }
    coturn      = { port = "3478", script = "coturn.sh" }
    frp         = { port = "7000", script = "frp.sh" }
    thingsboard = { port = "8080", script = "thingsboard.sh" }
  }
  
  name_prefix = "${each.key}-lt-"
  image_id    = data.aws_ami.ubuntu.id
  instance_type = "t3.small"
  
  vpc_security_group_ids = [aws_security_group.services.id]
  
  user_data = base64encode(templatefile("${path.module}/user-data/${each.value.script}", {
    service_name = each.key
    service_port = each.value.port
  }))
  
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${each.key}-asg-instance"
      Service     = each.key
      Environment = "prod"
    }
  }
}

# Auto Scaling Groups - THIS IS THE MAGIC
resource "aws_autoscaling_group" "services" {
  for_each = aws_launch_template.services
  
  name               = "${each.key}-asg"
  min_size          = 1  # Always have at least 1
  max_size          = 2  # Can scale to 2 if needed
  desired_capacity  = 1  # Normal operation = 1 instance
  
  vpc_zone_identifier = aws_subnet.private[*].id
  
  launch_template {
    id      = each.value.id
    version = "$Latest"
  }
  
  # AUTO-REPLACE FAILED INSTANCES - No Lambda needed!
  health_check_type         = "ELB"  # Check actual service health
  health_check_grace_period = 300
  
  # Automatically register with load balancer
  target_group_arns = [
    each.key == "signaling" ? aws_lb_target_group.signaling.arn :
    each.key == "coturn" ? aws_lb_target_group.coturn_tcp.arn :
    each.key == "frp" ? aws_lb_target_group.frp.arn :
    aws_lb_target_group.thingsboard.arn
  ]
  
  tag {
    key                 = "Name"
    value              = "${each.key}-asg"
    propagate_at_launch = false
  }
}

# For pilot light mode - scale to 0 when not needed
resource "aws_autoscaling_schedule" "scale_down" {
  for_each = var.enable_pilot_light ? aws_autoscaling_group.services : {}
  
  scheduled_action_name  = "${each.key}-scale-down"
  autoscaling_group_name = each.value.name
  
  # Scale to 0 at night (pilot light)
  min_size         = 0
  max_size         = 0
  desired_capacity = 0
  
  recurrence = "0 22 * * *"  # 10 PM daily
}

resource "aws_autoscaling_schedule" "scale_up" {
  for_each = var.enable_pilot_light ? aws_autoscaling_group.services : {}
  
  scheduled_action_name  = "${each.key}-scale-up"
  autoscaling_group_name = each.value.name
  
  # Scale back up in morning
  min_size         = 1
  max_size         = 2
  desired_capacity = 1
  
  recurrence = "0 6 * * *"  # 6 AM daily
}

# CloudWatch alarms for auto-scaling (not failover)
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  for_each = aws_autoscaling_group.services
  
  alarm_name          = "${each.key}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "CPUUtilization"
  namespace          = "AWS/EC2"
  period             = "120"
  statistic          = "Average"
  threshold          = "80"
  
  dimensions = {
    AutoScalingGroupName = each.value.name
  }
  
  alarm_actions = [aws_autoscaling_policy.scale_up[each.key].arn]
}

# Scaling policies
resource "aws_autoscaling_policy" "scale_up" {
  for_each = aws_autoscaling_group.services
  
  name                   = "${each.key}-scale-up"
  autoscaling_group_name = each.value.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown              = 300
}

# NO LAMBDA NEEDED!
# NO MANUAL FAILOVER!
# AWS HANDLES EVERYTHING!

variable "enable_pilot_light" {
  description = "Enable pilot light mode (scale to 0 at night)"
  type        = bool
  default     = false
}