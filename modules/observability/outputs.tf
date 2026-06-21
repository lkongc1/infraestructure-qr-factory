output "sns_alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications (subscribe PagerDuty here)."
  value       = aws_sns_topic.alarms.arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL (Golden Signals + Cost + Security)."
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.dashboard_name}"
}
