###############################################################################
# Remote state backend (dev).
#
# TODO: create the shared backend bucket + lock table once and fill in the real
# names below. Recommended one-time bootstrap:
#
#   aws s3api create-bucket --bucket qr-factory-tfstate --region us-east-1
#   aws s3api put-bucket-versioning --bucket qr-factory-tfstate \
#     --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket qr-factory-tfstate \
#     --server-side-encryption-configuration \
#     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   aws dynamodb create-table \
#     --table-name qr-factory-tflock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST
#
# Then run `terraform init` to initialize the backend.
###############################################################################

terraform {
  backend "s3" {
    bucket         = "qr-factory-tfstate" # TODO: replace with your real backend bucket
    key            = "qr-factory/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "qr-factory-tflock" # TODO: replace with your real lock table
  }
}
