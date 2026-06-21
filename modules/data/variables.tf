variable "assets_bucket_name" {
  description = "Globally-unique name for the private assets S3 bucket."
  type        = string
}

variable "templates_table_name" {
  description = "Name for the DynamoDB Templates table."
  type        = string
}

variable "quotas_table_name" {
  description = "Name for the DynamoDB Quotas table (PK=userId, TTL enabled)."
  type        = string
}

variable "extra_tags" {
  description = "Extra tags merged on top of the provider default_tags for module resources."
  type        = map(string)
  default     = {}
}
