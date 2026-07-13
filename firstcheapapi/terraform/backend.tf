# Optional: use this file only if you want S3 remote Terraform state.
terraform {
  # Configure Terraform to store its state file in S3.
  backend "s3" {
    # Replace this with the bucket name printed by scripts/bootstrap-state-s3.sh.
    bucket = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
    # Store this stack's state under this object key inside the bucket.
    key = "hello-python-api/dev/terraform.tfstate"
    # Use the same Region where the state bucket was created.
    region = "us-east-1"
    # Encrypt the state file at rest using S3 server-side encryption.
    encrypt = true
    # Use Terraform's native S3 lock file support to reduce simultaneous-apply risk.
    use_lockfile = true
  }
}
