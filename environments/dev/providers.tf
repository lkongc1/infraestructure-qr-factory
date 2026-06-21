provider "aws" {
  region = var.aws_region

  # Default tags applied to every taggable resource.
  # Individual resources may add extra tags, but these are always present.
  # Child modules inherit these default_tags automatically; they do NOT re-apply
  # Project/Environment/ManagedBy/Owner.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = "PlatformTeam"
    }
  }
}
