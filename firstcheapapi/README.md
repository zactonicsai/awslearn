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


For the **cheap Python Hello API** ZIP I made, the cost is usually **$0/day for light testing** because it uses **Lambda Function URL only** — no EC2, no NAT Gateway, no ALB, and no VPC.

Estimated cost in **us-east-1**, assuming the default **128 MB Lambda** and a fast hello response around **50 ms**:

|               Usage | Estimated monthly cost | Estimated daily cost |
| ------------------: | ---------------------: | -------------------: |
|         0 calls/day |              **$0.00** |            **$0.00** |
|       100 calls/day |              **$0.00** |            **$0.00** |
|     1,000 calls/day |              **$0.00** |            **$0.00** |
|    10,000 calls/day |              **$0.00** |            **$0.00** |
|   100,000 calls/day |  **about $0.40/month** |  **about $0.01/day** |
| 1,000,000 calls/day |  **about $5.80/month** |  **about $0.19/day** |

Why so cheap: AWS Lambda includes **1 million free requests per month** and **400,000 GB-seconds free per month**. After that, Lambda request pricing is shown by AWS as **$0.20 per 1 million requests**, and compute is **$0.0000166667 per GB-second** in the AWS example pricing. ([Amazon Web Services, Inc.][1])

The **Function URL itself does not add API Gateway cost**. AWS says Function URLs are included in normal Lambda request and duration pricing. ([Amazon Web Services, Inc.][2])

Small extra possible costs:

| Item                               |                                                 Estimate |
| ---------------------------------- | -------------------------------------------------------: |
| CloudWatch logs                    | Usually $0 for small testing; can cost more if logs grow |
| Optional S3 Terraform state bucket |                                            Pennies/month |
| Data transfer out                  |                          Usually tiny for this hello API |

CloudWatch Logs can start free, but normal CloudWatch Logs rates apply after free-tier usage; AWS shows example log ingestion pricing at **$0.50/GB** in US East examples. ([AWS Documentation][3])

For your testing, I would budget:

**Daily:** `$0.00 to $0.01`
**Monthly:** `$0.00 to $1.00` for normal lab use

This is much cheaper than the VPC/EC2/ALB/NAT version, which was around **$2.70–$3.00 per day**.

[1]: https://aws.amazon.com/lambda/pricing/ "AWS Lambda Pricing"
[2]: https://aws.amazon.com/blogs/aws/announcing-aws-lambda-function-urls-built-in-https-endpoints-for-single-function-microservices/ "Announcing AWS Lambda Function URLs: Built-in HTTPS Endpoints for Single-Function Microservices | AWS News Blog"
[3]: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/LogsBillingDetails.html "Amazon CloudWatch Logs billing and cost - Amazon CloudWatch Logs"

