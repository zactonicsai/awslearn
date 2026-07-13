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


For the Terraform lab I created, assume **us-east-1**, **2 private EC2 instances**, **1 NAT Gateway**, **1 public ALB**, **2 small EBS root disks**, and very little traffic.

Estimated cost:

| Item                                                         |                        Approx daily cost |
| ------------------------------------------------------------ | ---------------------------------------: |
| NAT Gateway hourly cost                                      |                            **$1.08/day** |
| Application Load Balancer + 1 low-usage LCU                  |                            **$0.73/day** |
| Two `t3.micro` EC2 instances                                 |                            **$0.50/day** |
| Public IPv4 addresses, roughly 3 IPs: NAT + ALB across 2 AZs |                            **$0.36/day** |
| Two 8 GB gp3 EBS root volumes                                |                            **$0.04/day** |
| Route 53 hosted zone, if you create/use one                  |                            **$0.02/day** |
| S3 buckets for site + Terraform state                        | Usually **pennies or less** for this lab |

**Total estimate: about `$2.70 to $3.00 per day`** with low traffic.

That is about **$81 to $90 per month** if left running all month.

The biggest cost is the **NAT Gateway**, which is about **$0.045/hour**, or **$1.08/day**, before data processing charges. AWS also charges NAT data processing by GB. ([Amazon Web Services, Inc.][1])

The ALB is about **$0.0225/hour** plus LCU usage. For a small hello-world lab, I estimated 1 LCU, giving about **$0.73/day**. ([Amazon Web Services, Inc.][2])

The two `t3.micro` instances are about **$0.50/day total** using the common US East Linux on-demand price estimate of `$0.0104/hour` each. ([Vantage][3])

AWS charges for public IPv4 addresses, including service-managed public IPv4 addresses used by services like internet-facing load balancers and NAT gateways, at about **$0.005/IP/hour**. ([Amazon Web Services, Inc.][4])

To reduce cost, the fastest change is to **destroy the lab when done**:

```bash
./scripts/destroy.sh
```

For a cheaper version, remove the NAT Gateway and use **VPC endpoints for SSM/S3** or temporarily allow package install during build time only. That can cut the lab by roughly **$1.20+ per day**.

[1]: https://aws.amazon.com/vpc/pricing/?utm_source=chatgpt.com "Amazon VPC Pricing"
[2]: https://aws.amazon.com/elasticloadbalancing/pricing/?utm_source=chatgpt.com "Elastic Load Balancing pricing"
[3]: https://instances.vantage.sh/aws/ec2/t3.micro?utm_source=chatgpt.com "t3.micro pricing and specs - Amazon EC2 Instance Comparison"
[4]: https://aws.amazon.com/blogs/networking-and-content-delivery/identify-and-optimize-public-ipv4-address-usage-on-aws/?utm_source=chatgpt.com "Identify and optimize public IPv4 address usage on AWS"
