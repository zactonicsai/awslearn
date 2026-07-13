# Cheapest AWS Python Hello API with Terraform

This project creates a tiny AWS API that returns `hello` and accepts a POST argument named `name`.

It uses the lowest-cost simple serverless path:

- AWS Lambda running Python 3.14 by default
- Lambda Function URL for the HTTPS API endpoint
- CloudWatch Logs with short retention
- No EC2
- No NAT Gateway
- No Elastic Load Balancer / ALB
- No API Gateway required
- No VPC needed

## What the API does

GET request:

```bash
curl "${API_URL}hello"
```

Response:

```json
{"message":"Hello from Python Lambda!","method":"GET"}
```

POST request:

```bash
curl -X POST "${API_URL}hello" \
  -H "Content-Type: application/json" \
  -d '{"name":"Zach"}'
```

Response:

```json
{"message":"Hello, Zach!","method":"POST"}
```

## Why this is cheaper than the earlier VPC/EC2/ALB setup

This project does not create a VPC, NAT Gateway, EC2 instance, or Elastic Load Balancer.
That removes the biggest daily fixed costs from the previous lab.

Lambda Function URLs do not require API Gateway for this simple lab.
For very small testing, the cost is usually close to zero, depending on your AWS Free Tier and request count.

## Folder layout

```text
aws-python-hello-api-cheapest/
  README.md
  lambda/
    app.py
  terraform/
    versions.tf
    variables.tf
    main.tf
    outputs.tf
    terraform.tfvars.example
    backend.tf.example
  scripts/
    bootstrap-state-s3.sh
    deploy.sh
    destroy.sh
    test-api.sh
  build/
    .gitkeep
```

## Prerequisites

Install these on your local computer:

- AWS CLI
- Terraform
- curl
- zip, if your system needs it for other packaging work

This project uses Terraform's `archive` provider to zip the Lambda code, so you do not need to manually zip the Python file.

## Configure AWS credentials

Run this first:

```bash
aws configure
```

Or use AWS SSO:

```bash
aws configure sso
aws sso login --profile your-profile-name
export AWS_PROFILE=your-profile-name
```

## Deploy with local Terraform state

This is the easiest path for a small lab:

```bash
cd aws-python-hello-api-cheapest
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
./scripts/deploy.sh
./scripts/test-api.sh
```

## Optional: use S3 remote state

Remote state is safer for team work because the state file is stored in S3 instead of only on your laptop.

Create the backend bucket:

```bash
export AWS_REGION=us-east-1
export PROJECT_NAME=hello-python-api
export ENVIRONMENT=dev
./scripts/bootstrap-state-s3.sh
```

Then copy the backend example:

```bash
cp terraform/backend.tf.example terraform/backend.tf
```

Edit `terraform/backend.tf` and replace the bucket name with the bucket printed by the bootstrap script.

Then deploy:

```bash
./scripts/deploy.sh
```

## Destroy everything created by Terraform

```bash
./scripts/destroy.sh
```

Important: the optional S3 Terraform state bucket is created outside Terraform by the bootstrap shell script.
Terraform will not destroy that bucket automatically. This is intentional so you do not accidentally delete your state history.

## Troubleshooting

### Terraform says the Lambda zip is missing

Run from the project root using the script:

```bash
./scripts/deploy.sh
```

The Terraform `archive_file` data block will build the zip automatically.

### Python runtime issue

If your AWS Region/account does not support `python3.14` yet, edit `terraform/terraform.tfvars` and set:

```hcl
lambda_runtime = "python3.13"
```

Then run `./scripts/deploy.sh` again.

### API returns 500

Check Lambda logs:

```bash
aws logs tail /aws/lambda/hello-python-api-dev-handler --follow
```

### Destroy fails because state bucket exists

The app stack does not own the optional state bucket. Empty and delete it manually only when you are sure you no longer need the state history.


## Fix: Lambda Function URL CORS origin error

If Terraform shows an error like this:

```text
InvalidParameterValueException: 68.32.112.68 isn't a valid origin
```

That means `allowed_cors_origins` contains a bare IP address. CORS origins must be `*` or a full URL.

Use this for a simple lab:

```hcl
allowed_cors_origins = ["*"]
```

Use this for a local React/Vite app:

```hcl
allowed_cors_origins = ["http://localhost:3000"]
```

Use this for a real HTTPS website:

```hcl
allowed_cors_origins = ["https://www.example.com"]
```

Do not use this:

```hcl
allowed_cors_origins = ["68.32.112.68"]
```

CORS is not the same as an IP allow list. CORS only controls browser JavaScript behavior. It does not block curl, Postman, or other direct API clients.
