# AWS Cloud Team Playbook: Simple VPC + ALB Port 7777 + Private EC2 + S3 Site Source + SSM Command Host

This project creates a small AWS lab that is easy to stand up and tear down.

## What it builds

- New VPC with two public subnets and two private subnets.
- Internet Gateway for public subnets.
- One NAT Gateway so private EC2 instances can reach AWS APIs and install packages.
- Public Application Load Balancer with one listener: HTTP on port `7777`.
- Public ALB security group limited to your trusted CIDR list.
- Private web EC2 instance with no public IP.
- Private command EC2 instance with no public IP and no inbound rules.
- SSM Session Manager access to the command host.
- Private S3 bucket that stores `index.html` and local CSS.
- Web EC2 copies files from S3 and serves them with Apache.
- Optional Route 53 A-record alias to the ALB.
- S3 remote Terraform state bucket created by AWS CLI, with versioning, encryption, public access block, TLS-only policy, and native Terraform lock file.

## Important cost note

This lab creates resources that can cost money while running, especially the NAT Gateway and Application Load Balancer. Run `scripts/destroy.sh` when finished.

## Prerequisites on your local machine

- AWS CLI configured with credentials that can create VPC, EC2, IAM, ELB, S3, and Route 53 resources.
- Terraform installed locally.
- Session Manager plugin installed locally if you want to connect by CLI.

## Step 1: Copy variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Find your current public IP:

```bash
curl -s https://checkip.amazonaws.com
```

Edit `terraform.tfvars` and replace:

```hcl
allowed_alb_cidrs = ["YOUR_PUBLIC_IP/32"]
```

with something like:

```hcl
allowed_alb_cidrs = ["198.51.100.25/32"]
```

## Step 2: Create the safe S3 backend bucket

```bash
export AWS_REGION=us-east-1
export PROJECT_NAME=cloud-team-playbook
export ENVIRONMENT=dev
./scripts/bootstrap-state-s3.sh
```

The script creates `backend.tf`. This keeps Terraform state in S3 instead of only on your laptop.

## Step 3: Deploy

```bash
./scripts/deploy.sh
```

When complete, Terraform prints outputs. Open the `app_url`, which looks like:

```text
http://ALB-DNS-NAME:7777
```

## Step 4: Connect to the private command host with SSM

```bash
./scripts/ssm-command-host.sh
```

Inside the command host, check tools:

```bash
terraform version
ansible --version
aws sts get-caller-identity
```

You can also run:

```bash
cat /var/log/user-data-command-host.log
```

## Step 5: Optional Route 53 setup

DNS names do not control ports. Route 53 points a name to the ALB. The ALB listener and security group control port `7777`.

To create a Route 53 alias record, set these in `terraform.tfvars`:

```hcl
route53_zone_name   = "example.com"
route53_record_name = "app.example.com"
```

Then rerun:

```bash
./scripts/deploy.sh
```

Open:

```text
http://app.example.com:7777
```

## Step 6: Destroy everything created by Terraform

```bash
./scripts/destroy.sh
```

Or, for automation:

```bash
./scripts/destroy.sh --auto-approve
```

The state bucket from `scripts/bootstrap-state-s3.sh` is not destroyed by Terraform. This is intentional so you do not accidentally lose infrastructure history.

## If you accidentally started with local state

Back it up to the state bucket:

```bash
./scripts/backup-local-state-to-s3.sh
```

Then migrate state during init:

```bash
terraform init -migrate-state
```

## Production upgrades to consider later

- Replace the single NAT Gateway with one NAT Gateway per Availability Zone.
- Use VPC interface endpoints for SSM, EC2 Messages, SSM Messages, S3 gateway endpoint, and CloudWatch Logs to reduce public internet dependence.
- Add HTTPS on the ALB with ACM certificate.
- Add AWS WAF to the ALB.
- Add CloudWatch log collection from Apache and user-data logs.
- Replace broad outbound security group rules with narrower egress rules.
- Use a CI/CD pipeline with manual approval for `terraform apply` and `terraform destroy`.
