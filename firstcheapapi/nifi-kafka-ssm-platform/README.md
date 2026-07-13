# AWS Command Node → NiFi → Kafka (SSM-only, zero SSH)

Infrastructure-as-code for an AWS data platform:

- an **EC2 Command Node** with Terraform + Ansible, used to build and configure everything else
- a **new VPC** with an **ALB**, a public HTTPS endpoint for **NiFi** on your own domain
- a private **Kafka** broker reachable by **exactly two security groups** — NiFi and the Command Node — and nothing else
- **S3** access for NiFi via an IAM role (no keys anywhere)
- a **Python trigger app** that tells NiFi to pull text files from S3, and a **consumer** that `cat`s their contents

**There is no SSH in this build.** No key pairs. No port 22. Not on the Command Node, not on NiFi, not on Kafka. Everything — interactive shells and Ansible alike — runs over **AWS Systems Manager Session Manager**.

Read **[docs/SSM-ONLY.md](docs/SSM-ONLY.md)** before you start. It explains how that works and the five things that must be right for it to work at all.

---

## Architecture

```
   YOUR LAPTOP
        |
        |  aws ssm start-session   (HTTPS 443 to the AWS API)
        |  No SSH. No key. No inbound port on anything.
        v
  +==============================================================+
  |  AWS                                                          |
  |                                                               |
  |  COMMAND VPC (172.31/16)          DATA VPC (10.20/16)         |
  |  +--------------------+           +-------------------------+ |
  |  |  COMMAND NODE      |           |  PUBLIC SUBNETS x2       | |
  |  |  - Terraform       |           |  +--------------------+  | |
  |  |  - Ansible (SSM)   |           |  |  ALB :443 (ACM TLS)|<-+-+-- nifi.yourdomain.com
  |  |  - Python venv     |           |  +---------|----------+  | |
  |  |  - NO SSH KEY      |           |            | 8443        | |
  |  +---------|----------+           |  PRIVATE SUBNETS x2      | |
  |            |                      |  +---------v----------+  | |
  |            |   VPC PEERING        |  |  NIFI              |  | |
  |            +======================+->|  - IAM role -> S3  |  | |
  |                (9092, 9999)       |  |  - no public IP    |  | |
  |                                   |  +---------|----------+  | |
  |                                   |            | 9092        | |
  |                                   |  +---------v----------+  | |
  |                                   |  |  KAFKA (KRaft)     |  | |
  |                                   |  |  ingress on 9092:  |  | |
  |                                   |  |   [NiFi SG]        |  | |
  |                                   |  |   [Command Node SG]|  | |
  |                                   |  |   ...and NOTHING   |  | |
  |                                   |  |      else.         |  | |
  |                                   |  +--------------------+  | |
  |                                   |                          | |
  |                                   |  S3 Gateway Endpoint ----+-+--> S3 BUCKET
  |                                   |  (free, private)         | |    (.txt files)
  |                                   |  SSM Interface Endpoints | |
  |                                   |  (ssm/ssmmessages/       | |
  |                                   |   ec2messages)           | |
  |                                   +--------------------------+ |
  +===============================================================+
```

---

## Layout

```
.
├── terraform/                    # The whole data platform
│   ├── versions.tf               #   providers + S3 backend (native locking)
│   ├── variables.tf              #   every knob (note: NO ssh_key_name)
│   ├── network.tf                #   VPC, subnets, NAT, routes, peering
│   ├── security.tf               #   *** the security groups. read this one. ***
│   ├── s3.tf                     #   data bucket, SSM transfer bucket, endpoints
│   ├── iam.tf                    #   roles: NiFi->S3, both->SSM
│   ├── compute.tf                #   NiFi + Kafka EC2 (no key_name!)
│   ├── alb.tf                    #   ALB, ACM cert, Route53
│   ├── outputs.tf
│   └── terraform.tfvars.example  #   copy -> terraform.tfvars
│
├── ansible/                      # Configures the servers, over SSM
│   ├── ansible.cfg               #   aws_ssm connection, pipelining OFF
│   ├── inventory.aws_ec2.yml     #   hostnames = INSTANCE IDs, not IPs
│   ├── group_vars/all.yml        #   the SSM connection settings
│   ├── site.yml                  #   preflight -> kafka -> nifi
│   └── roles/
│       ├── kafka/                #   Kafka 3.9 KRaft (no ZooKeeper)
│       └── nifi/                 #   NiFi 2.x + the proxy-host fix
│
├── python-app/
│   ├── trigger_nifi.py           # POST -> NiFi -> "go pull from S3"
│   ├── consumer.py               # reads Kafka, cats the file contents
│   └── requirements.txt
│
├── scripts/
│   ├── 00-bootstrap-command-node.sh    # run this on the fresh Command Node
│   ├── install-session-manager-plugin.sh
│   ├── deploy.sh                       # terraform + ansible, end to end
│   ├── verify-security.sh              # PROVES no port 22 exists
│   └── destroy.sh
│
└── docs/
    ├── SSM-ONLY.md               # *** start here ***
    ├── NIFI-FLOW.md              # how to build the flow in the UI
    └── TROUBLESHOOTING.md
```

---

## Quick start

### 1. Launch the Command Node (by hand, once)

- **AMI:** Ubuntu Server 24.04 LTS
- **Type:** `t3.small`
- **Key pair:** **"Proceed without a key pair"** ← yes, really
- **Security group:** create one with **no inbound rules at all**
- **Storage:** 30 GiB gp3
- **IAM role:** create one with `AmazonSSMManagedInstanceCore` + `AdministratorAccess`, attach it

### 2. Get in — without SSH

On your laptop:

```bash
bash scripts/install-session-manager-plugin.sh
aws ssm start-session --target i-0your-command-node
sudo su - ubuntu
```

### 3. Bootstrap it

```bash
git clone <this repo> && cd <repo>
bash scripts/00-bootstrap-command-node.sh
```

Installs Terraform, Ansible + `community.aws`, AWS CLI v2, the session-manager-plugin, a Python venv, and creates the state bucket. **It does not generate an SSH key, because nothing needs one.**

### 4. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars        # paste the values the bootstrap script printed

sed -i "s/REPLACE_WITH_YOUR_BUCKET/$(cat ~/tf-bucket-name.txt)/" versions.tf
```

### 5. Deploy

```bash
bash scripts/deploy.sh
```

Runs `terraform plan` (**read it**), applies, waits for the SSM agents to register, then runs Ansible over SSM.

**Total: ~30 minutes.** Most of it is the ALB provisioning and NiFi's 1.5 GB download.

### 6. Prove the security model

```bash
bash scripts/verify-security.sh
```

Checks that zero port-22 rules exist, zero key pairs are attached, the data hosts have no public IP, and Kafka's 9092 admits exactly two security groups and zero CIDRs.

### 7. Run it

Build the NiFi flow ([docs/NIFI-FLOW.md](docs/NIFI-FLOW.md)), then:

```bash
BUCKET=$(terraform -chdir=terraform output -raw s3_bucket_name)
echo "hello from s3" > test.txt
aws s3 cp test.txt "s3://$BUCKET/incoming/"

source ~/.venvs/nifi-kafka/bin/activate
cd python-app
python consumer.py --from-beginning &
python trigger_nifi.py
```

---

## The security requirement, satisfied

> *"add security groups to support private connections to another EC2 setup with Kafka and only allow access from the EC2 command server and NiFi on this subnet security group"*

`terraform/security.tf`:

```hcl
resource "aws_security_group_rule" "kafka_in_from_nifi" {
  from_port                = 9092
  source_security_group_id = aws_security_group.nifi.id       # badge #1
  security_group_id        = aws_security_group.kafka.id
}

resource "aws_security_group_rule" "kafka_in_from_command_node" {
  from_port                = 9092
  source_security_group_id = var.command_node_sg_id           # badge #2
  security_group_id        = aws_security_group.kafka.id
}

# There is no rule #3.
```

Both rules use `source_security_group_id` — a **badge**, not an address. No `cidr_blocks` on port 9092 anywhere. Not `0.0.0.0/0`, not the VPC range, not a hardcoded IP.

This matters because a CIDR rule like `10.20.0.0/16` would let **any** host in that subnet reach Kafka, including ones you didn't create. A security-group reference admits only what actually wears the badge — and it keeps working when NiFi reboots with a new IP.

---

## Cost

~**$200/month** running 24/7. The big items:

| | |
|---|---|
| NAT Gateway | **$33** — the biggest single line |
| SSM interface endpoints (×3) | **$22** — the price of zero open ports |
| NiFi `t3.large` | $61 |
| ALB | $16 |
| Kafka `t3.medium` | $30 |

**Stop the instances between sessions** and you drop to ~$18/month in EBS. Bake AMIs with Packer and you can delete the NAT Gateway entirely.

`bash scripts/destroy.sh` tears it all down (and empties the versioned buckets first, which Terraform can't do on its own).

---

## Two things that will bite you

Everyone hits these. They're in the code comments too.

1. **NiFi behind an ALB returns "invalid host header."** It's `nifi.web.proxy.host`. It must contain your ALB's FQDN. Always.

2. **Your Kafka consumer connects and then hangs forever with no error.** It's `advertised.listeners`. Kafka told the client to reconnect to an address the client can't reach.

And one that's specific to this build:

3. **Ansible fails with a confusing S3 error.** You forgot `export ANSIBLE_AWS_SSM_BUCKET=...`. The SSM connection plugin has no file channel, so it ships modules through S3. `site.yml` has a preflight check that catches this with a clear message.
