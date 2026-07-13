# SSM-Only Access: How This Works Without SSH

This build opens **zero SSH ports**. There is no key pair, no `authorized_keys`, no port 22 rule anywhere. All access — interactive shells *and* Ansible — goes through **AWS Systems Manager Session Manager**.

This document explains how, why it's better, and every place it will bite you.

---

## The core idea: the connection runs backwards

With SSH, **you connect in**:

```
  You  ──────(inbound TCP 22)─────>  Server
                                     ^
                                     |
                        A LISTENING DAEMON, exposed,
                        waiting for anyone to knock.
```

That listening daemon is an attack surface. It exists whether or not you're using it. Bots scan for it constantly. If your firewall rule is ever wrong — even for ten minutes — it's found.

With SSM, **the server connects out**:

```
  You  ──(HTTPS 443)──> AWS SSM API  <──(HTTPS 443, OUTBOUND)── Server
                             ^                                     ^
                             |                                     |
                    You call an API.               The SSM Agent, running ON the
                    You never touch                box, POLLS OUT to AWS and holds
                    the server directly.           open a WebSocket. Nothing ever
                                                   connects INTO the server.
```

The agent initiates. AWS brokers. **The instance has no inbound rules at all.**

This is not "SSH with better firewall rules." It's a structurally different thing. There is no daemon exposed to attack.

---

## Why this is strictly better than a bastion + SSH

| | SSH (even via a bastion) | SSM Session Manager |
|---|---|---|
| Inbound port required | **Yes** — 22, somewhere | **None. Zero.** |
| Credential to steal | A private key file | Nothing. It's IAM. |
| Revoking someone's access | Hunt down every copy of the key they may have emailed, copied, or committed | **Remove one IAM permission.** Instant, central. |
| Key rotation | Manual, painful, always overdue | **N/A — there are no keys** |
| Audit trail | `/var/log/auth.log` on each box, if you remember to ship it | **Every session in CloudTrail**, with the IAM principal who opened it |
| Session recording | Bolt on something like `sshrec` | **Built in** — pipe full session transcripts to S3 or CloudWatch |
| Bastion host to run/patch/pay for | **Yes** | **No** |
| Works with no public IP | Needs a bastion or VPN | **Yes, natively** |
| What a stolen laptop gets an attacker | Your private key → your servers | Nothing useful without their IAM creds *and* MFA |

That "revoking access" row is the one that matters most in practice. SSH keys are copied. They end up in Slack, in `scp` history, in a teammate's `~/.ssh`, in a Docker image, in a git commit. You can never be sure you've found them all. An IAM permission is one row in one place.

---

## What SSM costs you (the honest tradeoffs)

It is not free.

### 1. Three VPC endpoints, ~$22/month

Your instances are in a private subnet. The SSM Agent needs to reach the SSM API. It can do that via the NAT Gateway, but the clean way is **interface endpoints**, and you need **all three**:

| Endpoint | What it does |
|---|---|
| `ssm` | The Session Manager / Run Command API |
| `ssmmessages` | The WebSocket channel that carries your actual shell |
| `ec2messages` | The legacy Run Command channel — **still required** |

**People forget `ec2messages` constantly.** It sounds legacy and optional. It is not. Omit it and your instance either never registers, or registers and then shows "Connection lost."

Each is ~$7.30/month. That's ~$22/month — a real cost, and it's the price of having no open ports.

*(You could skip the endpoints and let the agent reach SSM through the NAT Gateway. That works, but it means your control-plane traffic goes out to the internet and back. The endpoints keep it entirely on AWS's private backbone.)*

### 2. Ansible needs an S3 bucket

This is the surprising one.

Ansible works by copying a Python module to the target and running it. Over SSH it uses SFTP. **SSM has no file channel** — it only carries a command stream.

So `community.aws.aws_ssm` does this instead:

```
1. Ansible PUTs the module into an S3 bucket (presigned)
2. Ansible tells the host, over the SSM command channel:
     "curl this presigned URL and execute it"
3. The host downloads it from S3 and runs it
4. stdout comes back over the SSM channel
```

That's why `terraform` creates an `ssm_transfer` bucket, why both instance roles need `s3:GetObject` on it, and why you must set:

```bash
export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=terraform output -raw ssm_transfer_bucket)
```

Forget that and **every task fails**, with an error that doesn't mention S3 at all.

### 3. It's slower than SSH

Every module round-trips through S3. Expect Ansible playbooks to run maybe 1.5–3× slower than over SSH. That's why `ansible.cfg` bumps `forks` to 10 — parallelism claws some of it back.

### 4. `pipelining` must be OFF

Pipelining is an SSH optimization. It has no meaning for SSM and will break the plugin. `ansible.cfg` sets `pipelining = False` deliberately. Don't "helpfully" turn it back on.

### 5. You need the `session-manager-plugin` binary

`aws ssm start-session` needs a separate helper binary that is **not bundled with the AWS CLI**. Ansible's `aws_ssm` plugin shells out to the same binary.

Install it on **both** your laptop and the Command Node:

```bash
bash scripts/install-session-manager-plugin.sh
```

---

## The five things that make SSM work

If any one of these is missing, you get no access at all — and remember, **there is no SSH fallback**. Get these right.

### 1. The instance role has `AmazonSSMManagedInstanceCore`

```hcl
resource "aws_iam_role_policy_attachment" "nifi_ssm_core" {
  role       = aws_iam_role.nifi.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

Without this the agent cannot register. The instance simply never appears in SSM.

### 2. The SSM Agent is installed and running

Ubuntu's official AWS AMIs (and Amazon Linux 2023) ship it preinstalled as a snap. Our `user_data` makes sure it's started anyway. Debian and most non-AWS images do **not** include it — you'd have to install it yourself.

### 3. All three VPC endpoints exist, with `private_dns_enabled = true`

```hcl
resource "aws_vpc_endpoint" "ssm" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  private_dns_enabled = true   # <-- MUST be true
  # ...
}
```

If `private_dns_enabled` is false, the agent resolves `ssm.us-east-1.amazonaws.com` to the *public* IP and tries to go out through the NAT. It may work, or it may hang. Set it true.

### 4. The endpoint security group allows 443 from the private subnets

The endpoints are ENIs in your subnets. They need an SG that lets the instances reach them:

```hcl
ingress {
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = var.private_subnet_cidrs
}
```

### 5. The instance SG allows **outbound** 443

The agent connects *out*. If you lock egress down to nothing, the agent can't reach SSM and you've locked yourself out permanently.

```hcl
resource "aws_security_group_rule" "nifi_out_https" {
  type        = "egress"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  # ...
}
```

---

## Daily usage

### Get a shell

```bash
# List what's available
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{ID:InstanceId,Ping:PingStatus}' \
  --output table

# Connect
aws ssm start-session --target i-0abc123def456

# You land as ssm-user. Become the real user:
sudo su - ubuntu
```

### Run one command everywhere

```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Project,Values=nifi-platform" \
  --parameters 'commands=["systemctl is-active kafka"]'
```

### Port-forward (this replaces SSH tunnelling entirely)

Want NiFi's UI on your laptop without going through the ALB?

```bash
aws ssm start-session \
  --target i-0nifi-instance-id \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
```

Now open `https://localhost:8443`. **No open port, no bastion, no VPN.**

You can even port-forward to a *remote* host through the instance (`AWS-StartPortForwardingSessionToRemoteHost`) — which means you could reach Kafka from your laptop through the Command Node, without Kafka ever being exposed.

### Ansible

```bash
export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=terraform output -raw ssm_transfer_bucket)
cd ansible
ansible all -m ping        # "pong" over SSM
ansible-playbook site.yml
```

---

## Troubleshooting

### "Instance not showing up in SSM"

Work through this list in order. It is almost always #3.

```bash
# 1. Is the role attached and correct?
aws ec2 describe-instances --instance-ids i-0abc \
  --query 'Reservations[0].Instances[0].IamInstanceProfile'

# 2. Does that role have AmazonSSMManagedInstanceCore?
aws iam list-attached-role-policies --role-name nifi-platform-dev-nifi-role

# 3. DO ALL THREE ENDPOINTS EXIST?   <-- usually the problem
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-0abc" \
  --query 'VpcEndpoints[].ServiceName'
# You MUST see ssm, ssmmessages, AND ec2messages.
# Missing ec2messages is the single most common cause.

# 4. Is private DNS on?
aws ec2 describe-vpc-endpoints \
  --query 'VpcEndpoints[].{Svc:ServiceName,DNS:PrivateDnsEnabled}'

# 5. Can the instance egress on 443?
#    Check the instance SG has an egress rule for 443.
```

### `TargetNotConnected`

The agent isn't registered. Same list as above. Also: it takes **~90 seconds after boot** for a fresh instance to register. Be patient before you panic.

### Ansible fails with a vague S3 / AccessDenied error

Three causes:

1. `ANSIBLE_AWS_SSM_BUCKET` isn't set. `site.yml` has a preflight assert for exactly this.
2. The **instance role** lacks `s3:GetObject` on the transfer bucket. The *controller* uploading isn't enough — the *target* has to download.
3. `session-manager-plugin` isn't installed on the controller.

### Ansible is slow

It is. That's the S3 round-trip. Raise `forks`. Don't enable pipelining.

### "I locked myself out"

You can't, really — that's the point. As long as:
- the instance is running,
- the agent is alive,
- the role is attached,

...you have access. There's no key to lose.

But if you **detach the IAM role** or **delete the SSM endpoints**, you *have* locked yourself out, and there is no SSH fallback. The recovery is: reattach the role via the AWS API (which you can still do — it's a control-plane operation, not a network one), wait 90 seconds, reconnect.

---

## Least-privilege policy for a human operator

The Command Node's role has `AdministratorAccess` for simplicity. Here's what a *human* actually needs to use SSM, if you want to scope people down:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartSessionsOnTaggedInstances",
      "Effect": "Allow",
      "Action": ["ssm:StartSession"],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": { "aws:ResourceTag/Project": "nifi-platform" }
      }
    },
    {
      "Sid": "SessionDocuments",
      "Effect": "Allow",
      "Action": ["ssm:StartSession"],
      "Resource": [
        "arn:aws:ssm:*:*:document/AWS-StartSSHSession",
        "arn:aws:ssm:*:*:document/AWS-StartPortForwardingSession"
      ]
    },
    {
      "Sid": "ManageOwnSessionsOnly",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:*:*:session/${aws:username}-*"
    },
    {
      "Sid": "Discovery",
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeSessions",
        "ssm:DescribeInstanceInformation",
        "ssm:GetConnectionStatus",
        "ec2:DescribeInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

Note the tag condition on `StartSession` — this person can shell into project instances and **nothing else in the account**. Try expressing that with SSH keys.

The `${aws:username}-*` on `TerminateSession` means they can kill their own sessions but not a colleague's.

---

## Turn on session logging

Since you get an audit trail for free, take it. Send full session transcripts to S3 or CloudWatch Logs:

```bash
aws ssm update-document \
  --name "SSM-SessionManagerRunShell" \
  --content file://session-prefs.json \
  --document-version '$LATEST'
```

Now every keystroke anyone types on any box is recorded, attributed to an IAM principal, and immutable. That is genuinely not achievable with SSH without significant extra machinery.
