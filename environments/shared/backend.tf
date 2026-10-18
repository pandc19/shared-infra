# State lives in the hand-created DO Spaces bucket shared-infra-storage, under the
# tfstate/ prefix (Coolify writes Postgres backups under data/). The bucket and its limited
# access key are created manually - see SETUP.md - because Terraform can't create the
# bucket that holds its own state. Backend blocks can't use variables, so the endpoint
# is hardcoded (the bucket is in nyc3).
#
# skip_requesting_account_id: DO Spaces has no STS/IAM, so the default AWS account ID
# lookup would fail init with a 403 even with correct credentials.
# skip_s3_checksum: newer AWS SDKs send checksum headers some S3-compatible stores
# reject.
#
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (the Spaces key).
terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://nyc3.digitaloceanspaces.com"
    }
    region                      = "us-east-1" # required by the S3 backend syntax, ignored by Spaces
    bucket                      = "shared-infra-storage"
    key                         = "tfstate/shared/terraform.tfstate"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
