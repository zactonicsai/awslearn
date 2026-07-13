# Build Your Own Cloud Control Room

### An AWS Command Node with Terraform + Ansible, a NiFi Server, a Kafka Server, and a Python App That Ties Them Together

## 🔒 With Zero SSH. No Key Pairs. No Open Port 22. Anywhere.

---

## Table of Contents

1. [What Are We Building? (The Big Picture)](#1-what-are-we-building-the-big-picture)
2. [The Big Idea: Why There Is No SSH Here](#2-the-big-idea-why-there-is-no-ssh-here)
3. [Background: The Vocabulary You Need](#3-background-the-vocabulary-you-need)
4. [Before You Start: The Checklist](#4-before-you-start-the-checklist)
5. [PART ONE — Step-by-Step: Build the Command Node](#5-part-one--step-by-step-build-the-command-node)
6. [PART TWO — The Big Terraform Build](#6-part-two--the-big-terraform-build)
7. [PART THREE — Ansible Configures the Servers (Over SSM)](#7-part-three--ansible-configures-the-servers-over-ssm)
8. [PART FOUR — The Python App and the Consumer](#8-part-four--the-python-app-and-the-consumer)
9. [Running the Whole Thing End to End](#9-running-the-whole-thing-end-to-end)
10. [Deep Background: How Every Piece Actually Works](#10-deep-background-how-every-piece-actually-works)
11. [Best Practices (And Why They Matter)](#11-best-practices-and-why-they-matter)
12. [Pros and Cons of Every Choice We Made](#12-pros-and-cons-of-every-choice-we-made)
13. [Troubleshooting: When Things Break](#13-troubleshooting-when-things-break)
14. [Cost Estimate and How to Turn It All Off](#14-cost-estimate-and-how-to-turn-it-all-off)
15. [Glossary](#15-glossary)

---

## 1. What Are We Building? (The Big Picture)

Imagine you're the director of a school play. You don't build the sets yourself. You don't sew the costumes. You sit in one chair with one clipboard, and from that chair you tell everyone else what to do.

That chair is what we're building first. In cloud computing we call it a **command node**. It is one small computer that lives inside Amazon's data center, and from it you will command Amazon to build everything else.

Here is the whole system:

```
                          YOUR LAPTOP
                               |
                               |  aws ssm start-session
                               |  (an HTTPS API call to AWS -- NOT a
                               |   network connection to the server)
                               v
    +==========================================================+
    |                    AWS CLOUD (us-east-1)                 |
    |                                                          |
    |                  AWS SYSTEMS MANAGER                     |
    |                    (the broker)                          |
    |                    ^          ^                          |
    |     agent polls    |          |    agent polls           |
    |     OUTBOUND ------+          +------ OUTBOUND           |
    |     (nothing ever connects IN to any server)             |
    |          |                            |                  |
    |   +------|--------------+    +--------|---------------+  |
    |   | COMMAND VPC         |    | DATA VPC (10.20/16)    |  |
    |   | (10.0.0.0/16)       |    |                        |  |
    |   |                     |    |  PUBLIC SUBNETS x2     |  |
    |   |  +---------------+  |    |  +------------------+  |  |
    |   |  | COMMAND NODE  |  |    |  | ALB :443         |<-+--+-- nifi.you.com
    |   |  | (t3.small)    |  |    |  | (ACM TLS cert)   |  |  |
    |   |  |               |  |    |  +--------|---------+  |  |
    |   |  | - Terraform   |  |    |           | 8443       |  |
    |   |  | - Ansible     |  |    |  PRIVATE SUBNETS x2    |  |
    |   |  | - AWS CLI     |  |    |  +--------v---------+  |  |
    |   |  | - Python 3    |  |    |  | NIFI (t3.large)  |  |  |
    |   |  |               |  |    |  | - IAM role -> S3 |  |  |
    |   |  | NO SSH KEY.   |  |    |  | - NO public IP   |  |  |
    |   |  | NO PORT 22.   |  |    |  | - NO SSH KEY     |  |  |
    |   |  +-------|-------+  |    |  +--------|---------+  |  |
    |   |          |          |    |           | 9092       |  |
    |   +----------|----------+    |  +--------v---------+  |  |
    |              |               |  | KAFKA (t3.medium)|  |  |
    |              |  VPC PEERING  |  | KRaft, no ZK     |  |  |
    |              +===============+->|                  |  |  |
    |                 (9092, 9999)  |  | port 9092 admits |  |  |
    |                               |  |  [NiFi SG]       |  |  |
    |                               |  |  [CmdNode SG]    |  |  |
    |                               |  |  ...and NOTHING  |  |  |
    |                               |  |     else.        |  |  |
    |                               |  +------------------+  |  |
    |                               |                        |  |
    |                               |  S3 Gateway Endpoint --+--+--> S3 BUCKET
    |                               |  (private, FREE)       |  |    (.txt files)
    |                               |                        |  |
    |                               |  SSM Interface Endpts  |  |
    |                               |  (ssm/ssmmessages/     |  |
    |                               |   ec2messages)         |  |
    |                               +------------------------+  |
    +==========================================================+
```

### The story

1. You launch **one** small server. You launch it with **no key pair** and a security group with **no inbound rules at all**.
2. You get a shell on it anyway — via `aws ssm start-session`.
3. You install **Terraform** (the construction crew) and **Ansible** (the interior decorator).
4. You write a Terraform file describing the *entire rest of the system*, and run `terraform apply`. ~8 minutes.
5. You run `ansible-playbook site.yml`. Ansible configures NiFi and Kafka — **without SSH**, over SSM.
6. A Python program tells NiFi: *"go fetch the text files from S3 and put them into Kafka."*
7. A second Python program — a **consumer** — watches Kafka and prints each file's contents, like `cat`.

At no point in any of that does an SSH connection occur. There is no key to lose, no port 22 to attack, no bastion host to patch.

---

## 2. The Big Idea: Why There Is No SSH Here

This is the most important section in the tutorial. Everything else follows from it.

### 2.1 The problem with SSH

For thirty years, the way you administered a remote server was: open port 22, put your public key in `authorized_keys`, and connect.

```
  YOU  ────────(inbound TCP 22)────────>  SERVER
                                             ^
                                             |
                            A LISTENING DAEMON. Exposed.
                            Waiting for ANYONE to knock.
```

Think carefully about what that picture means:

**A daemon is listening, all the time, whether or not you're using it.** It doesn't know you're asleep. It sits there, accepting connections from anyone who can route a packet to it.

That is an **attack surface**. And it has all the problems that come with one:

| Problem | Why it's genuinely bad |
|---|---|
| **Bots find it in minutes** | Not hours. Minutes. Open port 22 to `0.0.0.0/0` and within ten minutes your auth log will fill with brute-force attempts from Russia, China, and Brazil. Continuously. Forever. |
| **The key is a file** | Files get copied. Your key ends up in Slack, in a teammate's `~/.ssh`, in `scp` history, in a Docker layer, in a git commit. |
| **You can never fully revoke it** | Someone leaves the company. Where are all the copies of the key they had? You genuinely cannot know. |
| **Rotation is manual and always overdue** | When did you last rotate your SSH keys? Right. |
| **The audit trail is on the box** | `/var/log/auth.log` — on the very machine an attacker would want to edit. |
| **You need a bastion** | Which is another server to run, patch, and pay for. And it has port 22 open too. |

We've all just accepted this because it's how it's always been done.

### 2.2 The SSM idea: run the connection backwards

**AWS Systems Manager Session Manager** inverts the picture:

```
  YOU  ──(HTTPS 443)──> AWS SSM API <──(HTTPS 443, OUTBOUND)── SERVER
                             ^                                    ^
                             |                                    |
                  You call an AWS API.          An agent RUNNING ON the server
                  You never touch the           polls OUT to AWS and holds open
                  server. You don't even        a WebSocket.
                  need a route to it.
                                                NOTHING EVER CONNECTS IN.
```

Read that again, because it's genuinely a different shape of thing.

**The server initiates.** A small program called the **SSM Agent** runs on the box. It reaches *out* to AWS over HTTPS and says *"I'm here, and I'm listening for instructions."* AWS holds that connection open.

When you run `aws ssm start-session`, you are **not connecting to the server**. You are calling an AWS API. AWS then pushes your commands down the WebSocket the agent already opened.

**The instance needs zero inbound rules.** Not "port 22 restricted to a bastion." **Zero.** The security group can be completely empty on the inbound side and it still works perfectly.

### 2.3 What this actually buys you

This isn't security theater. Compare, honestly:

| | **SSH (even via a bastion)** | **SSM Session Manager** |
|---|---|---|
| Inbound port required | **Yes.** 22, somewhere. | **None. Zero. Anywhere.** |
| Credential to steal | A private key file | **Nothing.** It's IAM. |
| Revoking one person's access | Hunt down every copy of a key that may have been emailed, copied, or committed. You'll never be certain. | **Remove one IAM permission.** Instant. Central. Certain. |
| Key rotation | Manual, painful, always overdue | **N/A — there are no keys** |
| Audit trail | `auth.log`, on the box, if you remember to ship it off | **Every session in CloudTrail**, tagged with the IAM principal who opened it |
| Full session recording | Bolt on extra tooling | **Built in.** Pipe every keystroke to S3 or CloudWatch. |
| Bastion to run and patch | **Yes** | **No** |
| Works with no public IP | Needs a bastion or a VPN | **Yes. Natively.** |
| A stolen laptop gets an attacker... | Your private key → your servers | **Nothing useful** without their IAM creds *and* their MFA device |

That "revoking access" row is the one that matters most in practice, and it's the one people underrate.

SSH keys **get copied**. That's not a hypothetical — it's the normal life cycle of an SSH key. It goes in a password manager, then someone shares it "just this once," then it's in a CI system, then it's baked into an AMI. When you need to revoke it, you are playing whack-a-mole against copies you don't know exist.

An IAM permission is **one row, in one place**. Delete it. Done. Instantly. Everywhere.

Now consider this IAM policy, which we'll come back to at the end:

```json
{
  "Effect": "Allow",
  "Action": ["ssm:StartSession"],
  "Resource": "arn:aws:ec2:*:*:instance/*",
  "Condition": {
    "StringEquals": { "aws:ResourceTag/Project": "nifi-platform" }
  }
}
```

That says: *"This person may shell into instances tagged `Project=nifi-platform`, and nothing else in the entire AWS account."*

**Try expressing that with SSH keys.** You can't, really — not without a lot of custom machinery. With IAM it's four lines.

### 2.4 What SSM costs you (I'm not going to pretend it's free)

Three real costs. Know them going in.

**1. Three VPC endpoints, ~$22/month.**

Your instances are in a private subnet. The agent needs to reach the SSM API. The clean way is **interface endpoints** — and you need **all three**:

| Endpoint | What it does |
|---|---|
| `ssm` | The Session Manager / Run Command API |
| `ssmmessages` | The WebSocket that carries your actual shell |
| `ec2messages` | The legacy Run Command channel — **still required** |

**Everyone forgets `ec2messages`.** It sounds legacy. It sounds optional. It is neither. Omit it and your instance either never registers, or registers and immediately shows "Connection lost" — and you'll spend an hour on it.

**2. Ansible needs an S3 bucket.**

This is the surprising one, and I'll explain it fully in Part Three. Short version: SSM carries a *command stream*, not a *file channel*. Ansible needs to copy Python modules to the target. Over SSH it'd use SFTP. Over SSM it can't — so it stages them through S3 instead.

**3. It's slower.**

Every Ansible module round-trips through S3. Expect playbooks to run maybe 1.5–3× slower than over SSH. We claw some of it back with more parallelism.

**My honest verdict:** $22/month and a slower Ansible, in exchange for eliminating an entire category of attack surface and getting a real audit trail for free. That is a very good trade. Take it.

---

## 3. Background: The Vocabulary You Need

Read this even if you think you know it. Everything after assumes it.

### 3.1 What is AWS, really?

**AWS** owns enormous buildings full of computers and rents them to you by the hour. That's genuinely the whole business model.

The important part: you don't rent them by walking in the door. You rent them by sending a **message over the internet** — an **API call**. An API call is like a text message with a very strict format. You send: *"Create one computer, medium size, Ubuntu, in Virginia."* AWS replies: *"Done. Here's its ID."*

Terraform, the AWS CLI, the web console, and `aws ssm start-session` are all just different ways of sending those same API messages. **This matters more than usual in an SSM build**, because SSM works *entirely* through the API. You never open a socket to the server yourself. AWS does it for you.

### 3.2 What is EC2?

**EC2** (*Elastic Compute Cloud*) rents you virtual computers. One is an **instance**.

"Virtual" means Amazon slices one big physical server into many smaller ones, like slicing a pizza. Each slice thinks it's a whole computer.

| Type | vCPU | RAM | ~$/month | Our use |
|---|---|---|---|---|
| `t3.micro` | 2 | 1 GB | $7.50 | Too small for us |
| `t3.small` | 2 | 2 GB | $15 | **Command Node** |
| `t3.medium` | 2 | 4 GB | $30 | **Kafka** |
| `t3.large` | 2 | 8 GB | $61 | **NiFi** (a hungry JVM app) |

The `t` family is *burstable* — cheap, because it assumes you're idle most of the time and gives you CPU credits to spend on short bursts. Perfect for a command node. Acceptable for a demo NiFi. Not appropriate for production Kafka.

### 3.3 What is a VPC?

Your own private network inside AWS. AWS is an apartment building; a VPC is your apartment.

It has an address range in **CIDR notation**, like `10.20.0.0/16`. CIDR trips up everyone, so here's the trick:

```
10.20.0.0/16
^^ ^^  <-- the first 16 bits (= first two numbers) are LOCKED
      ^^^^ <-- the last 16 bits are YOURS to hand out

So this VPC holds every address from 10.20.0.0 to 10.20.255.255
= 65,536 addresses.
```

A `/24` locks three numbers, leaving 256 addresses. **Smaller number after the slash = bigger network.** It's backwards from what feels natural. Everyone trips on this once.

### 3.4 Public vs. private subnets — the single most important security concept here

A **subnet** is a room inside your apartment. Every instance lives in exactly one.

| | **Public Subnet** | **Private Subnet** |
|---|---|---|
| Has a route to an Internet Gateway? | **Yes** | **No** |
| Can a stranger on the internet reach it? | Yes (if the firewall allows) | **No. Never. Physically impossible.** |
| What we put here | The Load Balancer | **NiFi, Kafka** |

Read that bottom-right cell again.

A private subnet isn't *"protected by a strong firewall."* It's that **there is no road**. A packet from the internet has no possible path. Even a badly misconfigured firewall can't expose it, because a firewall rule can't conjure a route that doesn't exist.

This is **defense in depth**: we don't rely on the lock. We remove the door.

And here's why this pairs so beautifully with SSM: normally, a server with no internet route is a server you *can't administer*. You'd need a bastion, or a VPN. **With SSM, you don't.** The agent reaches out through a VPC endpoint on AWS's private backbone, and you get a shell — on a box that is genuinely, structurally unreachable from the internet.

That combination — *no public IP, no inbound rules, and you can still get a shell* — is the whole design.

### 3.5 Availability Zones

An **AZ** is one physical data center building. A **Region** (like `us-east-1`) has several, miles apart, on different power grids.

Why do you care? Because **an ALB legally refuses to exist in only one AZ.** AWS forces you to give it subnets in at least two. That's AWS making you be resilient whether you like it or not.

So our Terraform builds **two** public and **two** private subnets, even though we run one NiFi. Subnets are free, and the ALB won't start without them.

### 3.6 Security Groups — and the badge trick

A **Security Group** (SG) is a firewall wrapped around an instance.

Four rules govern them:

1. **Default deny.** A new SG blocks all inbound. You must explicitly allow.
2. **Allow-only.** There is no "deny" rule. You can only add permissions, never subtract.
3. **Stateful.** Allow traffic *in*, and the reply is automatically allowed *out*. You never write a rule for the reply.
4. **They can reference each other.** ← *This is the magic.*

Point 4 is what this whole build hinges on, so let's make it concrete.

The naive way to lock down Kafka:

```hcl
# THE BAD WAY
ingress {
  from_port   = 9092
  cidr_blocks = ["10.20.11.47/32"]   # NiFi's IP, hardcoded
}
```

This works... until NiFi reboots and gets a new IP. Then Kafka silently stops accepting it, and you lose an afternoon.

The correct way references the **security group**, not an address:

```hcl
# THE GOOD WAY
ingress {
  from_port       = 9092
  security_groups = [aws_security_group.nifi.id]   # "whoever wears the NiFi badge"
}
```

It's a **badge system**. The rule doesn't say *"let in whoever is at desk 47."* It says *"let in anyone wearing the NiFi badge."* NiFi can move desks, get a new IP, be replaced entirely — as long as it wears the badge, it gets in. **Nobody else does.**

Our Kafka SG will have exactly **two** inbound rules on 9092:
- Anyone wearing the **NiFi badge**
- Anyone wearing the **Command Node badge**

And nothing else. Not the VPC range. Not a CIDR. Not port 22 — there is no port 22 in this build at all.

### 3.7 What is a Load Balancer?

A **doorman**. It stands at the front with a public address, takes requests from outside, and hands them to servers hiding in the back.

We use an **ALB** (*Application Load Balancer*), which understands HTTP. It gives us four things:

1. **A public front door** for NiFi — even though NiFi sits in a private subnet with no internet route. The ALB is the *only* thing exposed.
2. **HTTPS termination.** It holds the TLS certificate (free from AWS via **ACM**). Browsers see a valid padlock.
3. **Health checks.** It pings NiFi every 30 seconds and stops sending traffic to a dead one.
4. **A stable DNS name** to point your domain at.

The ALB lives in the **public** subnets. NiFi lives in the **private** subnets. Traffic only ever flows *in* through the doorman.

### 3.8 What is Terraform?

Terraform turns a text file into cloud infrastructure.

You describe what you *want*:

```hcl
resource "aws_instance" "nifi" {
  instance_type = "t3.large"
}
```

Run `terraform apply`. Terraform compares *what you want* against *what exists*, and makes the API calls to close the gap.

This is **declarative**, and it's the opposite of how people used to work:

- **Imperative** = a recipe. "Click here, then there." Run it twice → two servers.
- **Declarative** = a photo of the finished cake. "There should be one NiFi." Run it twice → the second time Terraform says *"there already is one. Nothing to do."*

That property — **running it twice equals running it once** — is called **idempotency**, and it is the single most valuable property in all of infrastructure automation. It means you can re-run your build any time without fear.

Terraform remembers what it built in a **state** file. Guard it: lose it and Terraform forgets it owns your infrastructure, then cheerfully builds a *second* copy of everything.

### 3.9 What is Ansible?

Terraform builds the **empty house**. Ansible **furnishes** it.

Terraform is excellent at *"make me a server"* and terrible at *"install Java on it."* Ansible is the reverse. Use both, each for what it's good at.

Classically, Ansible works over SSH. **We're not doing that.** We'll use its `aws_ssm` connection plugin, which does the same job over Systems Manager. Same playbooks, same modules, same YAML — different transport.

You write a **playbook** listing **tasks**:

```yaml
- name: Install Java 21
  apt:
    name: openjdk-21-jdk
    state: present    # <-- "present", not "install"
```

Notice `state: present`. Declarative again. It doesn't say *"run apt install."* It says *"Java should be there."* Already there? Ansible does nothing and reports `ok`. Missing? It installs and reports `changed`. **Idempotent**, just like Terraform.

### 3.10 What is Apache NiFi?

A data-movement tool with a drag-and-drop web canvas. You build a **flow** by connecting boxes called **processors**:

- `ListS3` — look in a bucket, emit one record per file
- `FetchS3Object` — download that file's bytes
- `PublishKafka` — publish the bytes to Kafka
- `HandleHttpRequest` — listen on a port for someone to poke it

Data travels as **FlowFiles**: *content* (the bytes) plus *attributes* (metadata like filename, size, S3 key). Think of a manila envelope — the document inside, the label on the front.

NiFi's superpower is **provenance**: it records every single thing that ever happened to every FlowFile. Click any file and see its complete life story. That's why banks and hospitals use it.

### 3.11 What is Apache Kafka?

A message queue — but the better metaphor is a **shared logbook**.

Picture a notebook nailed to a factory wall. Anyone can write a new line at the bottom. Nobody can erase or edit. Each reader keeps their own bookmark.

- A **topic** is one notebook. Ours: `nifi-s3-files`.
- A **producer** writes lines. That's NiFi.
- A **consumer** reads and moves its bookmark. That's our Python script.
- The bookmark is called an **offset**.

The key insight: **the reader's bookmark is the reader's problem.** Kafka doesn't delete a message when you read it and doesn't care if you're slow. Ten consumers can read the same topic at their own pace. If yours crashes, restart it — it picks up exactly where its bookmark was.

Modern Kafka (3.3+) runs in **KRaft mode** and manages itself. Older tutorials tell you to install **ZooKeeper** too. **You do not need ZooKeeper.** It was removed entirely in Kafka 4.0. Any tutorial telling you to install it is out of date.

### 3.12 What is S3?

Infinite file storage. You put **objects** into a **bucket**. Each object has a **key** (its path).

S3 is not a hard drive. You can't open a file, seek to byte 5000, and overwrite four bytes. You can only PUT a whole object or GET a whole object. That constraint is exactly what lets it scale infinitely and cost almost nothing.

Bucket names are **globally unique across every AWS customer on Earth**. If someone in Norway has `my-bucket`, you can't. So we append random hex.

### 3.13 IAM — and why it matters *more* in an SSM build

**IAM** (*Identity and Access Management*) controls who can do what.

The key concept is the **IAM Role**: a set of permissions a *machine* can wear, like a uniform. Attach a role to an EC2 instance, and any program on it inherits those permissions.

Here is the rule you must never break:

> ### 🚨 **NEVER put AWS access keys on an EC2 instance. Use an IAM Role.**

An access key is a **permanent** username and password for your whole AWS account. Write one into a file, and if that server is ever compromised — or that file ever hits GitHub — an attacker owns your account. They'll spin up thousands of GPU instances to mine crypto. People have woken up to $100,000 bills. Bots scan every public GitHub commit **within seconds** looking for exactly this.

An IAM Role has none of those problems:

- Credentials are **temporary** (they expire in hours)
- **Rotated automatically** by AWS
- **Never written to disk** — fetched from a magic address only reachable *inside* the instance
- **Revocable instantly** by detaching the role
- They **die with the instance**

Every AWS SDK checks for a role automatically. You write **zero lines of credential code**.

**And in this build, IAM is not just good practice — it IS the access control mechanism.**

There is no SSH key. The *only* way onto these machines is by having IAM permission to start an SSM session. Which means:

- **Granting access** = adding an IAM permission
- **Revoking access** = removing it. Instantly. Centrally. Certainly.
- **Auditing access** = reading CloudTrail, which logs every session with the principal who opened it

You cannot get that from SSH.

### 3.14 What is the SSM Agent?

A small program that runs on the instance. It:

1. Polls **outbound** to the SSM API over HTTPS
2. Holds open a WebSocket
3. Waits for instructions
4. Executes them and streams the output back

Ubuntu's official AWS AMIs (and Amazon Linux 2023) **ship it preinstalled**. Debian and most non-AWS images do not.

Three conditions must hold or the agent can't register — and if it can't register, **you have no way in at all**, because there's no SSH fallback:

1. The instance role has **`AmazonSSMManagedInstanceCore`**
2. It can **reach the SSM API** (via VPC endpoints, or a NAT gateway)
3. Its security group allows **outbound 443**

Get those three right and everything works. Get one wrong and you're locked out. We'll verify all three explicitly.

---

## 4. Before You Start: The Checklist

### 4.1 What you need

| Item | Why |
|---|---|
| An AWS account | Everything lives here |
| A credit card on it | AWS charges for this |
| A domain name you control | For `nifi.yourdomain.com` |
| A terminal | macOS/Linux built-in; Windows: PowerShell or WSL2 |
| ~$200/month budget | See section 14 — and read it |
| ~2–3 hours | Realistically 3 for a first-timer |

**What you do *not* need:** an SSH client, an SSH key, or PuTTY. You will not generate a key pair anywhere in this tutorial.

### 4.2 Set a billing alarm FIRST

Ninety seconds. It's the difference between a $200 bill and a $9,000 one.

1. Console → search **Budgets** → **Create budget**
2. **Use a template** → **Monthly cost budget**
3. Amount: **$250** (something that would alarm you)
4. Your email → Create

Now a runaway resource emails you instead of surprising you.

### 4.3 Create an IAM user (never use root)

Your **root user** is the email you signed up with. It can do *anything*, including close the account. **Never use it for daily work.**

1. Console → **IAM** → **Users** → **Create user**
2. Name: `admin-yourname`
3. Check **"Provide user access to the AWS Management Console"**
4. **Attach policies directly** → `AdministratorAccess`
5. Create. Save the sign-in URL and password.
6. **Sign out of root. Sign back in as the new user.**
7. IAM → your user → **Security credentials** → **Enable MFA**. Do it. Two minutes with your phone.

### 4.4 Install the AWS CLI (on your laptop)

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install

aws --version   # want aws-cli/2.x
```

Configure it with your IAM user's access key (this is on *your laptop*, which is fine — the rule about no keys applies to *servers*, which can be compromised and can't type an MFA code):

```bash
aws configure
# paste your access key + secret, region us-east-1, output json

aws sts get-caller-identity   # should print your user ARN
```

### 4.5 🔑 Install the Session Manager plugin — **this is the one people miss**

The AWS CLI can *call* the SSM API on its own, but `aws ssm start-session` needs a **separate helper binary** to broker the WebSocket and wire it to your terminal.

**It is not bundled with the CLI.** AWS ships it separately. Without it you get a baffling error, and you will assume SSM is broken when actually you're just missing a program.

```bash
# ---- macOS ----
brew install --cask session-manager-plugin

# ---- Ubuntu / Debian ----
curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
  -o session-manager-plugin.deb
sudo dpkg -i session-manager-plugin.deb
rm session-manager-plugin.deb

# ---- Verify ----
session-manager-plugin --version
```

You should see a version number. If you get "command not found," stop and fix it now. Nothing later in this tutorial will work.

> **You will install this again on the Command Node**, because Ansible's SSM connection plugin shells out to this exact same binary. Two installs: laptop, and Command Node.

### 4.6 Find your public IP

You'll use this to let *only you* reach the NiFi web UI.

```bash
curl -s https://checkip.amazonaws.com
```

Prints something like `203.0.113.45`. In firewall rules you'll write it as `203.0.113.45/32` — the `/32` means *"exactly this one address, nothing else."*

> ⚠️ **Home IPs change.** Your ISP will hand you a new one eventually, often after a router reboot. When the NiFi UI suddenly stops loading one morning, this is almost always why. Re-run the command, update the rule. Normal and expected.
>
> **Note this only affects the ALB rule** — your ability to `ssm start-session` is *not* IP-dependent. That's another quiet advantage: your admin access doesn't break when your IP changes.

---

## 5. PART ONE — Step-by-Step: Build the Command Node

This is the one thing you build by hand. Everything after is automated.

### Step 1 — Create the IAM role FIRST

**Do this before launching the instance.** In an SSM build the role isn't an afterthought — **it is the only way in**. Launch without it and you have created a machine you cannot access.

1. Console → **IAM** → **Roles** → **Create role**
2. **Trusted entity type:** **AWS service**
3. **Use case:** **EC2** → Next
4. **Permissions** — attach **both**:
   - ✅ **`AmazonSSMManagedInstanceCore`** ← **without this you cannot get in. At all.**
   - ✅ **`AdministratorAccess`** ← so Terraform can build things
5. Next → **Role name:** `command-node-role`
6. **Create role**

> **On `AdministratorAccess`:** yes, it's broad. Terraform genuinely needs to create VPCs, IAM roles, security groups, load balancers, S3 buckets, and EC2 instances — an enormous surface. Section 11 explains how to scope it down properly for a real company. For a personal learning account, admin is the pragmatic choice.
>
> **On `AmazonSSMManagedInstanceCore`:** this one is **not optional and not negotiable**. It grants the agent permission to register with SSM. Forget it and the instance boots, runs perfectly, and is completely unreachable. You'd have to terminate it and start over.

### Step 2 — Launch the instance

Console → **EC2** → **Instances** → **Launch instances**

1. **Name:** `command-node`

2. **Application and OS Images:** search **Ubuntu** → **Ubuntu Server 24.04 LTS**, 64-bit (x86)
   - *(24.04 is the current LTS — Long Term Support — patched until 2029. Always pick LTS for infrastructure. It also ships the SSM Agent preinstalled, which we're relying on.)*

3. **Instance type:** `t3.small`
   - *(Not `t3.micro`. 1 GB of RAM genuinely isn't enough — Terraform's providers and Ansible's Python will thrash and occasionally get killed by the kernel's OOM killer. The extra $7/month buys sanity.)*

4. ### **Key pair (login): select "Proceed without a key pair"** ⭐

   > **Yes. Really.** AWS will show you a warning. **Ignore it.** It assumes you want SSH. You don't.
   >
   > This is the moment the whole design becomes real. You are launching a server **with no key**. There will be no `authorized_keys` file. Even if someone did somehow open port 22, there would be **nothing to authenticate against**.
   >
   > You'll get in via SSM in about four minutes. Trust the process.

5. **Network settings** → **Edit**:
   - **VPC:** the **default VPC** (AWS gave you one free)
   - **Subnet:** any
   - **Auto-assign public IP:** **Enable**
     - *(Why? Not for you to connect to — you never will. It's so the SSM Agent can reach the SSM API through the default VPC's internet gateway. In the data VPC we build later, we'll use private VPC endpoints instead and there'll be no public IP at all.)*
   - **Firewall (security groups):** **Create security group**
     - Name: `command-node-sg`
     - Description: `SSM only. No inbound rules.`
     - ### **DELETE the default SSH rule.**
       AWS pre-populates an SSH rule on port 22. **Remove it.** Click the ✕.
     - **Leave the inbound rules list completely empty.**

   > 🎯 **Look at what you just did.** You created a security group with **zero inbound rules**. Nothing can connect to this machine. Not you, not a bot, not anyone.
   >
   > And in four minutes you'll have a root shell on it.
   >
   > That's the entire point of SSM.

6. **Configure storage:** `30 GiB`, **`gp3`**
   - *(The 8 GB default fills fast once you have Terraform providers, Ansible collections, and cached downloads. `gp3` is the modern SSD — cheaper **and** faster than the old `gp2`. Always pick gp3.)*

7. **Advanced details** → scroll to **IAM instance profile** → select **`command-node-role`**
   - ### **Do not skip this.** This is your only way in.

8. **Launch instance**

### Step 3 — Wait for the agent to register

The instance boots in ~60 seconds. The SSM Agent then takes another ~30–60 seconds to phone home.

```bash
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,Platform:PlatformName}' \
  --output table
```

Keep running it until you see:

```
-----------------------------------------------------
|          DescribeInstanceInformation              |
+----------------------+---------+------------------+
|          ID          |  Ping   |    Platform      |
+----------------------+---------+------------------+
|  i-0abc123def456789  | Online  |  Ubuntu          |
+----------------------+---------+------------------+
```

**`Online` is what you're waiting for.**

> **Empty table after 3 minutes?** Three causes, in order of likelihood:
> 1. **You forgot the IAM role** (Step 7 of the launch wizard). Fix: EC2 → Instance → **Actions** → **Security** → **Modify IAM role** → attach `command-node-role`. Wait 60s.
> 2. **The role is missing `AmazonSSMManagedInstanceCore`.** Check it in IAM.
> 3. **No outbound internet.** The default VPC has an internet gateway, so this is unlikely — but confirm the instance got a public IP.
>
> **Do not proceed until it says Online.** There is no fallback.

### Step 4 — Get a shell. No SSH. No key.

```bash
aws ssm start-session --target i-0abc123def456789
```

*(Use your own instance ID.)*

```
Starting session with SessionId: admin-yourname-0a1b2c3d4e5f
$
```

**You are inside the machine.**

Stop and appreciate what just happened:

- ❌ No SSH client
- ❌ No private key
- ❌ No `authorized_keys`
- ❌ No open port — the security group has **zero inbound rules**
- ❌ No bastion host
- ✅ Just an AWS API call, authenticated by IAM, **logged in CloudTrail** with your name on it

You land as the `ssm-user`. Become `ubuntu`:

```bash
sudo su - ubuntu
cd ~
```

Everything from here happens **on the Command Node**.

> **Tip:** an SSM session times out after ~20 minutes of inactivity. If you get dropped mid-task, just `start-session` again. To make long jobs survive, run them under `tmux` (we'll install it in a moment).

### Step 5 — Verify the IAM role works

Before installing anything, prove the role works. This is the best sanity check in AWS.

```bash
aws sts get-caller-identity
```

```json
{
    "UserId": "AROA...:i-0abc123def456789",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/command-node-role/i-0abc123def456789"
}
```

Look at that `Arn`: **`assumed-role/command-node-role`**.

That is AWS confirming: *"this machine is wearing the command-node-role uniform."* No keys were involved. Nothing is on disk. It just works.

> **`Unable to locate credentials` instead?** The role isn't attached, or hasn't propagated. Wait 30 seconds and retry once. If it persists, re-attach it in the console.

### Step 6 — Update and install base tools

```bash
sudo apt update && sudo apt upgrade -y
```

*(Purple screen about restarting services? Tab to `<Ok>`, Enter. Asked about a modified config file? Keep the local version — the default.)*

```bash
sudo apt install -y \
  curl wget unzip git jq tmux \
  python3-pip python3-venv \
  gnupg software-properties-common \
  netcat-openbsd
```

| Package | Why |
|---|---|
| `curl`, `wget` | Download things |
| `unzip` | Extract archives |
| `git` | You'll version-control your Terraform |
| `jq` | Parse JSON on the CLI. AWS returns JSON everywhere. **Invaluable.** |
| `tmux` | Keeps long jobs alive if your SSM session drops. **Genuinely useful here.** |
| `python3-venv` | Ubuntu 24.04 *requires* venvs — see Step 11 |
| `netcat-openbsd` | `nc`, for testing whether a port is reachable |

### Step 7 — Install Terraform

We install from HashiCorp's **official APT repository**, not a zip download. That way `apt upgrade` keeps Terraform patched forever. Download a zip and you'll be running a two-year-old Terraform without realizing.

```bash
# 1. Download HashiCorp's GPG signing key
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# 2. Add their repo, telling apt to trust ONLY packages signed by that key
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# 3. Install
sudo apt update && sudo apt install -y terraform

terraform version
```

```
Terraform v1.10.5
on linux_amd64
```

> **Why the GPG dance?** Without it, `apt` downloads software over the network with no way to know it wasn't tampered with in transit. The signing key lets apt cryptographically verify the package really came from HashiCorp. This isn't paranoia — it's how you avoid supply-chain attacks.
>
> Note we use `signed-by=` and a keyring file, **not** the old `apt-key add`. That command is **deprecated and insecure** because it trusted the key for *every* repository, not just HashiCorp's.

Enable tab-completion:

```bash
terraform -install-autocomplete
source ~/.bashrc
```

### Step 8 — Install Ansible **and the SSM connection plugin**

```bash
sudo apt install -y ansible
ansible --version   # want 2.16+
```

Now the critical part:

```bash
ansible-galaxy collection install amazon.aws community.aws community.general
```

> ### ⭐ `community.aws` is the important one.
>
> It provides the **`aws_ssm` connection plugin** — the thing that lets Ansible reach a host **without SSH**.
>
> Without this collection installed, Ansible has exactly one way to reach a Linux box: SSH. And we have no SSH. Miss this and nothing works.

Ansible needs `boto3` to talk to AWS:

```bash
sudo apt install -y python3-boto3 python3-botocore
```

### Step 9 — Install the Session Manager plugin (again — on the Command Node)

You installed this on your laptop. **You need it here too.**

Why? Because the Command Node is about to become the **Ansible controller**. Ansible's `aws_ssm` plugin doesn't speak the SSM WebSocket protocol itself — it **shells out to this exact binary**.

No plugin → every Ansible task fails with a vague error that never mentions the plugin.

```bash
cd /tmp
curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
  -o session-manager-plugin.deb
sudo dpkg -i session-manager-plugin.deb
rm session-manager-plugin.deb
cd ~

/usr/local/sessionmanagerplugin/bin/session-manager-plugin --version
```

**Note that path.** `/usr/local/sessionmanagerplugin/bin/session-manager-plugin`. Ansible needs to be told exactly where it lives, and we'll put it in `group_vars`.

### Step 10 — Verify the AWS CLI

```bash
aws --version
```

If it says `aws-cli/1.x`, upgrade — v1 is ancient:

```bash
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip
cd ~
aws --version   # now 2.x
```

Set the default region:

```bash
aws configure set region us-east-1
aws configure set output json
```

> **Notice what we did NOT do:** we did not run plain `aws configure` and paste an access key. Only region and output format. **The credentials come from the IAM role, invisibly.** That is the whole point.

### Step 11 — Set up Python properly (this trips up everyone)

Ubuntu 24.04 enforces **PEP 668**. Try `pip install kafka-python` and you get:

```
error: externally-managed-environment
× This environment is externally managed
```

This is Ubuntu protecting itself. System Python runs system tools — **`apt` itself is written in Python.** `pip install` a package that upgrades a shared library, and you can genuinely break your ability to install *anything*, including the thing that would fix it. People have bricked servers this way.

The fix is a **virtual environment** — an isolated Python sandbox.

```bash
mkdir -p ~/.venvs
python3 -m venv ~/.venvs/nifi-kafka
source ~/.venvs/nifi-kafka/bin/activate     # prompt now shows (nifi-kafka)

pip install --upgrade pip
pip install requests kafka-python boto3

python -c "import kafka, requests, boto3; print('All libraries OK')"
```

Leave with `deactivate`. Re-enter with `source ~/.venvs/nifi-kafka/bin/activate`.

> 🚨 **Never use `pip install --break-system-packages`** to force past that error, even though the message suggests it. The flag is named "break system packages" because **that is literally what it does.** Use a venv.

### Step 12 — Create the S3 backend for Terraform state

Terraform's state file is precious. Keep it on the Command Node's local disk and one accidental `rm` — or one terminated instance — loses the map to your entire infrastructure. Put it in S3.

```bash
SUFFIX=$(openssl rand -hex 4)
BUCKET="tfstate-cmdnode-${SUFFIX}"
echo "$BUCKET" > ~/tf-bucket-name.txt
echo "Your state bucket: $BUCKET"

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1

# Versioning: every save keeps the old copy, so you can ALWAYS roll back
# a corrupted state file. Do not skip this.
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# State files contain secrets. This must NEVER be public.
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Done: $BUCKET"
```

> **On state locking:** older tutorials say to create a DynamoDB table. As of **Terraform 1.10+**, S3 has **native state locking** via `use_lockfile = true`. DynamoDB is no longer needed and is deprecated for this. We'll use the modern way. (Locking stops two people running `apply` simultaneously and corrupting state.)

### Step 13 — Configure Git

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
```

### Step 14 — Grab the values Terraform needs

Terraform needs to know the Command Node's **security group** (to write the rule that lets it reach Kafka) and its **VPC**.

```bash
# IMDSv2 requires fetching a token first. This is a security improvement
# over IMDSv1 -- see the box below.
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "Instance ID: $INSTANCE_ID"

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{SG:SecurityGroups[0].GroupId,VPC:VpcId}' \
  --output table
```

**Write down the `SG` and `VPC` values.** You'll paste them into Terraform next.

> ### What is `169.254.169.254`?
>
> The **Instance Metadata Service** — a magic address that only exists *inside* an EC2 instance. From there an instance can ask about itself: its ID, its region, and critically, its **temporary IAM role credentials**.
>
> **This is exactly how the "no keys on disk" magic works.** The AWS SDK quietly curls this address, gets a temporary credential, and uses it.
>
> The `TOKEN` step is **IMDSv2**, which requires a PUT first. This was added specifically to defeat **SSRF attacks** — where a tricked web app could be made to fetch credentials from this address and leak them. IMDSv1 (no token) was the vector in the **2019 Capital One breach**, which exposed 100 million records. Always use v2. Our Terraform will *enforce* it.

### Step 15 — Final verification

```bash
echo "=== Command Node Status ==="
echo "Terraform : $(terraform version | head -1)"
echo "Ansible   : $(ansible --version | head -1)"
echo "AWS CLI   : $(aws --version)"
echo "Python    : $(python3 --version)"
echo "jq        : $(jq --version)"
echo ""
echo "=== SSM plugin (REQUIRED for Ansible) ==="
/usr/local/sessionmanagerplugin/bin/session-manager-plugin --version
echo ""
echo "=== community.aws collection (REQUIRED -- provides aws_ssm) ==="
ansible-galaxy collection list community.aws 2>/dev/null | grep community.aws || echo "  !!! MISSING !!!"
echo ""
echo "=== IAM Identity (must say 'assumed-role') ==="
aws sts get-caller-identity --query Arn --output text
echo ""
echo "=== State bucket ==="
cat ~/tf-bucket-name.txt
```

Every line should print something sensible, the ARN must contain `assumed-role/command-node-role`, and `community.aws` must be listed.

### Step 16 — Prove there is no SSH surface

Let's actually verify the claim.

```bash
# What inbound rules does the Command Node's SG have?
aws ec2 describe-security-groups --group-ids <YOUR_SG_ID> \
  --query 'SecurityGroups[0].IpPermissions' --output json
```

```json
[]
```

**An empty array.** Zero inbound rules. Nothing on Earth can open a connection to this machine.

And yet you are sitting at a root shell on it.

```bash
# Is an SSH daemon even listening?
sudo ss -tlnp | grep :22
```

You may see `sshd` listening on `0.0.0.0:22`. **That's fine — and it's worth understanding why.**

Ubuntu ships with `sshd` running by default. But the security group blocks every inbound packet, so **no packet ever reaches it.** The daemon is listening into a void. And there's no `authorized_keys` file anyway, because you launched without a key pair — so even a packet that somehow arrived would have nothing to authenticate against.

Two independent barriers. If you want to remove the daemon entirely (belt *and* braces):

```bash
sudo systemctl disable --now ssh
sudo systemctl status ssh   # inactive (dead)
```

You will not miss it. You're not using it.

**🎉 Your Command Node is complete.** You have a chair to direct from — and no lock on the door, because there is no door.
---

## 6. PART TWO — The Big Terraform Build

Now we describe the entire rest of the system in text, and let Terraform build it.

### 6.1 Project layout

On the **Command Node**:

```bash
mkdir -p ~/infra/terraform ~/infra/ansible ~/infra/python-app
cd ~/infra
git init
```

Terraform doesn't care about filenames — it reads *every* `.tf` file in a folder and mashes them together. The split below is purely for humans.

```
~/infra/terraform/
├── versions.tf      <- Terraform + provider versions, S3 backend
├── variables.tf     <- Every knob (note: NO ssh_key_name!)
├── network.tf       <- VPC, subnets, gateways, routes, peering
├── security.tf      <- ALL the security groups. ZERO port-22 rules.
├── s3.tf            <- Buckets + the endpoints that make SSM work
├── iam.tf           <- Roles: NiFi→S3, both→SSM
├── compute.tf       <- NiFi and Kafka EC2 (note: NO key_name!)
├── alb.tf           <- Load balancer, certificate, DNS
├── outputs.tf       <- What Terraform prints when done
└── terraform.tfvars <- YOUR values (git-ignored!)
```

### 6.2 Protect yourself from committing secrets — do this first

**Before you write a single line of code.** People leak AWS keys by committing them, and it costs them dearly.

```bash
cd ~/infra
cat > .gitignore <<'EOF'
# NEVER commit these
*.tfvars
!*.tfvars.example
*.tfstate
*.tfstate.*
.terraform/
tfplan
crash.log

# There are no keys in this project (SSM-only), but belt and braces:
*.pem
*.key
id_rsa*
id_ed25519*

# Python
.venv/
__pycache__/
EOF

git add .gitignore && git commit -m "gitignore before anything else"
```

### 6.3 `versions.tf` — pin everything

```hcl
# versions.tf

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"   # allows 5.70 -> 5.99, BLOCKS 6.0
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in S3 with NATIVE locking (Terraform 1.10+).
  # No DynamoDB table needed anymore.
  backend "s3" {
    bucket       = "REPLACE_WITH_YOUR_BUCKET"   # from Part One, Step 12
    key          = "nifi-kafka/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true                          # <-- the modern way
  }
}

provider "aws" {
  region = var.aws_region

  # Tag EVERY resource automatically. Future-you will be grateful when
  # the bill arrives and you can actually filter by Project.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}
```

> **The `~>` operator** is the "pessimistic constraint." `~> 5.70` means *"at least 5.70, but don't you dare go to 6.x."* Major version bumps are where breaking changes live. This one line prevents a whole class of 3am incidents.

### 6.4 `variables.tf` — note what's *missing*

```hcl
# variables.tf

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "nifi-platform"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "owner" {
  description = "Who owns this (for tags/billing)"
  type        = string
}

# ---------- NETWORK ----------

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be valid CIDR, e.g. 10.20.0.0/16"
  }
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "An ALB requires at least 2 subnets in 2 different AZs."
  }
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}

# ---------- COMMAND NODE (from Part One, Step 14) ----------

variable "command_node_sg_id" {
  type = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.command_node_sg_id))
    error_message = "Must look like sg-0a1b2c3d4e5f67890"
  }
}

variable "command_node_vpc_id" {
  type = string
}

variable "command_node_vpc_cidr" {
  type    = string
  default = "172.31.0.0/16"   # the default VPC is usually this
}

# ---------- DOMAIN ----------

variable "domain_name" {
  type = string
}

variable "nifi_subdomain" {
  type    = string
  default = "nifi"
}

variable "route53_zone_id" {
  type = string
}

# ---------- ACCESS ----------

variable "my_ip_cidr" {
  description = "Your public IP /32. Who may reach the NiFi UI."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "Must be CIDR, e.g. 203.0.113.45/32"
  }
}

# ==================================================================
# NOTE WHAT IS *NOT* HERE:
#
#   variable "ssh_key_name" { ... }     <-- DOES NOT EXIST
#
# There is no key pair in this build. Nothing to name, nothing to
# configure, nothing to leak.
# ==================================================================

# ---------- SIZING ----------

variable "nifi_instance_type" {
  type    = string
  default = "t3.large"   # NiFi is a JVM app. Give it RAM.
}

variable "kafka_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "nifi_volume_size" {
  type    = number
  default = 100
}

variable "kafka_volume_size" {
  type    = number
  default = 100
}

# ---------- APP ----------

variable "kafka_topic" {
  type    = string
  default = "nifi-s3-files"
}

variable "nifi_http_listener_port" {
  type    = number
  default = 9999
}
```

> **Those `validation` blocks earn their keep.** They catch a typo in 200 milliseconds instead of letting Terraform run for six minutes, half-build your VPC, and *then* explode with a cryptic AWS API error. Always validate.

### 6.5 `network.tf` — the VPC and plumbing

```hcl
# network.tf

# Ask AWS which AZs exist RIGHT NOW. Don't hardcode "us-east-1a" --
# not every AZ supports every instance type, and this adapts.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name      = "${var.project_name}-${var.environment}"
  azs       = slice(data.aws_availability_zones.available.names, 0, 2)
  nifi_fqdn = "${var.nifi_subdomain}.${var.domain_name}"
}

# ============================================================
# THE VPC
# ============================================================
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # BOTH must be true or AWS-internal DNS breaks.
  # Without them your VPC endpoints silently fail and you will lose
  # an hour wondering why the SSM agent can't reach anything.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# ============================================================
# INTERNET GATEWAY -- the door to the internet.
# A subnet becomes "public" ONLY when its route table points here.
# ============================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# ============================================================
# PUBLIC SUBNETS -- these hold ONLY the load balancer.
# ============================================================
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

# ============================================================
# PRIVATE SUBNETS -- NiFi and Kafka live here.
#
# No route to the internet gateway = unreachable from outside.
# Not "firewalled." UNROUTABLE. There is no path.
#
# Normally that would mean you can't administer them either.
# With SSM, you can. That's the whole trick.
# ============================================================
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # map_public_ip_on_launch is ABSENT. It defaults to false.
  # That single omission is what makes this subnet private.

  tags = {
    Name = "${local.name}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ============================================================
# NAT GATEWAY -- lets private servers reach OUT (to apt, to
# download NiFi and Java) while blocking anything reaching IN.
# A one-way mirror.
#
# 💰 ~$32/month + $0.045/GB. The most expensive thing in this
# build. Section 14 shows how to eliminate it.
# ============================================================
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # the NAT itself must sit in a PUBLIC subnet

  tags       = { Name = "${local.name}-nat" }
  depends_on = [aws_internet_gateway.main]
}

# ============================================================
# ROUTE TABLES -- the signposts that decide where packets go.
# ============================================================

# Public: "anything not local? -> Internet Gateway"
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"          # means "literally anywhere"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

# Private: "anything not local? -> NAT Gateway"
# NOTE: no route to the IGW. That is the entire point.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-private" }
}

# A route table does NOTHING until you associate it with a subnet.
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# VPC PEERING -- a private tunnel from the Command Node's VPC
# to the new data VPC.
#
# WHY? The requirement says Kafka must be reachable from the
# Command Node. Without peering, the Command Node would have to
# reach Kafka over the public internet -- which would mean giving
# Kafka a public IP. We are not doing that.
#
# Peering keeps ALL of this on Amazon's private backbone. It never
# touches the internet.
#
# NOTE: peering is for the DATA path (Kafka 9092, NiFi 9999).
# The SSM control path does NOT need it -- SSM goes through the
# AWS API, not through your network. Two separate paths.
#
# Peering has NO hourly charge. You pay only for data transferred.
# ============================================================
resource "aws_vpc_peering_connection" "command_to_data" {
  vpc_id      = var.command_node_vpc_id   # requester
  peer_vpc_id = aws_vpc.main.id           # accepter
  auto_accept = true                      # works: both VPCs are in OUR account

  accepter  { allow_remote_vpc_dns_resolution = true }
  requester { allow_remote_vpc_dns_resolution = true }

  tags = { Name = "${local.name}-peering" }
}

# A peering connection is just a pipe. NOTHING flows until you add
# ROUTES AT BOTH ENDS. Forgetting one direction is the #1 peering
# mistake -- traffic goes out and the reply never comes back.

# Data VPC -> Command VPC
resource "aws_route" "data_to_command" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.command_node_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.command_to_data.id
}

# Command VPC -> Data VPC (we must edit the DEFAULT VPC's route tables)
data "aws_route_tables" "command_vpc" {
  vpc_id = var.command_node_vpc_id
}

resource "aws_route" "command_to_data" {
  count = length(data.aws_route_tables.command_vpc.ids)

  route_table_id            = tolist(data.aws_route_tables.command_vpc.ids)[count.index]
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.command_to_data.id
}
```

### 6.6 `security.tf` — **THE MOST IMPORTANT FILE**

Read every comment. Two requirements live here: *"only NiFi and the Command Node may reach Kafka"* and *"no SSH."*

```hcl
# security.tf
# ==================================================================
# THE SECURITY MODEL (SSM-ONLY):
#
#   Your laptop ──(AWS API 443)──> AWS Systems Manager
#                                        │
#                    agent polls OUT     │  (no inbound, ever)
#                                        v
#   Internet ──(443)──> [ALB SG] ──(8443)──> [NiFi SG]
#                                                │
#                                             (9092)
#                                                v
#              [Command Node SG] ──(9092)──> [Kafka SG]
#
# THERE IS NO PORT 22 ANYWHERE IN THIS FILE.
# Search it. You will not find a single `from_port = 22`.
# ==================================================================

# ------------------------------------------------------------------
# ALB SG -- the ONLY thing touching the public internet
# ------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public entry point. HTTPS only."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb-sg" }

  lifecycle { create_before_destroy = true }  # avoids "SG in use" errors
}

resource "aws_security_group_rule" "alb_in_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]   # <-- ONLY YOU
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from my IP only"

  # To open NiFi to the world you'd put ["0.0.0.0/0"] here.
  # DON'T. NiFi's UI is a powerful admin console -- anyone who reaches
  # it can build a flow that reads your entire S3 bucket.
}

resource "aws_security_group_rule" "alb_in_http_redirect" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, only to 301-redirect to HTTPS"
}

resource "aws_security_group_rule" "alb_out_to_nifi" {
  type                     = "egress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nifi.id   # <-- BADGE, not IP
  security_group_id        = aws_security_group.alb.id
  description              = "ALB -> NiFi only. Nothing else."
}

# ------------------------------------------------------------------
# NIFI SG
#
# INBOUND: exactly TWO rules. The ALB, and the Command Node's trigger.
#          NO SSH. Ansible reaches this host over SSM, which needs
#          ZERO inbound rules.
# ------------------------------------------------------------------
resource "aws_security_group" "nifi" {
  name        = "${local.name}-nifi-sg"
  description = "NiFi. No inbound SSH. Managed via SSM."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-nifi-sg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "nifi_in_from_alb" {
  type                     = "ingress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.nifi.id
  description              = "NiFi web UI, from the ALB ONLY"
}

resource "aws_security_group_rule" "nifi_in_http_listener_from_command" {
  type                     = "ingress"
  from_port                = var.nifi_http_listener_port   # 9999
  to_port                  = var.nifi_http_listener_port
  protocol                 = "tcp"
  source_security_group_id = var.command_node_sg_id
  security_group_id        = aws_security_group.nifi.id
  description              = "The Python trigger app pokes NiFi here"
}

# ==================================================================
# >>> NOTE WHAT IS NOT HERE <<<
#
# In an SSH build, you'd need a rule like:
#
#     resource "aws_security_group_rule" "nifi_in_ssh" {
#       from_port                = 22
#       source_security_group_id = var.command_node_sg_id
#     }
#
# ...so Ansible could get in. WE DO NOT NEED THAT RULE.
#
# SSM works because the agent RUNNING ON THIS HOST polls OUTBOUND
# to the SSM API. The connection is established from the inside out.
# Nothing ever needs to connect INTO this machine.
#
# This is strictly stronger than "SSH, but only from the bastion."
# There is no exposed SSH daemon to attack. At all.
# ==================================================================

# --- NiFi OUTBOUND ---
# Deliberately specific. Unrestricted egress is how a compromised host
# EXFILTRATES your data. Least privilege applies outbound too.

resource "aws_security_group_rule" "nifi_out_to_kafka" {
  type                     = "egress"
  from_port                = 9092
  to_port                  = 9092
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.kafka.id
  security_group_id        = aws_security_group.nifi.id
  description              = "NiFi -> Kafka"
}

resource "aws_security_group_rule" "nifi_out_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nifi.id
  description       = "HTTPS out: SSM AGENT, S3 endpoint, apt via NAT"

  # ^ THIS RULE IS LOAD-BEARING FOR SSM.
  # The agent connects OUT on 443. Remove this and the agent cannot
  # reach SSM, the instance never registers, and you have PERMANENTLY
  # LOCKED YOURSELF OUT. There is no SSH fallback. Do not remove it.
}

resource "aws_security_group_rule" "nifi_out_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nifi.id
  description       = "HTTP out: Ubuntu apt repos"
}

# ==================================================================
# 🔒 KAFKA SG -- THE CENTREPIECE
#
# Requirement: "only allow access from the EC2 command server and
#               nifi on this subnet security group"
#
# TWO ingress rules on 9092. BOTH use source_security_group_id
# (badges), NOT cidr_blocks (addresses).
#
# NOT specified anywhere:
#   - 0.0.0.0/0        (the internet)
#   - 10.20.0.0/16     (the whole VPC)
#   - any hardcoded IP
#   - port 22          (there is no SSH in this build)
#
# Therefore: unreachable by anything else. Full stop.
# ==================================================================
resource "aws_security_group" "kafka" {
  name        = "${local.name}-kafka-sg"
  description = "Kafka. 9092 open to EXACTLY two SGs. No SSH."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-kafka-sg" }

  lifecycle { create_before_destroy = true }
}

# ==== ALLOWED SOURCE #1: NIFI ====
resource "aws_security_group_rule" "kafka_in_from_nifi" {
  type                     = "ingress"
  from_port                = 9092
  to_port                  = 9092
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nifi.id
  security_group_id        = aws_security_group.kafka.id
  description              = "ALLOWED: NiFi may produce to Kafka"
}

# ==== ALLOWED SOURCE #2: THE COMMAND NODE ====
resource "aws_security_group_rule" "kafka_in_from_command_node" {
  type                     = "ingress"
  from_port                = 9092
  to_port                  = 9092
  protocol                 = "tcp"
  source_security_group_id = var.command_node_sg_id
  security_group_id        = aws_security_group.kafka.id
  description              = "ALLOWED: Command Node may consume from Kafka"
}

# ==== THERE IS NO SOURCE #3. AND NO PORT 22. THAT IS THE POINT. ====

resource "aws_security_group_rule" "kafka_out_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.kafka.id
  description       = "HTTPS out: SSM AGENT + package downloads"
  # ^ also load-bearing for SSM. See the NiFi note above.
}

resource "aws_security_group_rule" "kafka_out_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.kafka.id
  description       = "HTTP out for apt"
}

# ------------------------------------------------------------------
# VPC ENDPOINT SG
#
# The SSM interface endpoints are ENIs living in your private subnets.
# The instances connect OUT to them on 443. This SG is what permits
# that -- and it's why the instances themselves need no inbound rules.
# ------------------------------------------------------------------
resource "aws_security_group" "vpce" {
  name        = "${local.name}-vpce-sg"
  description = "Lets private instances reach the SSM/AWS API endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
    description = "HTTPS from private subnets (SSM agent traffic)"
  }

  tags = { Name = "${local.name}-vpce-sg" }
}
```

> ### 🎯 Why `source_security_group_id` beats `cidr_blocks` — one final time
>
> | | `cidr_blocks = ["10.20.11.47/32"]` | `source_security_group_id = aws_security_group.nifi.id` |
> |---|---|---|
> | NiFi reboots with a new IP | ❌ **Silently breaks** | ✅ Still works |
> | You replace NiFi entirely | ❌ Breaks | ✅ Still works |
> | You scale to 3 NiFi nodes | ❌ Edit rules by hand | ✅ Automatic |
> | Someone launches a **rogue box** in that subnet | ❌ **They can reach Kafka** | ✅ **Blocked — no badge** |
> | Reads clearly in an audit | ❌ "What is 10.20.11.47?" | ✅ "Ah — NiFi. Obviously." |
>
> **That fourth row is the security argument.** If you allow `10.20.0.0/16`, **every machine in that VPC — including ones you didn't create — can hit Kafka.** With badges, only what actually wears the badge gets in.

### 6.7 `s3.tf` — the buckets and the endpoints that make SSM work

```hcl
# s3.tf

resource "random_id" "suffix" {
  byte_length = 4
}

# ==================================================================
# THE DATA BUCKET -- where your .txt files land
# ==================================================================
resource "aws_s3_bucket" "nifi_data" {
  bucket = "${local.name}-drop-${random_id.suffix.hex}"
  tags   = { Name = "${local.name}-drop" }
}

resource "aws_s3_bucket_versioning" "nifi_data" {
  bucket = aws_s3_bucket.nifi_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nifi_data" {
  bucket = aws_s3_bucket.nifi_data.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# 🚨 BLOCK ALL PUBLIC ACCESS. Every "company leaks 100M records"
# headline you have ever read was an S3 bucket missing this block.
# All four flags. Always.
resource "aws_s3_bucket_public_access_block" "nifi_data" {
  bucket                  = aws_s3_bucket.nifi_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==================================================================
# ⭐ THE SSM TRANSFER BUCKET -- YOU ONLY NEED THIS BECAUSE OF SSM
#
# WHY DOES THIS EXIST?
#
# Ansible works by copying a Python module to the target host and
# running it. Over SSH it would SFTP the file.
#
# SSM HAS NO FILE CHANNEL. It carries only a command stream.
#
# So the aws_ssm plugin does this instead:
#   1. Ansible uploads the module to THIS bucket (presigned PUT)
#   2. Ansible tells the host, over SSM: "curl this URL and run it"
#   3. The host downloads it FROM S3 and executes it
#   4. Output comes back over the SSM command channel
#
# That is why an SSM-only Ansible setup needs a bucket and an SSH
# one does not. It is the price of admission for zero open ports.
# ==================================================================
resource "aws_s3_bucket" "ssm_transfer" {
  bucket        = "${local.name}-ssm-transfer-${random_id.suffix.hex}"
  force_destroy = true   # scratch bucket; let `terraform destroy` clean it

  tags = {
    Name    = "${local.name}-ssm-transfer"
    Purpose = "Ansible aws_ssm connection plugin file transfer"
  }
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# The scratch files are transient. Bin them after a day.
resource "aws_s3_bucket_lifecycle_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id

  rule {
    id     = "expire-ansible-scratch"
    status = "Enabled"
    filter {}
    expiration { days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# ==================================================================
# S3 GATEWAY VPC ENDPOINT
#
# Without it: S3 traffic goes out through the NAT Gateway, onto the
#             public internet, and back. You pay $0.045/GB.
#
# With it:    S3 traffic takes a private road inside AWS. Never
#             touches the internet. And it is completely FREE.
#
# DOUBLY important in an SSM build: the Ansible plugin pushes EVERY
# module through S3. Without this endpoint, all of that would be
# billed through the NAT Gateway.
#
# There is no downside. Always create it. It is free money.
# ==================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # A gateway endpoint works by injecting routes into route tables.
  route_table_ids = [aws_route_table.private.id]

  tags = { Name = "${local.name}-s3-endpoint" }
}

# ==================================================================
# ⭐⭐⭐ THE THREE SSM ENDPOINTS -- WITHOUT THESE, NOTHING WORKS ⭐⭐⭐
#
# These are NOT optional in an SSM-only design. ALL THREE are
# required, and people constantly forget the third:
#
#   ssm          -- the Session Manager / Run Command API
#   ssmmessages  -- the WebSocket that carries your actual shell
#   ec2messages  -- the legacy Run Command channel. STILL REQUIRED.
#
# Miss any ONE and your instance either never registers, or shows
# "Connection lost" in the console. It is THE #1 cause of
# "SSM doesn't work in my private subnet."
#
# ec2messages sounds legacy. It sounds optional. IT IS NEITHER.
#
# Cost: ~$7.30/mo each = ~$22/mo. This is the price you pay for
# having zero open ports. It is worth it.
# ==================================================================
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true   # <-- MUST be true

  # ^ If private_dns_enabled is false, the agent resolves
  #   ssm.us-east-1.amazonaws.com to the PUBLIC IP and tries to go
  #   out via NAT. It may work; it may hang. Set it true.

  tags = { Name = "${local.name}-${each.key}-endpoint" }
}
```

### 6.8 `iam.tf` — where access control actually lives now

```hcl
# iam.tf
# ==================================================================
# In an SSM-only build, IAM is not just "nice to have."
# IT IS THE ACCESS CONTROL MECHANISM.
#
# There is no SSH key to hold. The ONLY way onto these boxes is to
# have IAM permission to start an SSM session. Which means:
#
#   - Revoking access = removing one IAM permission.
#     Instant. Central. Certain.
#   - vs SSH, where revoking = hunting down every copy of a key that
#     may have been emailed, copied, or committed. You'll never be sure.
#
# And every session is logged to CloudTrail with the IAM principal
# who opened it. You cannot get that from SSH.
# ==================================================================

# The "trust policy": WHO may wear this uniform? An EC2 instance. Nobody else.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ------------------------------------------------------------------
# Shared: access to the SSM transfer bucket.
#
# BOTH NiFi and Kafka need this, because the aws_ssm plugin has the
# TARGET HOST download modules from that bucket.
#
# Without it, every Ansible task fails with AccessDenied on the curl
# step -- a genuinely confusing error, because the SSM session itself
# connects just fine.
# ------------------------------------------------------------------
data "aws_iam_policy_document" "ssm_transfer_access" {
  statement {
    sid       = "ListTransferBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.ssm_transfer.arn]
  }

  statement {
    sid       = "ReadWriteTransferObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
}

resource "aws_iam_policy" "ssm_transfer_access" {
  name   = "${local.name}-ssm-transfer-access"
  policy = data.aws_iam_policy_document.ssm_transfer_access.json
}

# ==================================================================
# NIFI ROLE
# ==================================================================
resource "aws_iam_role" "nifi" {
  name               = "${local.name}-nifi-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "nifi_s3" {
  # Permission to LIST the bucket. Granted on the BUCKET arn, NO /*
  statement {
    sid       = "ListTheBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.nifi_data.arn]
  }

  # Permission to READ/WRITE the OBJECTS. Granted on arn + "/*"
  statement {
    sid    = "ReadWriteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.nifi_data.arn}/*"]
  }
}

resource "aws_iam_role_policy" "nifi_s3" {
  name   = "${local.name}-nifi-s3-policy"
  role   = aws_iam_role.nifi.id
  policy = data.aws_iam_policy_document.nifi_s3.json
}

# ⭐ THE key attachment. Without AmazonSSMManagedInstanceCore, the
# agent cannot register and you have NO WAY IN AT ALL. There is no
# SSH fallback. This is MANDATORY, not optional.
resource "aws_iam_role_policy_attachment" "nifi_ssm_core" {
  role       = aws_iam_role.nifi.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "nifi_ssm_transfer" {
  role       = aws_iam_role.nifi.name
  policy_arn = aws_iam_policy.ssm_transfer_access.arn
}

# An "instance profile" is the wrapper that lets an EC2 instance
# actually WEAR a role. Roles can't attach to EC2 directly -- they
# need this container. A quirk of IAM. Everyone forgets it once.
resource "aws_iam_instance_profile" "nifi" {
  name = "${local.name}-nifi-profile"
  role = aws_iam_role.nifi.name
}

# ==================================================================
# KAFKA ROLE (no S3 data access needed; just SSM)
# ==================================================================
resource "aws_iam_role" "kafka" {
  name               = "${local.name}-kafka-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "kafka_ssm_core" {
  role       = aws_iam_role.kafka.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "kafka_ssm_transfer" {
  role       = aws_iam_role.kafka.name
  policy_arn = aws_iam_policy.ssm_transfer_access.arn
}

resource "aws_iam_instance_profile" "kafka" {
  name = "${local.name}-kafka-profile"
  role = aws_iam_role.kafka.name
}
```

> ### 🔍 The `/*` trap that catches everyone
>
> Look at the two `nifi_s3` statements:
>
> | Action | Resource ARN | Why |
> |---|---|---|
> | `s3:ListBucket` | `arn:aws:s3:::my-bucket` | Acts on the **bucket** |
> | `s3:GetObject` | `arn:aws:s3:::my-bucket/*` | Acts on the **objects inside** |
>
> These are **different resources** in IAM's eyes. A bucket and its contents are not the same thing. Put `ListBucket` on the `/*` ARN and listing fails with AccessDenied — and you'll stare at it for 20 minutes. **Two statements. Always.**

### 6.9 `compute.tf` — note what's absent

```hcl
# compute.tf
# ==================================================================
# NOTE WHAT IS ABSENT FROM BOTH INSTANCES BELOW:
#
#     key_name = "..."          <-- GONE. No key pair. None exists.
#
# There is no SSH key associated with these hosts. Even if someone
# somehow opened port 22, there would be no authorized_keys entry to
# authenticate against. Access is exclusively via SSM.
# ==================================================================

# Look up the CURRENT Ubuntu 24.04 AMI rather than hardcoding an ID.
# AMI IDs are region-specific AND change every time Canonical
# publishes a patched image. Hardcode one and you'll deploy a stale,
# unpatched OS six months from now.
#
# BONUS: Ubuntu's official AWS AMIs ship amazon-ssm-agent preinstalled
# and enabled. So SSM works out of the box. (Amazon Linux 2023 too.
# Debian and most others do NOT -- you'd have to install it yourself.)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Keep user_data TINY. Debugging it is painful -- you have to dig
# through /var/log/cloud-init-output.log, and in an SSM-only world
# you need SSM WORKING before you can even read that file.
#
# Its ONLY job: make absolutely certain the SSM agent is alive.
# If it isn't, you have no way into this box. Ever.
locals {
  ssm_bootstrap = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Ubuntu ships amazon-ssm-agent as a snap. Make sure it's running.
    snap start amazon-ssm-agent || true
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    # Belt and braces: if the snap is somehow missing, install it.
    if ! systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service; then
      snap install amazon-ssm-agent --classic || true
      snap start amazon-ssm-agent || true
    fi

    # Ansible's aws_ssm plugin needs Python 3 on the target.
    apt-get update
    apt-get install -y python3 python3-pip unzip curl

    echo "ssm-ready" > /tmp/bootstrap-done
  EOF
}

# ============================================================
# NIFI
# ============================================================
resource "aws_instance" "nifi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.nifi_instance_type
  subnet_id              = aws_subnet.private[0].id   # PRIVATE. No public IP. Ever.
  vpc_security_group_ids = [aws_security_group.nifi.id]
  iam_instance_profile   = aws_iam_instance_profile.nifi.name

  # key_name is DELIBERATELY OMITTED. SSM only.

  root_block_device {
    volume_size           = var.nifi_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Force IMDSv2. Blocks the SSRF class of attack that steals role
  # credentials -- the vector in the 2019 Capital One breach.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # <-- the important line
    http_put_response_hop_limit = 1
  }

  user_data = local.ssm_bootstrap

  tags = {
    Name = "${local.name}-nifi"
    Role = "nifi"     # <-- Ansible's dynamic inventory finds hosts by this tag
  }
}

# ============================================================
# KAFKA
# ============================================================
resource "aws_instance" "kafka" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.kafka_instance_type
  subnet_id              = aws_subnet.private[0].id   # same subnet as NiFi -> lowest latency
  vpc_security_group_ids = [aws_security_group.kafka.id]
  iam_instance_profile   = aws_iam_instance_profile.kafka.name

  # key_name is DELIBERATELY OMITTED. SSM only.

  root_block_device {
    volume_size           = var.kafka_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = local.ssm_bootstrap

  tags = {
    Name = "${local.name}-kafka"
    Role = "kafka"
  }
}
```

### 6.10 `alb.tf` — the public front door

*(Unaffected by the SSM decision. The ALB is a managed AWS service; it was never SSH-able anyway.)*

```hcl
# alb.tf

# ---------- TLS CERTIFICATE (free, from AWS) ----------
resource "aws_acm_certificate" "nifi" {
  domain_name       = local.nifi_fqdn
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
  tags = { Name = "${local.name}-cert" }
}

# ACM proves you own the domain by asking you to create a specific DNS
# record. Since Terraform manages Route53 too, it does this automatically.
# One of Terraform's genuinely nicest tricks.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.nifi.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks Terraform until AWS confirms the cert is issued. 30s-2min.
resource "aws_acm_certificate_validation" "nifi" {
  certificate_arn         = aws_acm_certificate.nifi.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- THE LOAD BALANCER ----------
resource "aws_lb" "nifi" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false                     # false = internet-facing
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id   # <-- the two AZs. Required.

  enable_deletion_protection = false   # set TRUE in production!
  drop_invalid_header_fields = true    # security hardening
  idle_timeout               = 300     # NiFi's UI holds long connections

  tags = { Name = "${local.name}-alb" }
}

# ---------- TARGET GROUP: "who is behind the door?" ----------
resource "aws_lb_target_group" "nifi" {
  name        = "${local.name}-nifi-tg"
  port        = 8443
  protocol    = "HTTPS"        # NiFi speaks HTTPS internally
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/nifi-api/system-diagnostics"
    protocol            = "HTTPS"
    matcher             = "200,401"   # ⭐ 401 = "NiFi is UP but wants auth". That IS healthy!
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  # NiFi's UI is stateful -- pin a user to one node.
  stickiness {
    enabled         = true
    type            = "lb_cookie"
    cookie_duration = 86400
  }

  tags = { Name = "${local.name}-nifi-tg" }
}

resource "aws_lb_target_group_attachment" "nifi" {
  target_group_arn = aws_lb_target_group.nifi.arn
  target_id        = aws_instance.nifi.id
  port             = 8443
}

# ---------- LISTENERS ----------

# Port 80: serve nothing, just bounce to HTTPS
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.nifi.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Port 443: the real one
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.nifi.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"   # TLS 1.2/1.3 only
  certificate_arn   = aws_acm_certificate_validation.nifi.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nifi.arn
  }
}

# ---------- DNS ----------
# An ALIAS record (not a CNAME). ALIAS is AWS-specific, free to query,
# and unlike a CNAME it can live at the zone apex. Always prefer ALIAS
# when pointing at an AWS resource.
resource "aws_route53_record" "nifi" {
  zone_id = var.route53_zone_id
  name    = local.nifi_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.nifi.dns_name
    zone_id                = aws_lb.nifi.zone_id
    evaluate_target_health = true
  }
}
```

> **On the ALB↔NiFi certificate:** NiFi generates a *self-signed* cert on first boot. The ALB speaks HTTPS to it. That's fine — **an ALB does not validate backend certificates.** It encrypts the hop and moves on. The cert your *browser* sees is the ACM one on the ALB, which is properly trusted. Two certs, two jobs.

### 6.11 `outputs.tf`

```hcl
# outputs.tf

output "nifi_url" {
  value = "https://${local.nifi_fqdn}"
}

output "nifi_instance_id" {
  description = "For: aws ssm start-session --target <this>"
  value       = aws_instance.nifi.id
}

output "kafka_instance_id" {
  description = "For: aws ssm start-session --target <this>"
  value       = aws_instance.kafka.id
}

output "nifi_private_ip" {
  value = aws_instance.nifi.private_ip
}

output "kafka_private_ip" {
  value = aws_instance.kafka.private_ip
}

output "kafka_bootstrap_server" {
  value = "${aws_instance.kafka.private_ip}:9092"
}

output "s3_bucket_name" {
  description = "Drop your .txt files here"
  value       = aws_s3_bucket.nifi_data.id
}

output "ssm_transfer_bucket" {
  description = "REQUIRED by Ansible's aws_ssm plugin. Export this."
  value       = aws_s3_bucket.ssm_transfer.id
}

output "nifi_trigger_endpoint" {
  value = "http://${aws_instance.nifi.private_ip}:${var.nifi_http_listener_port}/trigger"
}

output "ssm_session_commands" {
  description = "How to get a shell -- no SSH, no keys, no open ports"
  value = {
    nifi  = "aws ssm start-session --target ${aws_instance.nifi.id}"
    kafka = "aws ssm start-session --target ${aws_instance.kafka.id}"
  }
}
```

### 6.12 `terraform.tfvars` — your values

**The only file with your real data. It is git-ignored.**

```hcl
# terraform.tfvars

aws_region   = "us-east-1"
project_name = "nifi-platform"
environment  = "dev"
owner        = "your-name"

# --- from Part One, Step 14 ---
command_node_sg_id    = "sg-0REPLACE_ME"
command_node_vpc_id   = "vpc-0REPLACE_ME"
command_node_vpc_cidr = "172.31.0.0/16"

# --- your domain ---
domain_name     = "example.com"
nifi_subdomain  = "nifi"
route53_zone_id = "Z0REPLACE_ME"

# --- from `curl https://checkip.amazonaws.com` on your LAPTOP ---
my_ip_cidr = "203.0.113.45/32"

# ==================================================================
# NOTE: There is NO ssh_key_name setting.
# There is no key pair in this build. Nothing to configure.
# ==================================================================
```

Need your Route53 Zone ID?

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[].{Name:Name,Id:Id}" --output table
```

*(Bought your domain at GoDaddy or Namecheap? Create a Route53 Hosted Zone for it, then update the nameservers at your registrar to the four AWS ones Route53 gives you. Propagation: 15 minutes to a few hours.)*

### 6.13 Run it

Point the backend at your bucket:

```bash
cd ~/infra/terraform
BUCKET=$(cat ~/tf-bucket-name.txt)
sed -i "s/REPLACE_WITH_YOUR_BUCKET/$BUCKET/" versions.tf
grep bucket versions.tf   # verify
```

Now the four commands. **Always in this order.**

```bash
# 1. INIT -- downloads the AWS provider, connects to the S3 backend.
terraform init
```

```bash
# 2. VALIDATE -- checks syntax. Free, instant, catches typos.
terraform fmt -recursive
terraform validate
```

```bash
# 3. PLAN -- ⭐ THE MOST IMPORTANT COMMAND IN TERRAFORM ⭐
#    Shows exactly what will change. Changes NOTHING.
#    READ THE OUTPUT. Every time. No exceptions.
terraform plan -out=tfplan
```

Terraform prints a diff:

- `+` green = **created**
- `~` yellow = **modified in place**
- `-/+` = **destroyed and recreated** ⚠️ ***this is where data loss lives — read carefully***
- `-` red = **destroyed** 🚨

It should end with something like:

```
Plan: 61 to add, 0 to change, 0 to destroy.
```

> 🚨 **The single best habit you can build:** never run `apply` without reading the `plan`. A `-/+` on a volume or a database means your data is about to be deleted. **`plan` is your seatbelt. Wear it.**

```bash
# 4. APPLY -- because we saved the plan, it applies EXACTLY what you
#    just reviewed. No surprises.
terraform apply tfplan
```

Go make coffee. **8–12 minutes**, almost entirely spent waiting on:
- The **NAT Gateway** (~2 min)
- The **Load Balancer** (~4 min — ALBs are genuinely slow)
- The **three SSM interface endpoints** (~2 min)

When it finishes:

```
Apply complete! Resources: 61 added, 0 changed, 0 destroyed.

Outputs:

kafka_bootstrap_server = "10.20.11.88:9092"
kafka_instance_id = "i-0kafka123"
nifi_instance_id = "i-0nifi456"
nifi_url = "https://nifi.example.com"
s3_bucket_name = "nifi-platform-dev-drop-a3f9c2e1"
ssm_transfer_bucket = "nifi-platform-dev-ssm-transfer-a3f9c2e1"
```

**You just built a 61-resource production-shaped AWS environment from a text file — with zero SSH ports.**

```bash
terraform output > ~/infra-outputs.txt
cd ~/infra && git add . && git commit -m "Full NiFi/Kafka platform, SSM-only"
```

### 6.14 ⭐ Wait for the SSM agents — this gate is mandatory

**Do not proceed until both instances are `Online`.** Ansible cannot connect otherwise, and there is no SSH fallback.

```bash
watch -n 5 'aws ssm describe-instance-information \
  --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,Agent:AgentVersion}" \
  --output table'
```

Wait for:

```
--------------------------------------------------------
|            DescribeInstanceInformation               |
+---------------------+---------+----------------------+
|         ID          |  Ping   |       Agent          |
+---------------------+---------+----------------------+
|  i-0cmdnode000000   | Online  |  3.3.1611.0          |
|  i-0nifi456         | Online  |  3.3.1611.0          |
|  i-0kafka123        | Online  |  3.3.1611.0          |
+---------------------+---------+----------------------+
```

**Three instances. All Online.** Ctrl+C to exit `watch`.

Takes ~90 seconds after `apply` finishes. Be patient before you panic.

> **Only seeing the Command Node after 3+ minutes?** Work through this, in order — it's usually #1:
>
> ```bash
> # 1. DO ALL THREE ENDPOINTS EXIST?  <-- usually the problem
> aws ec2 describe-vpc-endpoints \
>   --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id 2>/dev/null)" \
>   --query 'VpcEndpoints[].ServiceName' --output text
> # You MUST see ssm, ssmmessages, AND ec2messages.
> # Missing ec2messages is THE most common cause. It sounds optional. It isn't.
>
> # 2. Is private DNS on?
> aws ec2 describe-vpc-endpoints \
>   --query 'VpcEndpoints[].{Svc:ServiceName,DNS:PrivateDnsEnabled}' --output table
> # All three must be true.
>
> # 3. Does the instance role have AmazonSSMManagedInstanceCore?
> aws iam list-attached-role-policies --role-name nifi-platform-dev-nifi-role
>
> # 4. Does the instance SG allow OUTBOUND 443?
> # The agent connects OUT. No egress = no agent = no access.
> ```

### 6.15 Prove the security model — don't take my word for it

```bash
cd ~/infra/terraform

# ---- TEST 1: Are there ANY port-22 rules? (must be ZERO) ----
aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=nifi-platform" \
  --query 'SecurityGroups[].IpPermissions[?FromPort==`22`]' \
  --output text
# Expected: EMPTY. Not one SSH rule exists in this entire project.
```

```bash
# ---- TEST 2: Is any key pair attached? (must be NONE) ----
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=nifi-platform" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].KeyName' --output text
# Expected: None / empty.
# Even if port 22 were open, there'd be no key to authenticate with.
```

```bash
# ---- TEST 3: Does NiFi have a public IP? (must be NONE) ----
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=nifi" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text
# Expected: empty.
# NO PUBLIC IP = UNREACHABLE. Not "firewalled off." Genuinely unroutable.
```

```bash
# ---- TEST 4: Kafka's ingress list on 9092 ----
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*kafka-sg" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`9092`].UserIdGroupPairs[].GroupId' \
  --output text
# Expected: EXACTLY TWO security group IDs -- NiFi's and the Command Node's.

# And confirm there are NO CIDR blocks:
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*kafka-sg" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`9092`].IpRanges[].CidrIp' \
  --output text
# Expected: EMPTY. Badges only. No IP ranges.
```

That last pair is **the proof of the requirement.** Two badges. Zero CIDRs. Nothing else on Earth can reach port 9092.

```bash
# ---- TEST 5: And yet... you can still get a shell. ----
aws ssm start-session --target $(terraform output -raw kafka_instance_id)
```

You're on a machine with **no public IP**, **no key pair**, and **no inbound rules except 9092 from two specific security groups** — and you have a root shell.

That is the entire thesis of this build, demonstrated.
---

## 7. PART THREE — Ansible Configures the Servers (Over SSM)

Terraform built two empty Ubuntu boxes. No Java, no NiFi, no Kafka. Ansible fixes that — **without SSH**.

### 7.1 How Ansible works without SSH

This is the part that surprises people, so let's understand it before configuring anything.

**Ansible's normal model:**

```
Controller                                    Target
    |                                            |
    |---- SSH connect (port 22) ---------------->|
    |---- SFTP the Python module over ---------->|
    |---- run it -------------------------------->|
    |<--- stdout comes back over SSH ------------|
```

Everything rides one SSH connection.

**The `aws_ssm` model:**

```
Controller                 AWS SSM                Target
    |                         |                      |
    |                         |<-- agent polls OUT --|  (already connected)
    |                         |                      |
    |-- 1. PUT module ------------> S3 BUCKET        |
    |                         |                      |
    |-- 2. StartSession ----->|                      |
    |    "curl this presigned URL and run it"        |
    |                         |--------------------->|
    |                         |                      |
    |                         |    3. host downloads |
    |                         |       FROM S3 <------|
    |                         |                      |
    |<-- 4. stdout back over the SSM channel --------|
```

### 🔑 Why the S3 bucket exists

**SSM carries a command stream. It has no file channel.**

Ansible fundamentally works by *copying a Python program to the target and running it*. Over SSH, SFTP does that. Over SSM, there's no equivalent — you can send *commands*, but you can't send *files*.

So the plugin routes around it: **upload the module to S3, then tell the host to `curl` it down.**

That is why:
- Terraform created an `ssm_transfer` bucket
- **Both instance roles** need `s3:GetObject` on it (the *target* downloads, not just the controller)
- You must `export ANSIBLE_AWS_SSM_BUCKET=...`

Forget that export and **every task fails**, with an error that never mentions S3.

**It's also why SSM-Ansible is slower than SSH-Ansible.** Every module round-trips through S3. That's the honest cost. We claw some back with parallelism.

### 7.2 `ansible.cfg`

```bash
cd ~/infra/ansible
```

```ini
[defaults]
inventory           = inventory.aws_ec2.yml
host_key_checking   = False
interpreter_python  = /usr/bin/python3
stdout_callback     = yaml
timeout             = 120
retry_files_enabled = False

# SSM is slower per-task than SSH (every module round-trips through S3).
# Bump forks so hosts run in parallel and claw some of it back.
forks = 10

[inventory]
enable_plugins = aws_ec2

[connection]
pipelining = False
```

> ### 🚨 `pipelining = False` — and do not "helpfully" turn it on
>
> Pipelining is an **SSH-specific** optimization. It pipes the module over the existing SSH connection instead of writing a temp file.
>
> **The SSM plugin has no SSH connection to pipe over.** Enabling pipelining with `aws_ssm` produces confusing failures.
>
> If you've used Ansible before, `pipelining = True` is muscle memory — it's normally free performance. **Not here.** The SSM equivalent optimization is the S3 bucket, which we already use. Nothing further to tune.
>
> Notice also what's **absent** from this config: no `ssh_args`, no `ForwardAgent`, no `remote_user`, no `ControlMaster`. None of it is meaningful anymore.

### 7.3 Dynamic inventory — **hostnames must be instance IDs**

This is the single most important line in the Ansible setup.

**`inventory.aws_ec2.yml`:**

```yaml
---
# ==================================================================
# THE CRITICAL DIFFERENCE FROM AN SSH SETUP:
#
#   SSH inventory  -> hostnames are IP ADDRESSES   (10.20.11.42)
#   SSM inventory  -> hostnames are INSTANCE IDS   (i-0abc123def456)
#
# SSM does not connect to an IP. It calls the AWS API with an
# INSTANCE ID, and AWS routes the session to the agent on that box.
# There is no network path involved from your side at all.
#
# Leave `hostnames: private-ip-address` here (the SSH default) and
# the plugin will try StartSession against "10.20.11.42" and fail with:
#
#     "An error occurred (TargetNotConnected) ... is not connected"
#
# ...which is a MADDENING error, because it's a HOSTNAME problem
# wearing a NETWORK problem's clothes. You'll go check firewalls for
# an hour. Don't. Check this line.
# ==================================================================

plugin: aws_ec2
regions:
  - us-east-1

filters:
  instance-state-name: running
  tag:Project: nifi-platform

# Auto-create groups from the Role tag.
# An instance tagged Role=nifi lands in group "role_nifi".
keyed_groups:
  - key: tags.Role
    prefix: role
    separator: "_"

# >>> THE LINE THAT MAKES SSM WORK <<<
hostnames:
  - instance-id

compose:
  ansible_host: instance_id

  # Keep the real private IP available as a normal variable -- the
  # playbooks still NEED it (Kafka's advertised.listeners, NiFi's
  # bootstrap address). We just don't CONNECT to it.
  private_ip: private_ip_address
```

### 7.4 `group_vars/all.yml` — the SSM connection settings

```bash
mkdir -p group_vars
```

```yaml
---
# group_vars/all.yml

# ⭐ Use the SSM connection plugin. Not SSH. Not paramiko. SSM.
ansible_connection: community.aws.aws_ssm

ansible_aws_ssm_region: us-east-1

# The S3 bucket Ansible uses to hand modules to the target host.
# Read from the environment so the repo stays generic:
#
#   export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=../terraform \
#     output -raw ssm_transfer_bucket)
#
ansible_aws_ssm_bucket_name: "{{ lookup('env', 'ANSIBLE_AWS_SSM_BUCKET') }}"

# Path to the session-manager-plugin binary ON THE CONTROLLER
# (i.e. on the Command Node). You installed this in Part One, Step 9.
ansible_aws_ssm_plugin: /usr/local/sessionmanagerplugin/bin/session-manager-plugin

# SSM sessions take a few seconds to establish. Be patient.
ansible_aws_ssm_timeout: 120

# The SSM agent runs as root, so we land as root already. become is
# set anyway, for clarity and for tasks that drop privileges.
ansible_become: true
ansible_become_method: sudo

# ---------- shared app config ----------
kafka_topic: nifi-s3-files
```

### 7.5 Set the bucket and test the connection

```bash
export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=~/infra/terraform \
  output -raw ssm_transfer_bucket)

echo "Bucket: $ANSIBLE_AWS_SSM_BUCKET"
```

> **Put that export in your `~/.bashrc`.** You will forget it otherwise, and the resulting error is unhelpful.

Check the inventory:

```bash
ansible-inventory --graph
```

```
@all:
  |--@aws_ec2:
  |  |--i-0nifi456
  |  |--i-0kafka123
  |--@role_kafka:
  |  |--i-0kafka123
  |--@role_nifi:
  |  |--i-0nifi456
```

**Instance IDs, not IPs.** That's what you want to see. If you see IPs, fix `hostnames:` in the inventory.

Now the moment of truth:

```bash
ansible all -m ping
```

```
i-0nifi456 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
i-0kafka123 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

🎉 **Ansible just reached two servers that have no SSH, no key pair, no public IP, and no inbound firewall rules.**

*(Ansible's "ping" isn't ICMP — it's a Python round-trip. So a `pong` proves the entire chain works: SSM session established, module uploaded to S3, host downloaded and executed it, output came back.)*

### 7.6 When `ping` fails — the three causes

**1. `ANSIBLE_AWS_SSM_BUCKET` is not set.** The error won't say so. Check:
```bash
echo $ANSIBLE_AWS_SSM_BUCKET   # empty? that's your problem
```

**2. `session-manager-plugin` isn't installed on the Command Node.**
```bash
/usr/local/sessionmanagerplugin/bin/session-manager-plugin --version
```
Ansible shells out to this binary. No binary, no connection. (Part One, Step 9.)

**3. `community.aws` isn't installed.**
```bash
ansible-galaxy collection list community.aws
```
Without it there is no `aws_ssm` plugin at all.

**4. `TargetNotConnected`** — either the instance isn't `Online` in SSM (§6.14), or your inventory is using IPs instead of instance IDs.

### 7.7 The Kafka role

```bash
mkdir -p roles/kafka/{tasks,templates,handlers,defaults}
```

**`roles/kafka/defaults/main.yml`:**

```yaml
---
kafka_version: "3.9.0"
kafka_scala_version: "2.13"
kafka_install_dir: /opt/kafka
kafka_data_dir: /var/lib/kafka
kafka_user: kafka
kafka_heap: "-Xmx2G -Xms2G"
kafka_topic: "nifi-s3-files"
kafka_partitions: 3
```

**`roles/kafka/tasks/main.yml`:**

```yaml
---
# Kafka 3.9 in KRaft mode. NO ZOOKEEPER.
# ZooKeeper has been optional since Kafka 3.3 and was REMOVED
# entirely in Kafka 4.0. Any tutorial telling you to install it is
# out of date. Do not install it.

- name: Install Java 21 (Kafka needs a JVM)
  ansible.builtin.apt:
    name: openjdk-21-jre-headless
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Create the kafka system user
  ansible.builtin.user:
    name: "{{ kafka_user }}"
    system: true
    shell: /usr/sbin/nologin      # cannot be logged into. Good.
    home: "{{ kafka_install_dir }}"
    create_home: false

- name: Create directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ kafka_user }}"
    group: "{{ kafka_user }}"
    mode: "0755"
  loop:
    - "{{ kafka_install_dir }}"
    - "{{ kafka_data_dir }}"

- name: Download Kafka
  ansible.builtin.get_url:
    url: >-
      https://downloads.apache.org/kafka/{{ kafka_version }}/kafka_{{ kafka_scala_version }}-{{ kafka_version }}.tgz
    dest: /tmp/kafka.tgz
    mode: "0644"
    timeout: 180
  register: kafka_download
  retries: 3
  delay: 10
  until: kafka_download is succeeded

- name: Unpack Kafka
  ansible.builtin.unarchive:
    src: /tmp/kafka.tgz
    dest: "{{ kafka_install_dir }}"
    remote_src: true
    extra_opts: [--strip-components=1]    # drop the top-level folder
    owner: "{{ kafka_user }}"
    group: "{{ kafka_user }}"
    creates: "{{ kafka_install_dir }}/bin/kafka-server-start.sh"   # <-- IDEMPOTENCY

- name: Write the KRaft server config
  ansible.builtin.template:
    src: server.properties.j2
    dest: "{{ kafka_install_dir }}/config/kraft/server.properties"
    owner: "{{ kafka_user }}"
    mode: "0644"
  notify: restart kafka

- name: Check whether storage is already formatted
  ansible.builtin.stat:
    path: "{{ kafka_data_dir }}/meta.properties"
  register: kafka_meta

- name: Generate a cluster UUID (once, and only once)
  ansible.builtin.command: "{{ kafka_install_dir }}/bin/kafka-storage.sh random-uuid"
  register: cluster_uuid
  changed_when: false
  when: not kafka_meta.stat.exists

- name: Format the storage directory
  ansible.builtin.command: >-
    {{ kafka_install_dir }}/bin/kafka-storage.sh format
    -t {{ cluster_uuid.stdout }}
    -c {{ kafka_install_dir }}/config/kraft/server.properties
  become_user: "{{ kafka_user }}"
  when: not kafka_meta.stat.exists
  changed_when: true

- name: Install the systemd unit
  ansible.builtin.template:
    src: kafka.service.j2
    dest: /etc/systemd/system/kafka.service
    mode: "0644"
  notify:
    - reload systemd
    - restart kafka

- name: Start and enable Kafka
  ansible.builtin.systemd:
    name: kafka
    state: started
    enabled: true
    daemon_reload: true

- name: Wait for Kafka to actually listen on 9092
  ansible.builtin.wait_for:
    port: 9092
    host: "{{ ansible_default_ipv4.address }}"
    timeout: 120

- name: Create the topic
  ansible.builtin.command: >-
    {{ kafka_install_dir }}/bin/kafka-topics.sh
    --bootstrap-server {{ ansible_default_ipv4.address }}:9092
    --create --if-not-exists
    --topic {{ kafka_topic }}
    --partitions {{ kafka_partitions }}
    --replication-factor 1
  become_user: "{{ kafka_user }}"
  register: topic_result
  changed_when: "'Created topic' in topic_result.stdout"
```

**`roles/kafka/templates/server.properties.j2`:**

```jinja
# KRaft mode: this ONE node is both broker and controller.
# In production you'd separate these and run 3+ controllers.
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@{{ ansible_default_ipv4.address }}:9093

# ============================================================
# 🚨 THE #1 KAFKA GOTCHA, EXPLAINED
#
# listeners            = "what socket do I BIND to?"
# advertised.listeners = "what address do I TELL CLIENTS to use?"
#
# Kafka's protocol works like this: a client connects to the
# bootstrap server and asks "who are the brokers?" Kafka replies
# with the ADVERTISED address. The client then DISCONNECTS and
# RECONNECTS to that advertised address.
#
# If advertised.listeners says "localhost", the client will try to
# connect to ITS OWN localhost, find nothing, and hang FOREVER.
#
# This is the single most confusing failure in all of Kafka. It
# connects fine, then times out with no useful error whatsoever.
#
# ALWAYS advertise an address the client can actually reach.
# ============================================================
listeners=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
advertised.listeners=PLAINTEXT://{{ ansible_default_ipv4.address }}:9092
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
inter.broker.listener.name=PLAINTEXT

log.dirs={{ kafka_data_dir }}

num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

# Single node = replication factor MUST be 1. You cannot replicate
# to yourself. Set these to 3 on one broker and EVERY topic
# creation fails.
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
default.replication.factor=1
min.insync.replicas=1

num.partitions={{ kafka_partitions }}
auto.create.topics.enable=true

# Keep messages 7 days
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
```

> ⚠️ **PLAINTEXT means unencrypted.** Acceptable here *only* because Kafka sits in a private subnet, its SG admits exactly two source SGs on 9092, and **there is no SSH daemon on the box to pivot from**. For real data, configure **SASL_SSL** with SCRAM and ACLs. A security group is a strong outer wall; it is not a substitute for authentication on the wire.

**`roles/kafka/templates/kafka.service.j2`:**

```jinja
[Unit]
Description=Apache Kafka (KRaft mode, no ZooKeeper)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{ kafka_user }}
Group={{ kafka_user }}
Environment="KAFKA_HEAP_OPTS={{ kafka_heap }}"
ExecStart={{ kafka_install_dir }}/bin/kafka-server-start.sh {{ kafka_install_dir }}/config/kraft/server.properties
ExecStop={{ kafka_install_dir }}/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```

**`roles/kafka/handlers/main.yml`:**

```yaml
---
# Handlers only fire if a task NOTIFIED them AND that task changed
# something. Ten tasks can notify "restart kafka" -- it restarts ONCE,
# at the end. That's why you don't get ten restarts in a row.
- name: reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: restart kafka
  ansible.builtin.systemd:
    name: kafka
    state: restarted
```

### 7.8 The NiFi role

```bash
mkdir -p roles/nifi/{tasks,templates,handlers,defaults}
```

**`roles/nifi/defaults/main.yml`:**

```yaml
---
nifi_version: "2.0.0"
nifi_install_dir: /opt/nifi
nifi_user: nifi
nifi_web_port: 8443
nifi_http_listener_port: 9999
nifi_heap: "4g"
nifi_admin_user: "admin"

# CHANGE THIS. NiFi refuses to start if it's under 12 characters.
# Better still: use ansible-vault, or pass -e nifi_admin_password=...
nifi_admin_password: "ChangeMe-LongPassword-123!"

nifi_fqdn: "nifi.example.com"    # overridden by site.yml
```

**`roles/nifi/tasks/main.yml`** (the essential tasks):

```yaml
---
- name: Install Java 21
  ansible.builtin.apt:
    name: openjdk-21-jdk
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Create the nifi user
  ansible.builtin.user:
    name: "{{ nifi_user }}"
    system: true
    shell: /bin/bash
    home: "{{ nifi_install_dir }}"
    create_home: false

- name: Create install dir
  ansible.builtin.file:
    path: "{{ nifi_install_dir }}"
    state: directory
    owner: "{{ nifi_user }}"
    group: "{{ nifi_user }}"
    mode: "0755"

- name: Download NiFi (~1.5GB -- be patient)
  ansible.builtin.get_url:
    url: "https://downloads.apache.org/nifi/{{ nifi_version }}/nifi-{{ nifi_version }}-bin.zip"
    dest: /tmp/nifi.zip
    mode: "0644"
    timeout: 900
  register: nifi_dl
  retries: 3
  delay: 15
  until: nifi_dl is succeeded

# `unarchive` cannot --strip-components a ZIP (that's tar-only), and
# NiFi's zip has a top-level nifi-<version>/ folder. So extract and
# flatten by hand, guarded by `creates:` to stay idempotent.
- name: Extract and flatten NiFi
  ansible.builtin.shell: |
    set -euo pipefail
    rm -rf /tmp/nifi-extract && mkdir -p /tmp/nifi-extract
    unzip -q /tmp/nifi.zip -d /tmp/nifi-extract
    cp -a /tmp/nifi-extract/nifi-{{ nifi_version }}/. {{ nifi_install_dir }}/
    chown -R {{ nifi_user }}:{{ nifi_user }} {{ nifi_install_dir }}
    rm -rf /tmp/nifi-extract
  args:
    creates: "{{ nifi_install_dir }}/bin/nifi.sh"
    executable: /bin/bash

- name: Configure JVM heap
  ansible.builtin.lineinfile:
    path: "{{ nifi_install_dir }}/conf/bootstrap.conf"
    regexp: '^java\.arg\.{{ item.n }}='
    line: "java.arg.{{ item.n }}=-{{ item.flag }}{{ nifi_heap }}"
  loop:
    - { n: 2, flag: "Xms" }
    - { n: 3, flag: "Xmx" }
  notify: restart nifi

# ============================================================
# ⭐⭐⭐ THE PROXY HEADER GOTCHA ⭐⭐⭐
#
# NiFi checks the HTTP Host header on EVERY request. Behind an ALB
# that header is "nifi.example.com" -- which NiFi has never heard of.
# So it rejects every request with:
#
#     "System Error: The request contained an invalid host header"
#
# nifi.web.proxy.host is the WHITELIST of hostnames NiFi will accept.
# You MUST include your ALB domain.
#
# This trips up LITERALLY EVERYONE who puts NiFi behind a load
# balancer. If your NiFi page is blank, it is this. It's always this.
# ============================================================
- name: Set nifi.web.proxy.host (THE line that makes the ALB work)
  ansible.builtin.lineinfile:
    path: "{{ nifi_install_dir }}/conf/nifi.properties"
    regexp: '^nifi\.web\.proxy\.host='
    line: >-
      nifi.web.proxy.host={{ nifi_fqdn }}:443,{{ nifi_fqdn }},{{ ansible_default_ipv4.address }}:{{ nifi_web_port }},localhost:{{ nifi_web_port }}
  notify: restart nifi

- name: Bind the web UI to all interfaces
  ansible.builtin.lineinfile:
    path: "{{ nifi_install_dir }}/conf/nifi.properties"
    regexp: '^nifi\.web\.https\.host='
    line: "nifi.web.https.host=0.0.0.0"
  notify: restart nifi

- name: Set the HTTPS port
  ansible.builtin.lineinfile:
    path: "{{ nifi_install_dir }}/conf/nifi.properties"
    regexp: '^nifi\.web\.https\.port='
    line: "nifi.web.https.port={{ nifi_web_port }}"
  notify: restart nifi

- name: Set the single-user credentials
  ansible.builtin.command: >-
    {{ nifi_install_dir }}/bin/nifi.sh set-single-user-credentials
    {{ nifi_admin_user }} {{ nifi_admin_password }}
  become_user: "{{ nifi_user }}"
  args:
    creates: "{{ nifi_install_dir }}/conf/login-identity-providers.xml"
  notify: restart nifi
  no_log: true      # don't print the password to the console

- name: Install the systemd unit
  ansible.builtin.template:
    src: nifi.service.j2
    dest: /etc/systemd/system/nifi.service
    mode: "0644"
  notify:
    - reload systemd
    - restart nifi

- name: Start and enable NiFi
  ansible.builtin.systemd:
    name: nifi
    state: started
    enabled: true
    daemon_reload: true

# NiFi is SLOW to boot. 2-4 minutes is completely normal -- it's
# unpacking hundreds of NAR bundles. Do not panic. Do not restart it;
# you'll just start the clock over.
- name: Wait for NiFi (this genuinely takes several minutes)
  ansible.builtin.wait_for:
    port: "{{ nifi_web_port }}"
    host: "{{ ansible_default_ipv4.address }}"
    timeout: 420
    delay: 30
```

**`roles/nifi/templates/nifi.service.j2`:**

```jinja
[Unit]
Description=Apache NiFi
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User={{ nifi_user }}
Group={{ nifi_user }}
ExecStart={{ nifi_install_dir }}/bin/nifi.sh start
ExecStop={{ nifi_install_dir }}/bin/nifi.sh stop
Restart=on-failure
RestartSec=30
# NiFi is SLOW to boot. Do not lower this.
TimeoutStartSec=600
LimitNOFILE=50000
LimitNPROC=10000

[Install]
WantedBy=multi-user.target
```

**`roles/nifi/handlers/main.yml`:**

```yaml
---
- name: reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: restart nifi
  ansible.builtin.systemd:
    name: nifi
    state: restarted
```

### 7.9 `site.yml` — with an SSM preflight check

In an SSH world, a broken connection gives you `UNREACHABLE` and you know it's your key or your port. **Over SSM the failure modes are different and the errors are worse.** So we check the two things that actually break, up front, with a clear message.

```yaml
---
# ------------------------------------------------------------------
# PLAY 0: PREFLIGHT -- catch the two SSM-specific footguns early
# ------------------------------------------------------------------
- name: Preflight -- verify the SSM path works
  hosts: localhost
  connection: local
  gather_facts: false
  become: false

  tasks:
    - name: Fail early if the SSM transfer bucket isn't set
      ansible.builtin.assert:
        that:
          - ansible_aws_ssm_bucket_name is defined
          - ansible_aws_ssm_bucket_name | length > 0
        fail_msg: |

          ANSIBLE_AWS_SSM_BUCKET is not set.

          The aws_ssm connection plugin CANNOT work without an S3
          bucket -- it's how modules get onto the target host.
          SSM has no file channel.

          Fix:
            export ANSIBLE_AWS_SSM_BUCKET=$(terraform \
              -chdir=../terraform output -raw ssm_transfer_bucket)

        success_msg: "SSM transfer bucket: {{ ansible_aws_ssm_bucket_name }}"

    - name: Check session-manager-plugin is installed on this controller
      ansible.builtin.stat:
        path: "{{ ansible_aws_ssm_plugin }}"
      register: smp

    - name: Fail if session-manager-plugin is missing
      ansible.builtin.assert:
        that: smp.stat.exists
        fail_msg: |

          session-manager-plugin is not installed at:
            {{ ansible_aws_ssm_plugin }}

          Ansible's aws_ssm plugin SHELLS OUT to this binary. Without
          it, every connection fails.

          Fix: see Part One, Step 9.

# ------------------------------------------------------------------
# PLAY 1: BASELINE
# ------------------------------------------------------------------
- name: Baseline on every host
  hosts: all
  gather_facts: true

  tasks:
    - name: Confirm we really are connected over SSM (not SSH)
      ansible.builtin.debug:
        msg: >-
          Connected to {{ inventory_hostname }}
          ({{ private_ip | default('?') }})
          via {{ ansible_connection }}
          -- no SSH, no key, no open port.

    - name: Install common tools
      ansible.builtin.apt:
        name:
          - curl
          - wget
          - unzip
          - vim
          - htop
          - net-tools
          - chrony      # clock sync -- Kafka is VERY sensitive to drift
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Enable time sync
      ansible.builtin.systemd:
        name: chrony
        state: started
        enabled: true

# ------------------------------------------------------------------
# PLAY 2: KAFKA FIRST
#
# Order matters. NiFi will try to reach Kafka. If Kafka isn't up yet,
# NiFi's PublishKafka processor sits in a retry loop -- not fatal, but
# it makes the first run look broken when it isn't.
# ------------------------------------------------------------------
- name: Deploy Kafka
  hosts: role_kafka
  gather_facts: true
  roles:
    - kafka

# ------------------------------------------------------------------
# PLAY 3: THEN NIFI
# ------------------------------------------------------------------
- name: Deploy NiFi
  hosts: role_nifi
  gather_facts: true
  vars:
    # Pull Kafka's address straight out of Ansible's fact cache.
    # No hardcoding, no copy-paste, survives a rebuild.
    kafka_bootstrap: >-
      {{ hostvars[groups['role_kafka'][0]]['ansible_default_ipv4']['address'] }}:9092

    nifi_fqdn: "{{ lookup('env', 'NIFI_FQDN') | default('nifi.example.com', true) }}"
  roles:
    - nifi

  post_tasks:
    - name: Connection summary
      ansible.builtin.debug:
        msg:
          - "NiFi UI     : https://{{ nifi_fqdn }}"
          - "NiFi listen : {{ ansible_default_ipv4.address }}:{{ nifi_http_listener_port }}"
          - "Kafka       : {{ kafka_bootstrap }}"
          - ""
          - "Shell on this box (NO SSH):"
          - "  aws ssm start-session --target {{ inventory_hostname }}"
```

### 7.10 Run it

```bash
cd ~/infra/ansible

# Make sure these are set
export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=~/infra/terraform \
  output -raw ssm_transfer_bucket)
export NIFI_FQDN="nifi.yourdomain.com"

# ALWAYS dry-run first. --check changes nothing; --diff shows what
# WOULD change. This is Ansible's `terraform plan`.
ansible-playbook site.yml --check --diff

# Now for real
ansible-playbook site.yml
```

**This takes 15–25 minutes** — a bit longer than the SSH version, because every module round-trips through S3. Most of it is downloading NiFi's 1.5 GB zip and waiting for the JVM to unpack hundreds of NAR bundles on first boot.

> **Session dropping mid-run?** Run it under `tmux`:
> ```bash
> tmux new -s deploy
> ansible-playbook site.yml
> # Ctrl+B then D to detach. Reconnect later with: tmux attach -t deploy
> ```
> This is genuinely useful — an SSM session times out after ~20 minutes of *inactivity*, and a long Ansible run can occasionally trip it.

Success:

```
PLAY RECAP ****************************************************
i-0kafka123  : ok=17  changed=14  unreachable=0  failed=0
i-0nifi456   : ok=22  changed=18  unreachable=0  failed=0
localhost    : ok=3   changed=0   unreachable=0  failed=0
```

**`failed=0` is the only number that matters.**

Now run it **again**:

```bash
ansible-playbook site.yml
```

```
PLAY RECAP ****************************************************
i-0kafka123  : ok=17  changed=0   unreachable=0  failed=0
i-0nifi456   : ok=22  changed=0   unreachable=0  failed=0
```

**`changed=0`. That is idempotency, proven.** Ansible checked every task, saw the desired state already existed, and did nothing. That's exactly what you want — and it's why it's safe to re-run these playbooks any time.

### 7.11 Useful SSM commands you now have for free

```bash
# Shell on any box
aws ssm start-session --target i-0kafka123

# Run one command across the whole fleet -- no Ansible needed
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Project,Values=nifi-platform" \
  --parameters 'commands=["systemctl is-active kafka nifi"]'

# ⭐ PORT FORWARD -- this replaces SSH tunnelling entirely.
# Want NiFi's UI on your laptop, bypassing the ALB?
aws ssm start-session \
  --target i-0nifi456 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
# Now open https://localhost:8443
# No open port. No bastion. No VPN. No key.
```

That last one is worth dwelling on. **You just port-forwarded into a machine with no public IP and no inbound firewall rules** — something that would normally require a bastion host or a VPN.

---

## 8. PART FOUR — The Python App and the Consumer

Now the fun part. We build:
- A **NiFi flow** that listens for an HTTP poke, reads S3, and publishes to Kafka
- A **Python trigger** that sends the poke
- A **Python consumer** that `cat`s the file contents to your screen

### 8.1 Open the NiFi UI

```bash
terraform -chdir=~/infra/terraform output -raw nifi_url
```

Open `https://nifi.yourdomain.com` in your **laptop's** browser. (The ALB security group allows your IP.)

Log in with `admin` and the password from `roles/nifi/defaults/main.yml`.

> **Blank page or "invalid host header"?** That is `nifi.web.proxy.host`. It is always that. See §7.8.

### 8.2 The flow, explained before we build it

```
[HandleHttpRequest] :9999
        |  ("the Python app poked me")
        v
   [ListS3]  ---> emits ONE FlowFile per object in the bucket.
        |         Content is EMPTY. The S3 key lives in the ATTRIBUTES.
        |         It's a POINTER, not the data.
        v
 [FetchS3Object] ---> reads those attributes, downloads the actual bytes
        |             into the FlowFile content.
        v
  [PublishKafka] ---> writes the bytes to topic 'nifi-s3-files'
        |
        v
[HandleHttpResponse] ---> "200 OK" back to the Python app
```

**Why split List and Fetch?** Because listing 10,000 files is cheap, but downloading 10,000 files is expensive. Splitting lets NiFi queue the pointers and fetch at a controlled rate. Same reason `ls` is instant and `cat *` is slow.

### 8.3 Build it

**A) `ListS3`**

Drag a Processor onto the canvas → search `ListS3` → Add. Right-click → **Configure** → **Properties**:

| Property | Value |
|---|---|
| Bucket | *your bucket* (`terraform output -raw s3_bucket_name`) |
| Region | `us-east-1` |
| Prefix | `incoming/` |
| **AWS Credentials Provider Service** | *see below* ⬇️ |

Click the dropdown → **Create new service** → `AWSCredentialsProviderControllerService` → click the ⚙️ gear.

### **Leave every field blank.** Then click ⚡ to **Enable** it.

> ### 🔑 Why blank? This is the payoff of the entire IAM section.
>
> With nothing configured, the AWS SDK falls back to its **default credential provider chain**. On an EC2 instance, the last link in that chain is the **instance metadata service** — which hands back the temporary credentials of the IAM role Terraform attached.
>
> So by configuring **nothing**, NiFi automatically picks up the role. **Zero keys. Zero secrets. Zero configuration.**
>
> If you paste an access key into those fields, you have just created **exactly the vulnerability** this whole build was designed to eliminate. You'd have taken a system with no SSH keys and no credentials on disk — and put a permanent, never-expiring AWS credential into a config file.
>
> **Blank is correct. Blank is secure. Blank is the whole point.**

**Scheduling** tab: Run Schedule `0 sec`, Timer driven.

**B) `FetchS3Object`**

| Property | Value |
|---|---|
| Bucket | `${s3.bucket}` |
| Object Key | `${filename}` |
| Region | `us-east-1` |
| AWS Credentials Provider Service | *the same service* |

The `${...}` is **NiFi Expression Language** — it reads attributes off the incoming FlowFile. `ListS3` set them; `FetchS3Object` uses them.

**C) `PublishKafka`**

| Property | Value |
|---|---|
| Kafka Brokers | `<KAFKA_IP>:9092` |
| Topic Name | `nifi-s3-files` |
| Delivery Guarantee | `Guarantee Replicated Delivery` |
| Use Transactions | `false` |

```bash
terraform -chdir=~/infra/terraform output -raw kafka_bootstrap_server
```

This connection works **only** because NiFi's security group is one of the two badges on Kafka's port 9092.

**D) `HandleHttpRequest`**

| Property | Value |
|---|---|
| Listening Port | `9999` |
| Allowed Paths | `/trigger` |
| HTTP Context Map | *create new* `StandardHttpContextMap` → **enable it** ⚡ |

**E) `HandleHttpResponse`**

| Property | Value |
|---|---|
| HTTP Status Code | `200` |
| HTTP Context Map | *the same context map* |

**F) Wire them together**

| From | Relationship | To |
|---|---|---|
| HandleHttpRequest | `success` | ListS3 |
| ListS3 | `success` | FetchS3Object |
| FetchS3Object | `success` | PublishKafka |
| PublishKafka | `success` | HandleHttpResponse |

For `failure` on FetchS3Object and PublishKafka: right-click → **Configure** → **Settings** → check **Automatically Terminate**.

> In production you'd route failures to a retry loop or a dead-letter queue. Auto-terminating means silently dropping data. Fine for a demo; not fine for real.

**G) Start everything**

Ctrl+A on the canvas → click ▶ **Start**. All processors turn **green**. A red ⚠️ means a config error — hover and it tells you what.

### 8.4 Upload test files

```bash
source ~/.venvs/nifi-kafka/bin/activate
cd ~/infra/python-app

BUCKET=$(terraform -chdir=~/infra/terraform output -raw s3_bucket_name)

echo "Hello from the first file. This is line one." > file1.txt
echo "Second file. NiFi should pull this out of S3." > file2.txt
printf "Third file.\nWith multiple lines.\nAnd a third line.\n" > file3.txt

aws s3 cp file1.txt "s3://$BUCKET/incoming/"
aws s3 cp file2.txt "s3://$BUCKET/incoming/"
aws s3 cp file3.txt "s3://$BUCKET/incoming/"

aws s3 ls "s3://$BUCKET/incoming/"
```

### 8.5 `trigger_nifi.py`

```python
#!/usr/bin/env python3
"""
trigger_nifi.py -- pushes the button that starts the NiFi flow.

Think of NiFi as a vending machine that only dispenses when you push
the button. This pushes the button.

Runs on the COMMAND NODE. Reaches NiFi on port 9999, which is allowed
because the Command Node's SG is the only source permitted on that port.

Note: this is a plain HTTP call over the VPC peering connection.
There is no SSH anywhere in this system.
"""

import argparse
import json
import os
import subprocess
import sys
import time

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

INFRA_DIR = os.path.expanduser("~/infra/terraform")


def terraform_output(name: str) -> str:
    """Read a value straight out of Terraform state.

    Far better than hardcoding IPs: rebuild the infrastructure and
    this picks up the new addresses automatically.
    """
    try:
        r = subprocess.run(
            ["terraform", f"-chdir={INFRA_DIR}", "output", "-raw", name],
            capture_output=True, text=True, check=True, timeout=30,
        )
        return r.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"[!] terraform output '{name}' failed: {e.stderr}", file=sys.stderr)
        sys.exit(1)


def build_session() -> requests.Session:
    """Automatic retries with exponential backoff (1s, 2s, 4s...).

    NiFi can be briefly unresponsive during a flow restart. Rather than
    failing instantly, retry. This is standard practice for ANY network
    call and you should do it everywhere.
    """
    s = requests.Session()
    retry = Retry(
        total=5,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
    )
    s.mount("http://", HTTPAdapter(max_retries=retry))
    return s


def trigger(endpoint: str, prefix: str, session: requests.Session) -> bool:
    payload = {
        "action": "pull_from_s3",
        "prefix": prefix,
        "requested_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    print("=" * 62)
    print("  TRIGGERING NIFI")
    print("=" * 62)
    print(f"  Endpoint : {endpoint}")
    print(f"  Payload  : {json.dumps(payload)}")
    print("-" * 62)

    try:
        r = session.post(
            endpoint, json=payload,
            timeout=(5, 60),      # (connect, read)
            headers={"Content-Type": "application/json"},
        )
    except requests.exceptions.ConnectTimeout:
        print("[!] TIMED OUT connecting to NiFi.")
        print("    - Is the HandleHttpRequest processor STARTED (green)?")
        print("    - Does NiFi's SG allow :9999 from the Command Node?")
        print("    - Are you actually ON the Command Node?")
        return False
    except requests.exceptions.ConnectionError as e:
        print(f"[!] CONNECTION REFUSED: {e}")
        print("    Nothing is listening on 9999. Start the processor.")
        print("    Get a shell to check (no SSH needed):")
        print("      aws ssm start-session --target <nifi-instance-id>")
        return False

    print(f"  Status   : {r.status_code}")
    print("=" * 62)

    if r.status_code == 200:
        print("\n  NiFi accepted the trigger.")
        print("  Now: listing S3 -> fetching objects -> publishing to Kafka.")
        print("\n  Run  python consumer.py  to watch the contents arrive.\n")
        return True

    print(f"\n  Unexpected status {r.status_code}\n")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Tell NiFi to pull from S3")
    ap.add_argument("--prefix", default="incoming/")
    ap.add_argument("--endpoint", default=None)
    args = ap.parse_args()

    endpoint = args.endpoint or terraform_output("nifi_trigger_endpoint")
    return 0 if trigger(endpoint, args.prefix, build_session()) else 1


if __name__ == "__main__":
    sys.exit(main())
```

### 8.6 `consumer.py` — the `cat`

```python
#!/usr/bin/env python3
"""
consumer.py -- reads Kafka and prints file contents, like `cat`.

WHY THIS ONLY WORKS FROM THE COMMAND NODE
------------------------------------------
Kafka's security group has exactly TWO ingress rules on port 9092:

    1. source_security_group_id = <NiFi's SG>
    2. source_security_group_id = <Command Node's SG>

That's it. No CIDR blocks. No 0.0.0.0/0. And no port 22 on the box
either -- the whole build is SSM-only.

Run this from your laptop, or any other EC2 instance, and the TCP
connection will simply hang and time out.

That is not a bug. That is the requirement, working exactly as
specified.
"""

import argparse
import os
import subprocess
import sys
from datetime import datetime

from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable

INFRA_DIR = os.path.expanduser("~/infra/terraform")

CYAN, GREEN, YELLOW, GREY, BOLD, RESET = (
    "\033[96m", "\033[92m", "\033[93m", "\033[90m", "\033[1m", "\033[0m"
)


def terraform_output(name: str) -> str:
    r = subprocess.run(
        ["terraform", f"-chdir={INFRA_DIR}", "output", "-raw", name],
        capture_output=True, text=True, check=True, timeout=30,
    )
    return r.stdout.strip()


def cat_message(msg, index: int) -> None:
    """Print one Kafka message the way `cat` would print a file."""
    ts = datetime.fromtimestamp(msg.timestamp / 1000).strftime("%H:%M:%S")

    filename = "(unknown)"
    if msg.headers:
        for key, value in msg.headers:
            if key in ("filename", "s3.key", "nifi.filename"):
                filename = value.decode("utf-8", errors="replace")
                break

    # The message VALUE is the raw bytes of the .txt file from S3.
    try:
        content = msg.value.decode("utf-8")
    except UnicodeDecodeError:
        content = f"<{len(msg.value)} bytes of non-UTF8 data>"

    print()
    print(f"{CYAN}{'=' * 66}{RESET}")
    print(f"{BOLD}  MESSAGE #{index}{RESET}")
    print(f"{GREY}  file      : {filename}{RESET}")
    print(f"{GREY}  topic     : {msg.topic}  partition {msg.partition}  "
          f"offset {msg.offset}{RESET}")
    print(f"{GREY}  timestamp : {ts}   size: {len(msg.value)} bytes{RESET}")
    print(f"{CYAN}{'=' * 66}{RESET}")
    print(f"{YELLOW}  CONTENTS (this is the `cat`){RESET}")
    print(f"{CYAN}{'-' * 66}{RESET}")

    # ---- THE ACTUAL `cat` ----
    for line in content.splitlines():
        print(f"  {GREEN}{line}{RESET}")
    if not content.strip():
        print(f"  {GREY}(empty file){RESET}")
    # --------------------------

    print(f"{CYAN}{'-' * 66}{RESET}")


def main() -> int:
    ap = argparse.ArgumentParser(description="cat S3 text files, via Kafka")
    ap.add_argument("--topic", default="nifi-s3-files")
    ap.add_argument("--bootstrap", default=None)
    ap.add_argument("--group", default="s3-cat-consumer")
    ap.add_argument("--from-beginning", action="store_true",
                    help="replay the whole topic from offset 0")
    ap.add_argument("--max", type=int, default=0)
    args = ap.parse_args()

    bootstrap = args.bootstrap or terraform_output("kafka_bootstrap_server")

    print(f"\n{BOLD}{'=' * 66}{RESET}")
    print(f"{BOLD}  KAFKA CONSUMER -- cat-ing S3 text files{RESET}")
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"  broker : {bootstrap}")
    print(f"  topic  : {args.topic}")
    print(f"  offset : {'earliest (replay all)' if args.from_beginning else 'latest'}")
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"{GREY}  Waiting for messages... (Ctrl+C to quit){RESET}")

    try:
        consumer = KafkaConsumer(
            args.topic,
            bootstrap_servers=[bootstrap],
            group_id=args.group,

            # 'earliest' = start at offset 0, replay everything.
            # 'latest'   = start at the END, only show NEW messages.
            #
            # This ONLY applies the FIRST time a group_id is seen. After
            # that, Kafka remembers the group's committed offset and
            # resumes there. Change --group to force a fresh start.
            auto_offset_reset="earliest" if args.from_beginning else "latest",

            enable_auto_commit=True,
            auto_commit_interval_ms=1000,

            # Deliberately NOT deserializing -- we want the RAW bytes,
            # because that IS the literal content of the .txt file.
            value_deserializer=None,
        )
    except NoBrokersAvailable:
        print(f"\n  Cannot reach Kafka at {bootstrap}\n")
        print("  Check, in order:")
        print("    1. Is Kafka running? Get a shell (no SSH needed):")
        print("         aws ssm start-session --target <kafka-instance-id>")
        print("    2. Is the port reachable?")
        print(f"         nc -zv {bootstrap.replace(':', ' ')}")
        print("    3. ARE YOU ON THE COMMAND NODE?")
        print("       Only NiFi and the Command Node are in Kafka's SG")
        print("       ingress list. From anywhere else this WILL hang.")
        print("       That is not a bug -- that is the requirement working.\n")
        return 1

    count = 0
    try:
        for msg in consumer:
            count += 1
            cat_message(msg, count)
            if args.max and count >= args.max:
                break
    except KeyboardInterrupt:
        print(f"\n{GREY}  Interrupted.{RESET}")
    finally:
        consumer.close()
        print(f"\n{BOLD}  Total messages consumed: {count}{RESET}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### 8.7 Run the whole thing

**Terminal 1 — start the consumer first, so it's watching:**

```bash
aws ssm start-session --target <COMMAND_NODE_ID>
sudo su - ubuntu
source ~/.venvs/nifi-kafka/bin/activate
cd ~/infra/python-app
python consumer.py --from-beginning
```

**Terminal 2 — fire the trigger:**

```bash
aws ssm start-session --target <COMMAND_NODE_ID>
sudo su - ubuntu
source ~/.venvs/nifi-kafka/bin/activate
cd ~/infra/python-app
python trigger_nifi.py
```

```
==============================================================
  TRIGGERING NIFI
==============================================================
  Endpoint : http://10.20.11.42:9999/trigger
  Status   : 200
==============================================================

  NiFi accepted the trigger.
```

**Back in Terminal 1, within seconds:**

```
==================================================================
  MESSAGE #1
  file      : incoming/file1.txt
  topic     : nifi-s3-files  partition 0  offset 0
  timestamp : 14:23:07   size: 45 bytes
==================================================================
  CONTENTS (this is the `cat`)
------------------------------------------------------------------
  Hello from the first file. This is line one.
------------------------------------------------------------------

==================================================================
  MESSAGE #3
  file      : incoming/file3.txt
  topic     : nifi-s3-files  partition 2  offset 0
==================================================================
  CONTENTS (this is the `cat`)
------------------------------------------------------------------
  Third file.
  With multiple lines.
  And a third line.
------------------------------------------------------------------
```

🎉 **That's the whole system working.**

Trace what actually happened:

1. You opened a shell on a server **with no SSH, no key, and no inbound rules** — via an IAM-authenticated API call, logged in CloudTrail with your name on it.
2. Python sent an HTTP POST to NiFi — a server with **no public IP** — over a **VPC peering connection**.
3. NiFi listed an S3 bucket using an **IAM role**. No keys anywhere. The credentials field was **blank**.
4. It fetched the objects over a **free VPC Gateway Endpoint**, never touching the internet.
5. It published to Kafka, allowed through the firewall **only because it wears the NiFi badge**.
6. Python consumed them, allowed through **only because the Command Node wears the Command badge**.
7. Every byte stayed on AWS's private network the entire time.
8. **Not one SSH connection occurred at any point.**

---

## 9. Running the Whole Thing End to End

```bash
# --- ON YOUR LAPTOP ---
aws ssm start-session --target <COMMAND_NODE_ID>
sudo su - ubuntu

# --- ON THE COMMAND NODE ---
# 1. Build the infrastructure (8-12 min)
cd ~/infra/terraform
terraform init
terraform plan -out=tfplan     # READ THIS
terraform apply tfplan

# 2. ⭐ GATE: wait for the SSM agents. Mandatory.
watch -n 5 'aws ssm describe-instance-information \
  --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus}" \
  --output table'
# All Online? Ctrl+C and continue. There is no SSH fallback.

# 3. Configure the servers (15-25 min, over SSM)
export ANSIBLE_AWS_SSM_BUCKET=$(terraform output -raw ssm_transfer_bucket)
export NIFI_FQDN=nifi.yourdomain.com
cd ../ansible
ansible all -m ping            # sanity check
tmux new -s deploy             # survives a session drop
ansible-playbook site.yml

# 4. Build the flow in the NiFi UI (§8.3). Start all processors.

# 5. Load data, watch, trigger
BUCKET=$(terraform -chdir=~/infra/terraform output -raw s3_bucket_name)
echo "test content" > t.txt
aws s3 cp t.txt "s3://$BUCKET/incoming/"

source ~/.venvs/nifi-kafka/bin/activate
cd ~/infra/python-app
python consumer.py --from-beginning &
python trigger_nifi.py
```

### Automate it

**`~/infra/deploy.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "▶ Terraform"
cd ~/infra/terraform
terraform init -upgrade
terraform validate
terraform plan -out=tfplan

read -rp "Apply this plan? (yes/no) " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
terraform apply tfplan

echo "▶ Waiting for the SSM agents (there is no SSH fallback)..."
for i in $(seq 18); do
  ONLINE=$(aws ssm describe-instance-information \
    --query 'length(InstanceInformationList[?PingStatus==`Online`])' \
    --output text 2>/dev/null || echo 0)
  echo "   Online: ${ONLINE}/3"
  [[ "${ONLINE:-0}" -ge 3 ]] && break
  sleep 5
done

echo "▶ Ansible (over SSM)"
export ANSIBLE_AWS_SSM_BUCKET=$(terraform output -raw ssm_transfer_bucket)
export NIFI_FQDN=$(terraform output -raw nifi_url | sed 's|https://||')
cd ../ansible
ansible-playbook site.yml

echo "▶ Done."
terraform -chdir=~/infra/terraform output
```

```bash
chmod +x ~/infra/deploy.sh
```

Note the `read -rp` confirmation. **Never fully automate `terraform apply` without a human reading the plan** — not until you have a real CI pipeline with policy checks.
---

## 10. Deep Background: How Every Piece Actually Works

Now that it runs, here's the *why*.

### 10.1 How an SSM session actually works, step by step

This is worth understanding properly, because it's the foundation of everything here.

```
STARTUP (happens once, at boot, without you)
────────────────────────────────────────────
1. The instance boots. systemd starts amazon-ssm-agent.

2. The agent needs credentials to call the SSM API. It asks the
   Instance Metadata Service:
       GET http://169.254.169.254/.../iam/security-credentials/
   -> gets TEMPORARY credentials for the attached IAM role.

3. The agent calls ssm:UpdateInstanceInformation.
   AWS checks: does this role have AmazonSSMManagedInstanceCore?
       NO  -> registration DENIED. The instance is now unreachable
              forever. You must terminate it. There is no fallback.
       YES -> registered. PingStatus becomes "Online".

4. The agent opens an OUTBOUND WebSocket to ssmmessages
   (via the VPC interface endpoint) and holds it open,
   heartbeating every few minutes.

   >>> NOTE THE DIRECTION. The agent dialed OUT. <<<
   >>> Nothing connected IN. The instance has zero inbound rules. <<<


WHEN YOU RUN `aws ssm start-session --target i-0abc`
────────────────────────────────────────────────────
5. Your CLI calls the SSM API. IAM checks whether YOU are allowed to
   StartSession on that instance. (This is where a tag-scoped policy
   would enforce "only project X".)

6. AWS logs the session to CloudTrail: WHO, WHEN, WHICH INSTANCE.
   You cannot turn this off. That's a feature.

7. AWS returns a stream URL + a token to your CLI.

8. Your CLI hands them to session-manager-plugin -- the separate
   binary. THIS is why you had to install it. The CLI cannot speak
   the WebSocket protocol itself.

9. The plugin opens a WebSocket to AWS. AWS now has TWO sockets:
   yours, and the agent's (from step 4). It bridges them.

10. You type `ls`. It goes: your terminal -> plugin -> AWS -> down
    the agent's pre-existing socket -> the agent -> a real shell.
    Output comes back the same way.
```

**The insight is step 4.** The agent dialed *out* and AWS held the line open. When you connect, AWS isn't opening a new connection to the server — **it's using one the server already opened.**

This is exactly how a browser gets a live chat feed from a server behind a corporate firewall. The connection is established from the inside. There's no inbound hole to punch.

### 10.2 How the IAM role credential magic works

The security foundation of the entire design.

```
NiFi's Java code calls: s3Client.listObjects("my-bucket")
        |
        v
AWS SDK: "I need credentials. Walk the default chain."
        |
        ├─ 1. Java system properties?    -> not set
        ├─ 2. Environment variables?     -> not set
        ├─ 3. ~/.aws/credentials file?   -> DOESN'T EXIST (good!)
        └─ 4. EC2 Instance Metadata?     -> let's try...
                |
                v
        PUT http://169.254.169.254/latest/api/token
             (IMDSv2 -- token required first)
                |
                v
        GET .../meta-data/iam/security-credentials/nifi-role
                |
                v
        {
          "AccessKeyId":     "ASIA...",     <-- note: ASIA, not AKIA
          "SecretAccessKey": "...",         <-- TEMPORARY
          "Token":           "...",         <-- SESSION TOKEN
          "Expiration":      "2026-07-13T21:00:00Z"    <-- EXPIRES!
        }
                |
                v
        The SDK caches these, uses them, and AUTOMATICALLY refreshes
        ~5 min before expiry. Forever. With zero lines of your code.
```

Notice the key starts with **`ASIA`**, not `AKIA`. That prefix marks a **temporary** credential. A long-lived IAM user key starts with `AKIA` and **never expires** — which is exactly why they're so dangerous.

**And here's the killer detail:** because these expire in hours and rotate automatically, **even if an attacker steals them, they're worthless by dinnertime.** A leaked `AKIA` key works forever.

That's why the NiFi credentials service was blank. Blank means *"use the chain,"* and the chain means *"use the role."*

### 10.3 How Ansible-over-SSM actually moves a file

```
Ansible wants to run the `apt` module on the target.

1. Ansible builds the module: a self-contained Python file with the
   arguments baked in. Maybe 50 KB.

2. Over SSH it would SFTP this. But SSM has NO FILE CHANNEL.
   It carries a COMMAND STREAM only. You can send text. Not files.

3. So the aws_ssm plugin does this instead:

   a) PUT the module into the S3 transfer bucket:
        s3://ssm-transfer-abc/ansible-tmp-1234/AnsiballZ_apt.py

   b) Generate a PRESIGNED URL for it (valid a few minutes)

   c) Send a COMMAND over the SSM channel:
        "curl -s 'https://s3.../AnsiballZ_apt.py?X-Amz-Signature=...' \
           -o /tmp/x.py && python3 /tmp/x.py"

   d) The TARGET HOST downloads it FROM S3
      >>> THIS is why the INSTANCE role needs s3:GetObject.  <<<
      >>> Not just the controller. The TARGET does the GET.  <<<
      >>> Forget this and you get AccessDenied on every task, <<<
      >>> even though the SSM session connected fine.         <<<

   e) The host runs it. stdout returns over the SSM channel.

4. Repeat for EVERY task. That's the slowness. Each module is an
   S3 upload + a presign + a download.
```

Two things follow from this, and they explain most SSM-Ansible confusion:

1. **The S3 bucket isn't optional.** It's the file channel SSM doesn't have.
2. **The *target* needs S3 read permission**, not just the controller. This is the single least intuitive part of the setup, and it produces an error that never mentions S3.

### 10.4 How a packet gets from your browser to NiFi

Follow one HTTPS request all the way down:

```
1.  Browser looks up nifi.example.com
        v  DNS -> Route53
2.  Route53 has an ALIAS record. Resolves it to the ALB's current IPs.
    (ALIAS is resolved server-side by AWS -- that's why it's free and
     why it works at the zone apex, unlike a CNAME.)
        v
3.  Browser opens TCP :443 to the ALB's public IP.
    (The ALB is in a PUBLIC subnet -- it has a route to the IGW.)
        v
4.  ALB Security Group check:
       "Is the source IP in [my_ip_cidr]?"
       YES -> allow.
       NO  -> silently DROPPED. Not rejected. DROPPED. The attacker's
              connection just hangs. They learn nothing.
        v
5.  TLS handshake. ALB presents the ACM certificate. Browser validates
    it against Amazon's public CA. Padlock appears.
        v
6.  ALB decrypts. Reads the Host header. Matches the listener rule.
    Picks a healthy target from the target group.
        v
7.  ALB opens a *NEW* connection to NiFi at 10.20.11.42:8443.

    >>> THIS IS A COMPLETELY SEPARATE TCP CONNECTION. <<<
    The ALB is a PROXY, not a router. Your browser never talks to
    NiFi directly. This is why NiFi can sit in a subnet with NO
    internet route at all and still serve you a web page.
        v
8.  NiFi Security Group check:
       "Is the source SG the ALB's SG?"
       YES -> allow. Anything else -> DROPPED.
        v
9.  NiFi checks nifi.web.proxy.host against the Host header.
       Match    -> serve the page.
       No match -> "invalid host header". THE classic bug.
        v
10. Response travels back the same way.
    NOTE: no security group rule was needed for the reply. Security
    groups are STATEFUL -- the return path is automatic.
```

**The key realization is step 7.** The ALB opened a *new* connection. That's why NiFi never sees your browser's IP (it sees the ALB's), why the ALB can hold a public cert while NiFi holds a self-signed one, and why NiFi can live safely with no route to the internet.

### 10.5 How Kafka's log works on disk

Kafka's magic is that it's mostly *not* magic — it's an append-only file, and the OS does the heavy lifting.

```
Topic: nifi-s3-files
  ├── Partition 0 -> /var/lib/kafka/nifi-s3-files-0/
  │                    ├── 00000000000000000000.log      <- the messages
  │                    ├── 00000000000000000000.index    <- offset -> byte position
  │                    └── 00000000000000000000.timeindex
  ├── Partition 1 -> .../nifi-s3-files-1/
  └── Partition 2 -> .../nifi-s3-files-2/
```

A `.log` file is literally just messages appended one after another:

```
[offset 0][len][crc][key][value: "Hello from the first file..."]
[offset 1][len][crc][key][value: "Second file. NiFi should..."]
[offset 2][len][crc][key][value: "Third file.\nWith multiple..."]
                                  ^
                     Always append here. Never seek. Never edit.
```

Why so fast? Three reasons, and none of them are clever code:

1. **Sequential writes.** Appending to the end of a file is the fastest thing a disk can do — on spinning rust it's ~100× faster than random writes, and it's substantially faster even on SSDs.

2. **The page cache.** Kafka doesn't cache messages in the JVM heap. It writes to the **OS page cache** and lets Linux handle it. A message written a second ago is almost certainly still in RAM when a consumer asks for it. Kafka gets an enormous cache for free — and never has to garbage-collect it.

3. **Zero-copy (`sendfile`).** When a consumer reads, Kafka calls the `sendfile()` syscall, which copies bytes **directly from the page cache to the network card**. The data never enters userspace. Never enters the JVM. This is why one modest broker can saturate a 10 Gb NIC.

**Partitions are the unit of parallelism.** Three partitions = up to three consumers in a group reading simultaneously, one each. A fourth would sit idle. **Partition count is the ceiling on your consumer parallelism, and you can't easily lower it later.**

**Ordering, precisely:** Kafka guarantees order **within a partition**, not across a topic. Need file A processed before file B? They must land in the same partition (use the same message key). Our three test files landed in three different partitions — which is exactly why they may print out of order.

### 10.6 How Terraform's dependency graph works

Look at this:

```hcl
resource "aws_subnet" "private" {
  vpc_id = aws_vpc.main.id     # <-- a reference
}
```

That single reference tells Terraform: **"the subnet depends on the VPC."** Terraform builds a DAG from every such reference:

```
                    aws_vpc.main
                   /      |       \
      aws_subnet.public   |    aws_internet_gateway.main
              |           |              |
              |    aws_subnet.private    |
              |           |              |
       aws_nat_gateway ───┘              |
              |                          |
      aws_route_table.private     aws_route_table.public
```

Then it walks the graph, building **everything on the same level in parallel**. Both subnets are created at the same instant. Both route tables at the same instant. That's why 61 resources take 8 minutes instead of 61 sequential API calls.

You almost never need `depends_on`. If you're writing it, ask whether you've missed a natural reference. The legitimate exception is an *implicit* dependency Terraform can't see — like our NAT Gateway needing the IGW attached first, even though it doesn't reference it.

### 10.7 What NiFi's provenance is really doing

Every time a FlowFile passes through *any* processor, NiFi writes a provenance event:

```
Event 1  RECEIVE   ListS3         file: incoming/file1.txt
Event 2  FETCH     FetchS3Object  downloaded 45 bytes from S3
Event 3  SEND      PublishKafka   -> nifi-s3-files partition 0 offset 0
```

Click any event and see:
- The **exact bytes** of the content, before and after
- Every attribute at that moment
- The full lineage graph, backwards and forwards
- **Replay** — re-run this exact FlowFile from this exact point

That last one is the killer feature. Bug in a downstream processor? Fix it and **replay the original data**. You don't need to re-fetch from S3. You don't need the source system to still have it. **NiFi kept it.**

This is why banks and hospitals use NiFi. When an auditor asks *"prove what happened to this specific record on March 3rd,"* NiFi can literally show them.

The cost: provenance eats disk. Defaults keep 24 hours or 1 GB. Plan storage accordingly — it's why we gave NiFi 100 GB.

---

## 11. Best Practices (And Why They Matter)

### 11.1 Access & Security

| ✅ Do | ❌ Don't | Why it matters |
|---|---|---|
| **Use SSM Session Manager** | Open port 22, even "just from the bastion" | An SSH daemon is an attack surface that exists whether you're using it or not. SSM has none. |
| **Launch with no key pair** | Create a key pair "just in case" | A key that exists can be copied. A key that doesn't exist cannot. |
| **Scope `ssm:StartSession` by tag** | Grant `ssm:*` on `Resource: "*"` | You can say *"this person may shell into project X and nothing else in the account."* You cannot express that with SSH. |
| **Turn on SSM session logging** | Rely on `auth.log` on the box | Every keystroke, to S3, immutable, attributed to an IAM principal — on a machine an attacker would want to edit the logs of. |
| Use IAM roles on EC2 | Put access keys in files or env vars | Bots scan every public GitHub commit **within seconds** for `AKIA`. People have woken to $50k crypto-mining bills. |
| **Reference security groups** (badges) | Hardcode CIDRs / IPs | IPs change on reboot. And a CIDR lets *any* box in that range in, including ones you didn't create. |
| Put data servers in **private subnets** | Give them public IPs | No route = unreachable. A firewall misconfiguration can't conjure a route that doesn't exist. |
| Enforce IMDSv2 (`http_tokens = required`) | Leave IMDSv1 on | IMDSv1 was the vector in the **2019 Capital One breach** — an SSRF flaw let an attacker read role credentials. IMDSv2's token requirement kills that whole class of attack. |
| Encrypt EBS + S3 | Leave them plaintext | Free. Zero performance cost. Required by most compliance regimes. No reason not to. |
| **Block ALL public S3 access** (all four flags) | Trust bucket policies alone | Every *"N million records exposed"* headline is a public bucket. |
| **Restrict egress too** | `0.0.0.0/0` outbound on everything | Egress is how data gets **exfiltrated**. Least privilege applies in both directions. |

**The one SSM-specific gotcha:** you must allow **outbound 443**. The agent connects *out*. Lock egress down to nothing and **you have permanently locked yourself out**, with no SSH fallback. That's the one rule you cannot break.

**Scoping down `AdministratorAccess`:** in a real org you'd replace it with a policy granting only the services Terraform touches, plus **permission boundaries** so the role can't create *another* role more powerful than itself (a classic privilege-escalation path). [iamlive](https://github.com/iann0036/iamlive) can watch a `terraform apply` and generate the exact minimal policy.

### 11.2 The least-privilege SSM policy for a human

Here's what an *operator* actually needs. Note the tag condition — this is the thing you cannot do with SSH:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartSessionsOnProjectInstancesOnly",
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

Read the first statement again: **this person can shell into instances tagged `Project=nifi-platform`, and nothing else in the entire AWS account.**

Try expressing that with SSH keys. You'd need a bastion per project, separate key distribution, and a way to stop someone copying a key from one bastion to another. Here it's four lines, enforced centrally, and it takes effect instantly.

The `${aws:username}-*` on `TerminateSession` means they can kill their own sessions but not a colleague's.

### 11.3 Terraform

| ✅ Do | ❌ Don't |
|---|---|
| **Always read `terraform plan` before `apply`** | Blindly apply. A `-/+` on a volume means your data is about to be destroyed. |
| Remote state in S3 with `use_lockfile = true` | Local `.tfstate` on a laptop. Lose it and Terraform forgets it owns your infra. |
| Pin providers with `~>` | Float on latest. A major-version release will break your build on a random Tuesday. |
| `terraform fmt` + `validate` in CI | Bikeshed about formatting in PRs |
| Variables + `.tfvars` | Hardcode account IDs and IPs in `.tf` files |
| Add `validation` blocks | Discover a typo six minutes into an apply |
| Tag everything (`default_tags`) | Get a $400 bill with no idea what caused it |
| Separate state per environment | One state for dev+prod. One bad apply and prod is gone. |
| **`for_each` over `count` for named things** | `count` — see below |

**The `count` trap, made concrete.** With `count` and `["a","b","c"]`, remove `"b"` and Terraform sees:
- index 1 changes `b` → `c` → **destroy and recreate**
- index 2 disappears → **destroy**

You wanted to delete one thing. **You destroyed and rebuilt two.** With `for_each` on a map, each resource is tracked by *name*, and removing `"b"` destroys only `"b"`. Use `for_each` whenever items have identities. This has caused real outages.

### 11.4 Ansible (SSM-specific)

| ✅ Do | ❌ Don't |
|---|---|
| **`hostnames: instance-id`** in inventory | `private-ip-address` — SSM addresses by ID, not IP |
| **`pipelining = False`** | Turn it on out of habit. It's an SSH optimization and it breaks `aws_ssm`. |
| Export `ANSIBLE_AWS_SSM_BUCKET` | Forget it and get a confusing error that never mentions S3 |
| Grant the **target role** `s3:GetObject` | Assume the controller's permission is enough. **The target does the GET.** |
| Add a preflight assert for both of the above | Debug a vague error for 40 minutes |
| Raise `forks` | Accept the S3 round-trip slowness |
| Run long plays under `tmux` | Lose a 20-minute run to a session timeout |
| Use modules (`apt:`, `template:`) | `shell:`/`command:` for everything |
| Make everything idempotent (`creates:`, `state: present`) | Write tasks that break on the second run |
| `--check --diff` before running for real | Discover a mistake in production |
| `ansible-vault` for secrets | Plaintext passwords in git |

**Why `shell:` is a smell.** `shell: apt-get install -y nginx` runs every time, reports `changed` every time, and tells you nothing about whether it did anything. `apt: name=nginx state=present` checks first, does nothing if it's there, reports `ok`. Modules give you idempotency and honest reporting for free. Reach for `shell:` only when no module exists — and when you do, **always** add `creates:` or `changed_when:` so it stays honest.

### 11.5 Kafka

| ✅ Do | ❌ Don't |
|---|---|
| KRaft mode (3.3+) | Install ZooKeeper. **It was removed in Kafka 4.0.** |
| Set `advertised.listeners` to a **reachable** address | Leave it as `localhost` and lose an afternoon |
| 3+ brokers in production | Run one broker and call it HA |
| `replication.factor >= 3`, `min.insync.replicas = 2` | RF=1 in prod. One disk dies = data gone. |
| Partitions ≥ expected consumers | Under-partition. You can **add** partitions later but **cannot remove** them, and adding breaks key-based ordering. |
| SASL_SSL + ACLs for real data | PLAINTEXT outside a locked-down VPC |
| Monitor consumer lag | Fly blind |
| Run `chrony`/NTP | Ignore clock drift. Kafka's timestamps and session timeouts genuinely depend on it. |

### 11.6 NiFi

| ✅ Do | ❌ Don't |
|---|---|
| Set `nifi.web.proxy.host` behind a proxy | Wonder why "invalid host header" — it's always this |
| **Leave the AWS credentials service blank** | Paste an access key into the UI. You'd be undoing the entire security design. |
| Back-pressure on connections | Let a queue grow until the disk fills and NiFi dies |
| Route `failure` somewhere real | Auto-terminate failures in prod and silently lose data |
| Give the JVM real heap (4G+) | Run on a `t3.micro` and watch it OOM |
| Separate disks for the three repositories | Put flowfile/content/provenance on one volume and watch them fight for IOPS |
| Version-control flows (NiFi Registry) | Click-configure prod with no rollback path |

---

## 12. Pros and Cons of Every Choice We Made

### 12.1 SSM vs. SSH vs. a VPN

| | **SSM (ours)** | **SSH + bastion** | **VPN (e.g. WireGuard)** |
|---|---|---|---|
| Inbound port needed | **None** | 22 on the bastion | UDP 51820 on the gateway |
| Extra infra to run | **None** | A bastion EC2 | A VPN gateway EC2 |
| Credential | **IAM. Nothing on disk.** | A private key file | A private key file |
| Revoke one person | **One IAM change** | Hunt down key copies | Revoke a peer, redistribute |
| Audit trail | **CloudTrail + full session recording** | `auth.log` if you ship it | Connection logs only |
| Extra monthly cost | **~$22** (3 endpoints) | ~$8 (a t3.micro bastion) | ~$8 |
| Works with no public IP | **Yes** | Bastion needs one | Gateway needs one |
| Ansible speed | ⚠️ **Slower** (S3 round-trip) | ✅ Fast | ✅ Fast |
| Works offline / outside AWS | ❌ Needs AWS API access | ✅ Yes | ✅ Yes |
| Extra binary to install | ⚠️ `session-manager-plugin` | ✅ ssh is everywhere | ⚠️ VPN client |

**Honest verdict:** SSM is the right default on AWS in 2026. The security model is genuinely better, not just differently-shaped, and the audit trail is free.

**But it is not universally better.** SSM ties you to AWS's control plane. If the SSM API is having a bad day, you cannot reach your instances — whereas SSH would still work. Some teams keep a **break-glass** path (a key pair in a sealed envelope, an SG rule they can enable in an emergency) precisely for this. That's a defensible choice; just make it deliberately rather than by accident.

The Ansible slowdown is real and you will notice it.

### 12.2 Command Node vs. laptop vs. CI/CD

| | **Command Node (ours)** | **Laptop** | **CI/CD (GitHub Actions)** |
|---|---|---|---|
| Setup effort | Medium | **Lowest** | Highest |
| Cost | ~$15/mo | **Free** | Free–$ |
| Credentials | ✅ **IAM role, nothing on disk** | ❌ Long-lived keys in `~/.aws` | ✅ **OIDC, no keys** |
| Reach private subnets | ✅ Via peering | ❌ Needs a VPN | ⚠️ Needs a self-hosted runner |
| Consistent environment | ✅ One machine, one version | ❌ "Works on my machine" | ✅ Yes |
| Audit trail | ⚠️ Shell history | ❌ None | ✅ **Every change is a PR** |
| Team collaboration | ⚠️ A shared box, awkward | ❌ Poor | ✅ **Excellent** |
| Enforce plan review | ❌ Manual discipline | ❌ Manual discipline | ✅ **Enforced by the tool** |

**Verdict:** the Command Node is the right *learning* tool and a legitimate ops-workstation pattern. But **CI/CD is where you should end up.**

The single biggest win of CI isn't automation — it's that infrastructure changes become **pull requests**, so someone else reads the `plan` before it runs. That catches more incidents than any tool.

### 12.3 EC2 Kafka vs. Amazon MSK

| | **Self-managed EC2 (ours)** | **Amazon MSK** | **MSK Serverless** |
|---|---|---|---|
| Cost (small) | ~$30/mo | ~$150+/mo | Pay per GB |
| You patch the OS | ✅ You do | ❌ AWS does | ❌ AWS does |
| You handle broker failure | ✅ **At 3am** | ❌ AWS does | ❌ AWS does |
| Config control | ✅ **Total** | ⚠️ Most | ❌ Limited |
| Learning value | ✅ **Enormous** | ⚠️ Some | ❌ It's a black box |
| Right for production? | ⚠️ Only with real ops staff | ✅ **Yes** | ✅ For spiky loads |

**Verdict:** we chose EC2 because **you learn far more**. Understanding `advertised.listeners`, KRaft, partitions, and the on-disk log makes you dramatically better at debugging Kafka — including *managed* Kafka.

But for anything with a real SLA, **use MSK.** Paying AWS $120/month to never get paged about a broker at 3am is an extremely good trade.

### 12.4 NiFi vs. the alternatives

| | **NiFi** | **Airflow** | **Kafka Connect** | **A Lambda** |
|---|---|---|---|---|
| Interface | Drag & drop | Python code | Config files | Code |
| Best at | **Streaming, routing, real-time** | **Batch, scheduling, DAGs** | Kafka↔X only | Simple, event-driven |
| Data lineage | ✅ **World-class** | ⚠️ Basic | ❌ | ❌ |
| Resource hunger | ❌ **Heavy JVM** | Medium | Medium | ✅ **Tiny** |
| Version control | ⚠️ Needs NiFi Registry | ✅ **It's just code** | ✅ Config | ✅ Code |
| Cost | Your EC2 | Your EC2 / MWAA | Your EC2 | **~Free at low volume** |

**Honest verdict for *this exact* task:** if all you needed was *"copy S3 text files into Kafka,"* a **20-line Lambda triggered by an S3 event** would be cheaper, simpler, and better. Genuinely. No NiFi, no `t3.large`, no JVM, no NAT Gateway.

NiFi earns its keep when you have:
- **Many** sources and sinks that keep changing
- Non-programmers who need to build and modify flows
- Regulatory requirements for **provenance and replay**
- Complex routing, enrichment, and format conversion in flight

We used NiFi because you asked for it, and because it teaches an enormous amount about data-flow architecture. But *"should I use NiFi?"* has a real answer, and it is frequently **no**.

### 12.5 VPC Peering vs. Transit Gateway vs. one big VPC

| | **Peering (ours)** | **Transit Gateway** | **One VPC** |
|---|---|---|---|
| Hourly cost | **$0** | ~$36/mo + attachments | $0 |
| Scales to N VPCs | ❌ **N². 10 VPCs = 45 peerings.** | ✅ Hub & spoke, linear | N/A |
| Transitive routing | ❌ **No.** A↔B and B↔C does **not** give A↔C. | ✅ Yes | N/A |
| Complexity | **Low** | Medium | **Lowest** |
| Blast radius | Small | Small | **Large** |

**Verdict:** peering is right for 2 VPCs. It is *actively wrong* for 10 — the N² explosion and the lack of transitive routing will bury you. Past about 4 VPCs, move to **Transit Gateway**.

**And yes** — you could have avoided this entirely by putting the Command Node *inside* the data VPC. Simpler, cheaper. We used two VPCs deliberately, because separating your **control plane** from your **data plane** is a genuinely good pattern: you can destroy and rebuild the entire data VPC without touching the machine that does the destroying.

**A note specific to SSM:** the peering is only for the **data path** (Kafka 9092, NiFi 9999). The **SSM control path doesn't need it** — SSM goes through the AWS API, not through your network. Two independent paths. That's why you could `start-session` into NiFi even if peering were completely broken.

### 12.6 NAT Gateway vs. the alternatives

| | **NAT Gateway (ours)** | **NAT instance** | **Endpoints only** | **No egress** |
|---|---|---|---|---|
| Cost | **~$32/mo + $0.045/GB** 💸 | ~$4/mo | ~$7/mo per interface endpoint | $0 |
| AWS-managed | ✅ | ❌ You patch it | ✅ | N/A |
| Single point of failure | ❌ | ✅ **Yes** | ❌ | N/A |
| Can `apt install` | ✅ | ✅ | ❌ | ❌ |

**The NAT Gateway is the most expensive single line item in this build** — about a sixth of the total. Three ways to cut it:

1. **Add more VPC endpoints.** The S3 Gateway endpoint is **free** and already saves you all S3 traffic charges. Add endpoints for anything else you call often.
2. **Bake AMIs with Packer.** Pre-build an image with Java, NiFi, and Kafka installed. Then the instances never need to download anything, and **you can delete the NAT Gateway entirely.** This is the professional answer and it's a large saving. *(Note: you'd still keep the three SSM endpoints — those aren't optional.)*
3. **NAT instance.** A `t3.nano` saves ~$28/month. Single point of failure, and you patch it. Fine for dev.

---

## 13. Troubleshooting: When Things Break

### 🔴 SSM: instance doesn't appear / `TargetNotConnected`

**There is no SSH fallback.** If SSM is broken, you have no access. Work this list in order — it's almost always #2.

```bash
# 1. WAIT. A fresh instance takes ~90s to register. Don't panic early.

# 2. DO ALL THREE VPC ENDPOINTS EXIST?   <-- usually the problem
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-0abc" \
  --query 'VpcEndpoints[].ServiceName' --output text
```

You **must** see all three:
- `com.amazonaws.us-east-1.ssm`
- `com.amazonaws.us-east-1.ssmmessages`
- `com.amazonaws.us-east-1.ec2messages` ← **the one everyone forgets**

`ec2messages` *sounds* legacy and optional. **It is neither.** Omit it and the instance registers, then immediately shows "Connection lost."

```bash
# 3. Is private DNS on?
aws ec2 describe-vpc-endpoints \
  --query 'VpcEndpoints[].{Svc:ServiceName,DNS:PrivateDnsEnabled}' --output table
# All three must be true. If false, the agent resolves the PUBLIC
# endpoint and tries to go out via NAT. It may work; it may hang.

# 4. Does the role have AmazonSSMManagedInstanceCore?
aws iam list-attached-role-policies --role-name nifi-platform-dev-nifi-role

# 5. Does the instance SG allow OUTBOUND 443?
# The agent connects OUT. No egress = no agent = no access. Ever.
```

### 🔴 "I think I locked myself out"

You mostly can't — that's the point. As long as the instance runs, the agent lives, and the role is attached, **you're in**. There is no key to lose.

But if you **detach the IAM role** or **delete the SSM endpoints**, you have. Recovery: re-attach the role via the AWS API (a *control-plane* operation — still available to you, since it doesn't need network access to the box), wait 90 seconds, reconnect.

### 🔴 Ansible: vague S3 / AccessDenied error on every task

Three causes:

1. **`ANSIBLE_AWS_SSM_BUCKET` isn't set.**
   ```bash
   echo $ANSIBLE_AWS_SSM_BUCKET   # empty? that's it
   export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=~/infra/terraform \
     output -raw ssm_transfer_bucket)
   ```
   The preflight in `site.yml` catches this with a clear message. If you skipped it, this is your problem.

2. **The *instance* role lacks `s3:GetObject` on the transfer bucket.** The controller uploading isn't enough — **the target host does the download.** This is the least intuitive part of the whole setup.

3. **`session-manager-plugin` isn't installed on the Command Node.**
   ```bash
   /usr/local/sessionmanagerplugin/bin/session-manager-plugin --version
   ```

### 🔴 Ansible: `TargetNotConnected` against something like `10.20.11.42`

**Your inventory is using IPs.** SSM addresses hosts by **instance ID**.

```yaml
hostnames:
  - instance-id      # NOT private-ip-address
```

This error is maddening because it's a **hostname** problem wearing a **network** problem's clothes. You'll go check firewalls for an hour. Don't. Check this line.

### 🔴 Ansible is slow

It is. Every module round-trips through S3. Raise `forks`.

**Do not enable `pipelining`.** It's an SSH optimization and it breaks the SSM plugin.

### 🔴 NiFi: "System Error: invalid host header"

**It is `nifi.web.proxy.host`.** It is always `nifi.web.proxy.host`.

```bash
aws ssm start-session --target $(terraform output -raw nifi_instance_id)
sudo grep proxy.host /opt/nifi/conf/nifi.properties
```

It must contain your ALB's FQDN. Fix the role and re-run the playbook.

### 🔴 ALB target shows "unhealthy"

```bash
aws elbv2 describe-target-health --target-group-arn <ARN>
```

| Reason | Meaning | Fix |
|---|---|---|
| `Target.Timeout` | ALB can't reach NiFi | NiFi's SG must allow 8443 **from the ALB's SG** |
| `Target.ResponseCodeMismatch` | Wrong status code | The health check `matcher` **must include `401`** |
| `Target.FailedHealthChecks` | NiFi is down or still booting | Wait 4 minutes. NiFi boots slowly. |

**That `401` catches everyone.** A 401 means *"I'm alive and asking who you are"* — that is a **healthy** NiFi. If your matcher is only `200`, the ALB will mark a perfectly working NiFi as unhealthy **forever**.

### 🔴 Kafka: consumer connects, then hangs forever with no error

**It is `advertised.listeners`.** It is essentially always `advertised.listeners`.

```bash
aws ssm start-session --target $(terraform output -raw kafka_instance_id)
sudo grep advertised /opt/kafka/config/kraft/server.properties
```

Kafka's protocol: the client connects to the bootstrap server, asks *"who are the brokers?"*, gets back the **advertised** address, then **disconnects and reconnects** to *that* address.

If it advertises `localhost`, the client dutifully reconnects to **its own** localhost, finds nothing, and waits until the heat death of the universe. No error. Just silence.

### 🔴 Kafka: `NoBrokersAvailable`

```bash
# Is it running?
aws ssm send-command --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=kafka" \
  --parameters 'commands=["systemctl is-active kafka"]'

# Can you reach the port?
nc -zv <kafka-ip> 9092
```

**If you're running the consumer from anywhere except the Command Node or NiFi, it will fail — and that is correct.** Kafka's SG admits exactly two source security groups. That's the requirement working, not a bug.

### 🔴 Messages published but the consumer sees nothing

```bash
aws ssm send-command --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=kafka" \
  --parameters 'commands=["/opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell --bootstrap-server localhost:9092 --topic nifi-s3-files"]'
```

`nifi-s3-files:0:3` means partition 0 has 3 messages. **All zeros** → NiFi never published; check NiFi's PublishKafka bulletin.

Messages *are* there but you see nothing? Your consumer group already committed past them:

```bash
python consumer.py --from-beginning --group brand-new-name
```

A fresh `group_id` has no committed offset, so `auto_offset_reset=earliest` applies and it replays from 0.

### 🔴 Terraform: `Error acquiring the state lock`

A crashed run holds it. **Only** after you're certain nobody else is applying:

```bash
terraform force-unlock <LOCK_ID>
```

Force-unlocking while a colleague is mid-apply **will corrupt your state.**

### 🔴 `error: externally-managed-environment`

You forgot the venv.

```bash
source ~/.venvs/nifi-kafka/bin/activate
```

**Do not** use `--break-system-packages`. It is named after what it does.

---

## 14. Cost Estimate and How to Turn It All Off

### Monthly cost (us-east-1, on-demand, 24/7)

| Resource | Spec | ~Monthly |
|---|---|---|
| Command Node | t3.small | $15.18 |
| NiFi | t3.large | $60.74 |
| Kafka | t3.medium | $30.37 |
| EBS: Command | 30 GB gp3 | $2.40 |
| EBS: NiFi | 100 GB gp3 | $8.00 |
| EBS: Kafka | 100 GB gp3 | $8.00 |
| **NAT Gateway** | 1, + ~10GB | **$33.35** 💸 |
| ALB | 1, low traffic | $16.43 |
| **SSM Interface Endpoints** | **3 × ~$7.30** | **$21.90** 🔒 |
| S3 Gateway Endpoint | — | **$0.00** ✅ |
| Route53 hosted zone | 1 | $0.50 |
| ACM certificate | 1 | **$0.00** ✅ |
| VPC peering (hourly) | — | **$0.00** ✅ |
| S3 storage | ~1 GB | $0.02 |
| SSM Session Manager itself | — | **$0.00** ✅ |
| | **TOTAL** | **≈ $197/month** |

**Two lines deserve comment:**

- **The three SSM endpoints ($22/mo)** are the literal price of having zero open ports. That's what you're buying. In exchange you delete the bastion host you'd otherwise be running (~$8/mo) — so the *net* cost of SSM is more like **$14/month**, and you get the audit trail free.

- **SSM Session Manager itself is free.** You pay for the endpoints (a networking cost), not the service.

### 💰 Cutting it down

| Action | Saves | Trade-off |
|---|---|---|
| **Stop instances when not in use** | ~$85/mo | You pay only EBS. **Biggest single win.** |
| Bake an AMI (Packer), delete NAT GW | **$33/mo** | Real effort, but the *right* fix |
| Delete the 3 SSM endpoints, rely on NAT | $22/mo | ⚠️ SSM traffic then goes out to the internet and back. Works, but you lose the "entirely private" property. |
| NAT instance instead of NAT GW | $28/mo | Single point of failure; you patch it |
| Downsize NiFi to t3.medium | $30/mo | NiFi will be sluggish; may OOM |
| Delete the ALB, use SSM port-forwarding | $16/mo | ✅ **Actually viable now!** You can reach NiFi's UI via `AWS-StartPortForwardingSession` without any load balancer at all. |
| 1-yr Savings Plan | ~30% off EC2 | Committed for a year |

> **That second-to-last row is a genuine SSM bonus.** In an SSH world, the ALB is the only reasonable way to reach NiFi's web UI. With SSM port-forwarding, you can drop the ALB entirely and still get to the UI on `localhost:8443` — with **no public endpoint at all**. That's $16/month *and* a smaller attack surface. The only reason to keep the ALB is if non-admin users need browser access.

**Stop, don't destroy, between sessions:**

```bash
IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=nifi-platform" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

aws ec2 stop-instances --instance-ids $IDS
# Start again tomorrow:
aws ec2 start-instances --instance-ids $IDS
```

> ⚠️ **Stopped instances get NEW private IPs on restart.** After a start, **re-run the Ansible playbook** so NiFi learns Kafka's new address. (A good argument for using an ENI or DNS names instead of raw IPs in production.)
>
> **The SSM agent re-registers automatically** on boot — so your *access* survives a stop/start with no action needed. That's another quiet advantage: with SSH you'd have a new IP to look up. With SSM you address by **instance ID**, which never changes.

### 🔥 Destroy everything

```bash
cd ~/infra/terraform

# Empty the buckets FIRST -- Terraform CANNOT delete a non-empty
# bucket, and versioning means "delete all objects" isn't enough
# (there are old versions and delete markers too).
for B in $(terraform output -raw s3_bucket_name) \
         $(terraform output -raw ssm_transfer_bucket); do
  aws s3 rm "s3://$B" --recursive
  aws s3api list-object-versions --bucket "$B" --output json \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    | jq -c 'select(.Objects != null)' \
    | while read -r batch; do
        aws s3api delete-objects --bucket "$B" --delete "$batch" >/dev/null
      done
done

terraform plan -destroy    # READ IT
terraform destroy
```

**Then clean up the manual bits** (Terraform doesn't manage these — you built them by hand):

1. Terminate the `command-node` instance
2. Delete the `command-node-sg` security group
3. Delete the `command-node-role` IAM role
4. Empty and delete the `tfstate-cmdnode-*` bucket

**Verify nothing expensive survived:**

```bash
# NAT Gateways -- the pricey ones
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId'
# Should be: []

aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
# Should be: []

# The three SSM interface endpoints (~$22/mo)
aws ec2 describe-vpc-endpoints \
  --query 'VpcEndpoints[?VpcEndpointType==`Interface`].ServiceName'
# Should be: []

aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
# Should be: []
```

**Check the Billing dashboard tomorrow.** Confirm charges stopped.

---

## 15. Glossary

| Term | Plain English |
|---|---|
| **ACM** | AWS Certificate Manager — free HTTPS certificates |
| **ALB** | Application Load Balancer — the doorman that understands HTTP |
| **AMI** | Amazon Machine Image — a snapshot of an OS, used as a template |
| **Ansible** | Configures servers. Normally over SSH; **here, over SSM.** |
| **`aws_ssm` plugin** | Ansible's connection plugin that reaches a host with **no SSH**. From the `community.aws` collection. |
| **Availability Zone (AZ)** | One physical data center building |
| **Bastion / Jump box** | A server you SSH into first, to reach others. **We don't have one. SSM makes it unnecessary.** |
| **CIDR** | `10.0.0.0/16` — how you write "a range of IP addresses" |
| **CloudTrail** | AWS's audit log. **Every SSM session appears here**, with the IAM principal who opened it. |
| **Consumer group** | A team of Kafka readers sharing one bookmark |
| **Declarative** | You describe the *result*; the tool figures out the steps |
| **`ec2messages`** | One of the three SSM VPC endpoints. **Sounds legacy. Is required. Everyone forgets it.** |
| **Egress** | Traffic going **out**. In SSM, the agent's egress on 443 is **load-bearing** — block it and you're locked out. |
| **FlowFile** | NiFi's data package: content + attributes. An envelope with a label. |
| **IAM Role** | A uniform of permissions a *machine* can wear. **The correct alternative to access keys — and, in an SSM build, the access-control mechanism itself.** |
| **Idempotent** | Running it twice = running it once |
| **IGW** | Internet Gateway — the door between a VPC and the internet |
| **IMDSv2** | The token-protected instance metadata service. Where role credentials come from. Its predecessor was the Capital One breach vector. |
| **Ingress** | Traffic coming **in**. In this build, NiFi and Kafka have almost none — and **zero on port 22**. |
| **Instance Profile** | The wrapper that lets an EC2 instance actually *wear* an IAM role |
| **KRaft** | Kafka's built-in coordination mode. **Replaced ZooKeeper.** |
| **NAT Gateway** | One-way mirror: private servers reach out, nothing reaches in. **Expensive.** |
| **Offset** | A consumer's bookmark in a Kafka partition |
| **Partition** | One slice of a Kafka topic. Sets the ceiling on consumer parallelism. |
| **PEP 668** | The rule that makes Ubuntu 24.04 refuse `pip install` outside a venv |
| **Private subnet** | A subnet with **no route** to the internet. Not "firewalled" — **unroutable**. |
| **Provenance** | NiFi's complete audit trail of everything that happened to every FlowFile |
| **Security Group** | A stateful, allow-only firewall. **Can reference other SGs — the badge trick.** |
| **`session-manager-plugin`** | The separate binary `aws ssm start-session` needs. **Not bundled with the CLI.** Ansible's plugin shells out to it too. |
| **SSM Agent** | The program on the instance that **polls outbound** to AWS. The reason no inbound port is needed. |
| **SSM Session Manager** | AWS's shell-without-SSH service. **The foundation of this entire build.** |
| **State (Terraform)** | The file mapping "what I called X" → "the real AWS resource". Guard it. |
| **Stateful (firewall)** | Allow it in, and the reply is automatically allowed out |
| **Terraform** | Turns a text file into cloud infrastructure |
| **venv** | An isolated Python sandbox |
| **VPC** | Your own private network inside AWS |
| **VPC Endpoint** | A private road from your VPC to an AWS service. **The S3 Gateway one is free.** The three SSM Interface ones cost ~$22/mo and are **mandatory here**. |
| **VPC Peering** | A private tunnel between two VPCs. No hourly cost. Not transitive. |
| **Zero-copy** | Kafka sending bytes straight from page cache to NIC. Why it's so fast. |

---

## Where to Go Next

You have a working, security-conscious data platform with **no SSH surface at all**. Here's what's still missing before this is production-grade, roughly in priority order:

1. **Move Terraform into CI/CD.** GitHub Actions with OIDC (no stored AWS keys). Infra changes become pull requests someone reviews. **The single biggest maturity jump available to you.**
2. **Turn on SSM session logging.** You already get CloudTrail. Now pipe full session transcripts to S3 or CloudWatch: every keystroke, on every box, attributed and immutable. This is *genuinely* not achievable with SSH without significant extra machinery — take the free win.
3. **Scope down the IAM policies.** Replace `AdministratorAccess` with something real. Use the tag-scoped `ssm:StartSession` policy from §11.2 for humans.
4. **Kafka: 3 brokers, RF=3, `min.insync.replicas=2`.** One broker is not high availability. It's a single point of data loss.
5. **Enable Kafka SASL_SSL + ACLs.** PLAINTEXT is only acceptable because of the security-group lockdown. Belt *and* braces.
6. **NiFi Registry.** Version-control your flows. Clicking config into prod with no rollback is how outages happen.
7. **Bake AMIs with Packer.** Faster boots, reproducible builds, and it lets you **delete the NAT Gateway** — a real $33/month saving and one less moving part.
8. **Consider deleting the ALB.** With SSM port-forwarding you can reach NiFi's UI on `localhost` with **no public endpoint at all**. That's another $16/month *and* a smaller attack surface.
9. **Observability.** CloudWatch alarms on ALB 5xx, Kafka consumer lag, disk usage. You cannot operate what you cannot see.
10. **Backups.** EBS snapshots on a schedule. S3 versioning is already on. **Test a restore** — an untested backup is not a backup.
11. **Decide your break-glass path.** SSM ties you to AWS's control plane. If the SSM API has a bad day, you cannot reach your instances. Some teams keep an emergency SG rule or a sealed key pair for this. **Make that choice deliberately**, not by accident.

But you have the foundation. And more importantly, you understand *why* every piece is there:

- Why the SSM Agent **dials out**, and why that means zero inbound rules — a structurally different thing from "SSH with a good firewall"
- Why **all three** SSM endpoints are required, and why everyone forgets `ec2messages`
- Why Ansible-over-SSM needs an **S3 bucket**, and why the **target** — not the controller — needs permission to read it
- Why Kafka's security group names **exactly two badges** and not a single IP address
- Why NiFi has **no public IP**, and why that's stronger than any firewall rule
- Why the AWS credentials field in NiFi is **blank** — and why blank is the *most secure possible value*
- Why `terraform plan` is the most important command you will ever type
- Why `advertised.listeners` will be the first thing you check the next time a Kafka client hangs

That understanding is the actual deliverable. The infrastructure is just what fell out of it.
