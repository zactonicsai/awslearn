# Build Your Own Cloud Control Room

### An AWS Command Node with Terraform + Ansible, a NiFi Server, a Kafka Server, and a Python App That Ties Them Together

---

## Table of Contents

1. [What Are We Building? (The Big Picture)](#1-what-are-we-building-the-big-picture)
2. [Background: The Vocabulary You Need](#2-background-the-vocabulary-you-need)
3. [Before You Start: The Checklist](#3-before-you-start-the-checklist)
4. [PART ONE — Step-by-Step: Build the Command Node](#4-part-one--step-by-step-build-the-command-node)
5. [PART TWO — The Big Terraform Build (VPC, NiFi, Kafka, ALB, S3)](#5-part-two--the-big-terraform-build)
6. [PART THREE — Ansible Configures the Servers](#6-part-three--ansible-configures-the-servers)
7. [PART FOUR — The Python App and the Consumer](#7-part-four--the-python-app-and-the-consumer)
8. [Running the Whole Thing End to End](#8-running-the-whole-thing-end-to-end)
9. [Deep Background: How Every Piece Actually Works](#9-deep-background-how-every-piece-actually-works)
10. [Best Practices (And Why They Matter)](#10-best-practices-and-why-they-matter)
11. [Pros and Cons of Every Choice We Made](#11-pros-and-cons-of-every-choice-we-made)
12. [Troubleshooting: When Things Break](#12-troubleshooting-when-things-break)
13. [Cost Estimate and How to Turn It All Off](#13-cost-estimate-and-how-to-turn-it-all-off)
14. [Glossary](#14-glossary)

---

## 1. What Are We Building? (The Big Picture)

Imagine you're the director of a school play. You don't build the sets yourself. You don't sew the costumes. You sit in one chair with one clipboard, and from that chair you tell everyone else what to do. The set crew builds. The costume crew sews. You just direct.

That chair is what we're building first. In cloud computing we call it a **command node** (some people call it a "bastion host," a "jump box," or a "control node" — they mean roughly the same thing). It is one small computer that lives inside Amazon's data center, and from it you will command Amazon to build everything else.

Here is the whole system we are going to construct:

```
                          YOUR LAPTOP
                               |
                          (SSH over the internet)
                               |
                               v
    +==========================================================+
    |                    AWS CLOUD (us-east-1)                 |
    |                                                          |
    |   +--------------------------------------------------+   |
    |   |  COMMAND VPC (10.0.0.0/16)                       |   |
    |   |                                                  |   |
    |   |   +------------------+                           |   |
    |   |   |  COMMAND NODE    |  <-- YOU BUILD THIS FIRST |   |
    |   |   |  (t3.small)      |      by hand, one time    |   |
    |   |   |                  |                           |   |
    |   |   |  - Terraform     |      This is the chair.   |   |
    |   |   |  - Ansible       |      Everything else is   |   |
    |   |   |  - AWS CLI       |      built FROM here.     |   |
    |   |   |  - Python 3      |                           |   |
    |   |   +--------|---------+                           |   |
    |   |            |                                     |   |
    |   +------------|-------------------------------------+   |
    |                |                                         |
    |                | (VPC Peering - a private tunnel)        |
    |                |                                         |
    |   +------------|-------------------------------------+   |
    |   |  DATA VPC (10.20.0.0/16)   <-- TERRAFORM BUILDS  |   |
    |   |            |                    ALL OF THIS      |   |
    |   |            v                                     |   |
    |   |   PUBLIC SUBNETS (two, in two different AZs)     |   |
    |   |   +-------------------------------------------+  |   |
    |   |   |  APPLICATION LOAD BALANCER (ALB)          |  |   |
    |   |   |  nifi.yourdomain.com  --> HTTPS :443      |  |   |
    |   |   +---------------------|---------------------+  |   |
    |   |                         |                        |   |
    |   |   PRIVATE SUBNETS       |  (two, two AZs)        |   |
    |   |   +---------------------v---------------------+  |   |
    |   |   |  NIFI SERVER (t3.large)                   |  |   |
    |   |   |  - Apache NiFi 2.x                        |  |   |
    |   |   |  - Listens on :8443                       |  |   |
    |   |   |  - Has an IAM Role --> can read S3        |  |   |
    |   |   |  - Runs an HTTP listener on :9999         |  |   |
    |   |   +----|---------------------------|----------+  |   |
    |   |        |                           |             |   |
    |   |        | (port 9092)               | (S3 traffic)|   |
    |   |        v                           v             |   |
    |   |   +--------------------+     +------------------+|   |
    |   |   | KAFKA SERVER       |     |  VPC ENDPOINT    ||   |
    |   |   | (t3.medium)        |     |  (Gateway, free) ||   |
    |   |   | - Kafka 3.x KRaft  |     +--------|---------+|   |
    |   |   | - Listens on :9092 |              |          |   |
    |   |   | ONLY accepts from: |              |          |   |
    |   |   |  * NiFi SG         |              |          |   |
    |   |   |  * Command Node SG |              |          |   |
    |   |   +--------------------+              |          |   |
    |   +--------------------------------------|----------+   |
    |                                          v              |
    |                              +------------------------+ |
    |                              |  S3 BUCKET             | |
    |                              |  your-nifi-drop-bucket | |
    |                              |  (holds .txt files)    | |
    |                              +------------------------+ |
    +==========================================================+
```

### The story, told as a story

1. You build **one** small server by hand. This is the Command Node. It's the only thing you ever touch manually.
2. On that server you install **Terraform** (the construction crew) and **Ansible** (the interior decorator).
3. You write a Terraform file that describes the *entire rest of the system* — every network, every firewall rule, every server.
4. You type `terraform apply`. Terraform calls Amazon's API about 40 times and builds it all. This takes about 8 minutes.
5. You type `ansible-playbook site.yml`. Ansible logs into the new servers and installs NiFi and Kafka on them.
6. You run a small Python program. It sends a message to NiFi saying *"go fetch the text files out of S3 and put them into Kafka."*
7. You run a second Python program — a **consumer** — which sits and watches Kafka. Every time a file's contents show up, it prints them to the screen, like the Unix `cat` command.

That's it. That's the whole thing. Now let's understand what each of those words means.

---

## 2. Background: The Vocabulary You Need

Read this section even if you think you know it. The rest of the tutorial assumes every one of these words.

### 2.1 What is AWS, really?

**AWS** (Amazon Web Services) is a company that owns enormous buildings full of computers. You rent those computers by the hour. That's genuinely the whole business model.

The important thing to understand is that you don't rent them by walking in the door — you rent them by sending a **message over the internet**, called an **API call**. An API call is like a text message with a very strict format. You send: *"Please create one computer, medium size, running Ubuntu Linux, in Virginia."* AWS sends back: *"Done. It's at IP address 54.x.x.x."*

Everything in this tutorial — Terraform, the AWS CLI, the web console — is just a different way of sending those exact same API messages.

### 2.2 What is EC2?

**EC2** stands for *Elastic Compute Cloud*. It's the AWS service that rents you virtual computers. One rented computer is called an **EC2 instance**.

"Virtual" means it isn't a whole physical machine. Amazon has one giant physical server and slices it into many virtual ones, the way you'd slice one pizza into eight pieces. Each slice thinks it's a whole computer. It has its own memory, its own hard drive, its own operating system.

**Instance types** are the sizes of the slices. They look like `t3.small` or `m5.xlarge`:

| Instance Type | vCPUs | RAM   | Rough cost/month (on-demand, us-east-1) | Good for |
|---|---|---|---|---|
| `t3.micro`  | 2 | 1 GB  | ~$7.50  | Tiny experiments (too small for us) |
| `t3.small`  | 2 | 2 GB  | ~$15    | **Our Command Node** |
| `t3.medium` | 2 | 4 GB  | ~$30    | **Our Kafka server** |
| `t3.large`  | 2 | 8 GB  | ~$60    | **Our NiFi server** (NiFi is a Java app; it's hungry) |

The `t` family is *burstable*. It's cheap because it assumes you're idle most of the time, and it gives you "CPU credits" you can spend on short bursts of activity. That's perfect for a command node (idle 99% of the time) and acceptable for a demo NiFi. It is **not** appropriate for production Kafka — we'll discuss why in the pros/cons section.

### 2.3 What is a VPC?

A **VPC** (*Virtual Private Cloud*) is your own private network inside AWS. Think of AWS as a giant apartment building and a VPC as your apartment. Other tenants exist, but they can't see into your rooms, and you can't see into theirs.

A VPC has an address range, written in **CIDR notation**, like `10.20.0.0/16`.

CIDR notation confuses everyone at first, so here's the trick. An IP address is four numbers, each 0–255, like `10.20.3.47`. The `/16` at the end means **"the first 16 bits are locked; the rest are yours to assign."** Each number is 8 bits. So:

```
10.20.0.0/16
^^ ^^ <-- first 16 bits = first two numbers = LOCKED
      ^^^^ <-- last 16 bits = last two numbers = FREE

So this VPC contains every address from 10.20.0.0 to 10.20.255.255
That's 256 x 256 = 65,536 addresses.
```

A `/24` locks the first three numbers, leaving 256 addresses (`10.20.1.0` through `10.20.1.255`). Smaller number after the slash = bigger network. It's backwards from what feels natural. Everyone trips on this.

### 2.4 What is a subnet?

A **subnet** is a room inside your apartment. You slice your VPC's address range into smaller pieces. Every EC2 instance lives in exactly one subnet.

There are two kinds, and the difference is the single most important security concept in this tutorial:

| | **Public Subnet** | **Private Subnet** |
|---|---|---|
| Has a route to an Internet Gateway? | **Yes** | **No** |
| Can a stranger on the internet reach it? | Yes (if firewall allows) | **No. Never. Physically impossible.** |
| Can it reach out to the internet? | Yes | Only via a NAT Gateway |
| What we put here | The Load Balancer | NiFi, Kafka |

Read that table again. A private subnet isn't "protected by a strong firewall." It's that **there is no road**. A packet from the internet has no possible path to reach it. Even a misconfigured firewall can't expose it. This is called *defense in depth* — we don't rely on one lock, we remove the door.

### 2.5 Availability Zones (and why we need two of everything)

An **Availability Zone** (AZ) is one physical data center building. A **Region** (like `us-east-1`, Northern Virginia) contains several AZs, named `us-east-1a`, `us-east-1b`, and so on. They are miles apart, on different power grids.

Why do you care? Because **an Application Load Balancer legally refuses to exist in only one AZ.** AWS requires you to give it subnets in at least two AZs. This is AWS forcing you to be resilient. If a backhoe cuts the fiber to `us-east-1a`, your load balancer keeps working out of `us-east-1b`.

This is why our Terraform creates **two** public subnets and **two** private subnets, even though we only run one NiFi server. The extra subnets cost nothing (subnets are free), and the ALB won't start without them.

### 2.6 Security Groups — the heart of this tutorial

A **Security Group** (SG) is a firewall that wraps around an EC2 instance (technically around its network card).

Here are the four rules that make security groups behave the way they do:

1. **Default deny.** A brand new SG blocks everything inbound. You must explicitly allow.
2. **Allow-only.** There is no such thing as a "deny" rule in a security group. You can only add permissions, never subtract them.
3. **Stateful.** If you allow traffic *in*, the reply is automatically allowed *out*. You never write a rule for the reply. (This is different from a Network ACL, which is stateless and does require you to write both directions.)
4. **They can reference each other.** *This is the magic trick.*

That fourth point is what this whole tutorial is built around, so let's make it concrete.

The naive way to lock down Kafka looks like this:

```hcl
# THE BAD WAY - don't do this
ingress {
  from_port   = 9092
  to_port     = 9092
  protocol    = "tcp"
  cidr_blocks = ["10.20.11.47/32"]   # <-- NiFi's IP address, hardcoded
}
```

This works... until NiFi reboots and gets a new IP. Then Kafka silently stops accepting connections and you spend an afternoon confused.

The correct way references the *security group itself*, not an address:

```hcl
# THE GOOD WAY
ingress {
  from_port       = 9092
  to_port         = 9092
  protocol        = "tcp"
  security_groups = [aws_security_group.nifi.id]   # <-- "whoever wears the NiFi badge"
}
```

Think of it as a **badge system**. The rule doesn't say *"let in the person standing at desk 47."* It says *"let in anyone wearing the NiFi badge."* NiFi can move desks, get a new IP, be replaced by a brand new server — as long as the new server wears the NiFi badge, it gets in. Nobody else does.

Our Kafka security group will have exactly **two** inbound rules on port 9092:
- Anyone wearing the **NiFi badge**
- Anyone wearing the **Command Node badge**

And that's all. The entire rest of the internet, the entire rest of the VPC, every other server — blocked. This directly satisfies the requirement: *"only allow access from the EC2 command server and NiFi."*

### 2.7 What is a Load Balancer?

A **Load Balancer** is a doorman. It stands at the front door with a public address, takes requests from the outside world, and passes them to servers hiding safely in the back.

We use an **ALB** (*Application Load Balancer*), which understands HTTP and HTTPS. It gives us four things at once:

1. **A public front door** for NiFi, even though NiFi sits in a private subnet with no internet route. The ALB is the *only* thing exposed.
2. **HTTPS termination.** The ALB holds the TLS certificate. Browsers see a valid padlock. AWS gives you the certificate free via **ACM** (AWS Certificate Manager).
3. **Health checks.** It pings NiFi every 30 seconds. If NiFi dies, the ALB stops sending it traffic and returns a clean 503 instead of hanging.
4. **A stable DNS name** you point your domain at.

The ALB lives in the **public** subnets. NiFi lives in the **private** subnets. The ALB reaches backward into the private subnet to talk to NiFi. Traffic only ever flows *in* through the doorman.

### 2.8 What is Terraform?

**Terraform** turns a text file into cloud infrastructure.

You write a file describing what you *want*:

```hcl
resource "aws_instance" "nifi" {
  instance_type = "t3.large"
  ami           = "ami-0abcdef1234567890"
}
```

You run `terraform apply`. Terraform compares *what you want* against *what currently exists*, works out the difference, and makes the necessary API calls to close the gap.

This is called **declarative** infrastructure, and it's the opposite of how people used to work.

- **Imperative** = a recipe. "Click here. Then click there. Then type this." If you run it twice you get two servers.
- **Declarative** = a photograph of the finished cake. "There should be one t3.large NiFi server." Run it twice, and the second time Terraform says *"there already is one, nothing to do."*

That property — running it twice is the same as running it once — is called **idempotency**, and it is the single most valuable property in all of infrastructure automation. It means you can re-run your build anytime without fear.

Terraform remembers what it built in a file called **state** (`terraform.tfstate`). The state file is a JSON map of *"the thing I called `aws_instance.nifi` is really instance `i-0abc123`."* Guard this file. If you lose it, Terraform forgets it owns your infrastructure and will happily build a second copy of everything. We'll store it in S3 with locking, which is the professional standard.

### 2.9 What is Ansible?

Terraform builds the *empty house*. Ansible **furnishes** it.

Terraform is excellent at "make me a server" and terrible at "install Java on that server." Ansible is the reverse. So we use both, each for what it's good at.

Ansible works by SSH-ing into your servers and running commands. It needs **no agent** installed on the target — this is its killer feature. If you can SSH to a box, you can Ansible to it.

You write a **playbook** (a YAML file) that lists **tasks**:

```yaml
- name: Install Java 21
  apt:
    name: openjdk-21-jdk
    state: present    # <-- "present", not "install"
```

Notice `state: present`. That's declarative again. It doesn't say "run apt install." It says "Java should be there." If Java is already there, Ansible does nothing and reports `ok`. If it's missing, Ansible installs it and reports `changed`. Idempotent, just like Terraform.

### 2.10 What is Apache NiFi?

**NiFi** is a data-movement tool with a drag-and-drop web interface. You build a **flow** by dragging boxes (called **processors**) onto a canvas and connecting them with arrows.

Each processor does one job:
- `ListS3` — look in an S3 bucket, emit one record per file found
- `FetchS3Object` — given a record, download that file's actual bytes
- `PublishKafka` — take the bytes and publish them to a Kafka topic
- `HandleHttpRequest` — sit and listen on a port for someone to poke it

Data travels through the flow in packages called **FlowFiles**. A FlowFile is *content* (the bytes) plus *attributes* (metadata like filename, size, S3 key). Think of it as a manila envelope: the document is inside, and the label on the front is the attributes.

NiFi's superpower is **provenance** — it records every single thing that ever happened to every FlowFile. You can click any file and see its complete life story. That's why regulated industries (banks, hospitals) love it.

### 2.11 What is Apache Kafka?

**Kafka** is a message queue — but the better metaphor is a **shared logbook**.

Imagine a notebook nailed to the wall of a factory. Anyone can write a new line at the bottom. Nobody can erase or edit. Readers each keep a bookmark of "the last line I read."

That's Kafka:

- A **topic** is one notebook. Ours will be called `nifi-s3-files`.
- A **producer** writes new lines. NiFi will be our producer.
- A **consumer** reads lines and moves its bookmark forward. Our Python script will be our consumer.
- The bookmark is called an **offset**.

The key insight: **the reader's bookmark is the reader's problem.** Kafka doesn't delete a message when you read it, and it doesn't care if you're slow. Ten different consumers can read the same topic at their own pace with their own bookmarks. If your consumer crashes, you restart it and it picks up exactly where its bookmark was. Nothing is lost.

Modern Kafka (3.3+) runs in **KRaft mode**, which means it manages itself. Older tutorials will tell you to also install **ZooKeeper**, a separate coordination service. **You do not need ZooKeeper anymore.** ZooKeeper was fully removed in Kafka 4.0. Any tutorial telling you to install it is out of date, and we will not.

### 2.12 What is S3?

**S3** (*Simple Storage Service*) is infinite file storage. You put files ("objects") into a **bucket**. Each object has a **key** (its path, like `incoming/report.txt`).

S3 is not a hard drive. You cannot open a file, seek to byte 5,000, and overwrite four bytes. You can only PUT a whole object or GET a whole object. That constraint is what lets it scale infinitely and cost almost nothing (~$0.023 per GB per month).

Bucket names are **globally unique across every AWS customer on earth.** If someone in Norway has `my-bucket`, you can't have it. So we append random characters.

### 2.13 What is IAM? (And the one rule you must never break)

**IAM** (*Identity and Access Management*) controls who can do what.

The critical concept is the **IAM Role**. A role is a set of permissions that a *machine* can wear, like a uniform. You attach a role to an EC2 instance, and any program running on that instance automatically inherits those permissions.

Here is the rule, and it is the one rule in this entire tutorial that you must never, ever break:

> ### 🚨 **NEVER put AWS access keys on an EC2 instance. Ever. Use an IAM Role instead.**

Why does this matter so much?

An access key is a permanent username and password for your AWS account. If you write one into a file on a server, and that server is ever compromised — or that file ever gets committed to GitHub — an attacker now owns your entire AWS account. They will spin up thousands of GPU instances to mine cryptocurrency. People have woken up to $100,000 bills. This happens **constantly**; bots scan every public GitHub commit within seconds looking for exactly this.

An IAM Role has none of these problems:
- The credentials it hands out are **temporary** (they expire in a few hours)
- They are **rotated automatically** by AWS
- They are **never written to disk** — they're fetched from a special address (`169.254.169.254`) that only exists inside the instance
- They can be **revoked instantly** by detaching the role
- If the instance is destroyed, they die with it

Every AWS SDK — boto3, the AWS CLI, Terraform, the Java SDK — automatically checks for a role. You literally write **zero lines of code** to use one. That's why our Command Node and NiFi will both get roles, and no key will ever touch a disk.

---

## 3. Before You Start: The Checklist

Work through this list. Don't skip it — every item here will bite you later if it's missing.

### 3.1 What you need

| Item | Why | How to check |
|---|---|---|
| An AWS account | Everything lives here | Log into console.aws.amazon.com |
| A credit card on that account | AWS charges for this | Billing dashboard |
| A domain name you control | For `nifi.yourdomain.com` | You bought it somewhere |
| A terminal | To SSH from | macOS/Linux: built in. Windows: use PowerShell or WSL2 |
| ~$100/month budget | See section 13 | — |
| About 2 hours | Realistically 3 for a first-timer | — |

### 3.2 Set a billing alarm FIRST

Before you create a single resource, do this. It takes 90 seconds and it is the difference between a $90 bill and a $9,000 bill.

1. Go to the AWS Console → search "Budgets" → **Budgets**
2. **Create budget** → **Use a template** → **Monthly cost budget**
3. Set the amount to something that would alarm you. **$150** is sensible here.
4. Enter your email.
5. Create.

Now if something runs away, you get an email instead of a surprise.

### 3.3 Create an IAM user for yourself (not root!)

Your **root user** is the email address you signed up with. It can do literally anything, including close the account and cancel your billing. **Never use it for daily work.** Log in with it once, create a normal user, and then don't touch root again except for billing changes.

1. Console → **IAM** → **Users** → **Create user**
2. Name: `admin-yourname`
3. Check **"Provide user access to the AWS Management Console"**
4. **Attach policies directly** → check `AdministratorAccess`
   - *(In a real company you'd scope this down. For learning on your own account, admin is fine.)*
5. Create user. **Save the sign-in URL and password.**
6. Sign out of root. Sign back in as `admin-yourname`.
7. Console → IAM → Users → your user → **Security credentials** → **Enable MFA**. Do it. Use your phone's authenticator app. It takes two minutes.

### 3.4 Create an SSH key pair

An **SSH key pair** is two matching files. The **public key** is a padlock you can hand out freely. The **private key** is the only key that opens it. AWS puts the padlock on your server; you keep the key.

**Never share, email, or commit the private key. Anyone holding it can log into your servers.**

Run this on your laptop:

```bash
# Make a folder for AWS keys if you don't have one
mkdir -p ~/.ssh

# Generate a modern ED25519 key pair
ssh-keygen -t ed25519 -C "aws-command-node" -f ~/.ssh/aws-command-node

# When it asks for a passphrase: TYPE ONE. This encrypts the key on your disk,
# so a stolen laptop isn't an instant breach. Remember it.

# Lock the file down. SSH will REFUSE to use a key other users can read.
chmod 600 ~/.ssh/aws-command-node
chmod 644 ~/.ssh/aws-command-node.pub

# Print the PUBLIC key. You'll paste this into AWS in a moment.
cat ~/.ssh/aws-command-node.pub
```

You'll see something like:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx8k... aws-command-node
```

Copy that entire line, including the `ssh-ed25519` at the start.

> **Why ED25519 and not RSA?** ED25519 is a newer elliptic-curve algorithm. It's faster, the keys are far shorter, and it's considered more secure than 2048-bit RSA. It's been supported by AWS and every modern SSH client for years. There is no reason to generate RSA keys in 2026 unless you're talking to some ancient appliance.

### 3.5 Import your public key into AWS

1. Console → **EC2** → make sure the region in the top-right says **US East (N. Virginia) us-east-1**. *(If you use a different region, use it consistently everywhere in this tutorial.)*
2. Left sidebar → **Key Pairs** → **Actions** → **Import key pair**
3. Name: `aws-command-node`
4. Paste the public key line you copied.
5. **Import key pair**

Done. AWS now has your padlock.

### 3.6 Find your own public IP

You need this to write a firewall rule that lets *only you* SSH in.

```bash
curl -s https://checkip.amazonaws.com
```

That prints something like `203.0.113.45`. Write it down. In firewall rules you'll express it as `203.0.113.45/32` — the `/32` means "exactly this one address, nothing else."

> ⚠️ **Home internet IPs change.** Your ISP will hand you a new one eventually (often after a router reboot). When you suddenly can't SSH in one morning, this is almost always why. Re-run the command and update the rule. This is normal and expected.

---

## 4. PART ONE — Step-by-Step: Build the Command Node

**This is the one thing you build by hand.** Everything after this is automated. Follow along exactly.

### Step 1 — Launch the instance

1. Console → **EC2** → **Instances** → **Launch instances**

2. **Name:** `command-node`

3. **Application and OS Images:**
   - Search for **Ubuntu**
   - Select **Ubuntu Server 24.04 LTS (HVM), SSD Volume Type**
   - Architecture: **64-bit (x86)**
   - *(24.04 is the current Long Term Support release, supported until 2029. LTS means Ubuntu promises security patches for years. Always pick LTS for infrastructure.)*

4. **Instance type:** `t3.small`
   - *(Why not `t3.micro` at half the price? Because 1 GB of RAM is genuinely not enough. Terraform providers and Ansible's Python interpreter will thrash and occasionally get killed by the kernel's OOM killer. The extra $7/month buys you sanity.)*

5. **Key pair (login):** select `aws-command-node`

6. **Network settings** → click **Edit**:
   - **VPC:** leave as the **default VPC** (AWS gave you one free)
   - **Subnet:** pick any, or leave as "No preference"
   - **Auto-assign public IP:** **Enable** ← *critical. Without this you cannot SSH in.*
   - **Firewall (security groups):** **Create security group**
     - Name: `command-node-sg`
     - Description: `SSH from my IP only`
     - **Inbound rules → Add rule:**
       - Type: **SSH**
       - Port: `22`
       - Source type: **My IP** ← *AWS auto-fills your current IP. Use this, not "Anywhere."*
     
   > 🚨 **Do NOT set the SSH source to `0.0.0.0/0` ("Anywhere").** That opens port 22 to the entire planet. Automated bots find it within *minutes* — genuinely, minutes — and begin brute-forcing passwords 24/7. Your logs will fill with thousands of attempts from Russia, China, and Brazil. Set it to your IP.

7. **Configure storage:** `30 GiB`, `gp3`
   - *(The 8 GB default fills up fast once you have Terraform providers, Ansible collections, and a NiFi tarball cached. `gp3` is the modern SSD type — cheaper AND faster than the old `gp2`. Always pick `gp3`.)*

8. Click **Launch instance**.

Wait ~60 seconds. Refresh the instance list until **Status check** shows **2/2 checks passed**.

### Step 2 — Create the IAM role for the Command Node

The Command Node needs permission to build AWS infrastructure. Remember: **role, not keys.**

1. Console → **IAM** → **Roles** → **Create role**
2. **Trusted entity type:** **AWS service**
3. **Use case:** **EC2** → Next
4. **Permissions:** search and check **`AdministratorAccess`**
   - *(Yes, this is broad. Terraform genuinely needs to create VPCs, IAM roles, security groups, load balancers, S3 buckets, and EC2 instances — a huge surface. Section 10 explains how to scope this down properly for a real company. For a personal learning account, admin is the pragmatic choice.)*
5. Next → **Role name:** `command-node-role`
6. **Create role**

### Step 3 — Attach the role to the instance

1. Console → **EC2** → **Instances** → select `command-node`
2. **Actions** → **Security** → **Modify IAM role**
3. Choose `command-node-role` → **Update IAM role**

The instance now silently possesses AWS superpowers, with zero credentials on disk. Nothing to leak.

### Step 4 — SSH in

Copy the **Public IPv4 address** from the console (something like `54.211.87.3`).

```bash
ssh -i ~/.ssh/aws-command-node ubuntu@54.211.87.3
```

- `-i` = "identity file," i.e. which private key to present
- `ubuntu` = the default username on Ubuntu AMIs. (It's `ec2-user` on Amazon Linux, `admin` on Debian. Getting this wrong gives you `Permission denied (publickey)` — a confusing error that makes you think your key is broken when actually your *username* is wrong.)

First connection asks:

```
The authenticity of host '54.211.87.3' can't be established.
ED25519 key fingerprint is SHA256:xxxxx.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Type `yes`. *(This is SSH telling you it's never seen this server before and is memorizing its fingerprint, so it can warn you if the server is ever swapped out under you.)*

You should land at:

```
ubuntu@ip-172-31-25-10:~$
```

**You are inside the machine.** Everything from here happens on the Command Node, not your laptop.

### Step 5 — Verify the IAM role is working

Before installing anything, prove the role works. This is the single best sanity check in AWS.

```bash
# The AWS CLI ships preinstalled on Ubuntu's AWS AMI. Ask it: "who am I?"
aws sts get-caller-identity
```

You should see:

```json
{
    "UserId": "AROA...:i-0abc123def456",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/command-node-role/i-0abc123def456"
}
```

Look at that `Arn`. It says **`assumed-role/command-node-role`**. That is AWS confirming: *"this machine is wearing the command-node-role uniform."* No keys were involved. Nothing is on disk. It just works.

> **If you instead get `Unable to locate credentials`:** the role isn't attached. Go back to Step 3. Sometimes it takes 30 seconds to propagate — wait and retry once before panicking.

### Step 6 — Update the system

```bash
sudo apt update && sudo apt upgrade -y
```

- `apt update` — refresh the catalog of available packages (doesn't install anything)
- `apt upgrade -y` — actually install the updates. `-y` means "yes to all prompts"
- `sudo` — "do this as the superuser." Installing system software requires it.

If you get a purple screen asking about restarting services, hit Tab to `<Ok>` and Enter. If it asks about a modified config file, keep the local version (the default).

### Step 7 — Install the base tools

```bash
sudo apt install -y \
  curl \
  wget \
  unzip \
  git \
  jq \
  python3-pip \
  python3-venv \
  gnupg \
  software-properties-common
```

What each one is for:

| Package | Purpose |
|---|---|
| `curl`, `wget` | Download files from the internet |
| `unzip` | Extract .zip archives |
| `git` | Version control — you will store your Terraform in Git |
| `jq` | Parse JSON on the command line. AWS returns JSON everywhere. This tool is *invaluable*. |
| `python3-pip` | Python's package installer |
| `python3-venv` | Isolated Python environments (Ubuntu 24.04 *requires* these — see Step 11) |
| `gnupg` | Verifies cryptographic signatures on downloaded packages |
| `software-properties-common` | Provides `add-apt-repository` |

### Step 8 — Install Terraform

We install from HashiCorp's **official APT repository** rather than downloading a zip. This means `apt upgrade` will keep Terraform patched forever, automatically. Downloading a zip means you'll be running a 2-year-old Terraform and won't realize it.

```bash
# 1. Download HashiCorp's GPG signing key and store it in the modern keyring location
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# 2. Add their repository, telling apt to only trust packages signed by that key
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# 3. Refresh and install
sudo apt update && sudo apt install -y terraform

# 4. Verify
terraform version
```

Expected output (your version will be 1.9 or newer):

```
Terraform v1.9.8
on linux_amd64
```

> **Why the GPG dance?** Without it, `apt` would download software over the network with no way to know it wasn't tampered with in transit. The signing key lets apt cryptographically verify that the package genuinely came from HashiCorp and wasn't modified. This is not optional paranoia — this is how you avoid supply-chain attacks. Note we use `signed-by=` and a file in `/usr/share/keyrings/` rather than the old `apt-key add` command, which is **deprecated and insecure** because it trusted that key for *every* repository, not just HashiCorp's.

Enable tab-completion — you'll use it constantly:

```bash
terraform -install-autocomplete
source ~/.bashrc
```

### Step 9 — Install Ansible

```bash
sudo apt install -y ansible
ansible --version
```

You should see version 2.16 or newer, and it should report a Python 3.12 interpreter.

Now install the AWS collection, which gives Ansible modules that understand EC2, S3, and friends:

```bash
ansible-galaxy collection install amazon.aws community.general
```

Ansible needs `boto3` (the AWS Python library) to talk to AWS. On Ubuntu 24.04 this is best done as a system package:

```bash
sudo apt install -y python3-boto3 python3-botocore
```

### Step 10 — Verify the AWS CLI

It's preinstalled, but confirm the version — v1 is ancient and you want v2:

```bash
aws --version
```

If you see `aws-cli/1.x`, install v2 properly:

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip
aws --version   # should now say aws-cli/2.x
```

Set the default region so you stop having to type `--region` on every command:

```bash
aws configure set region us-east-1
aws configure set output json
```

> **Notice what we did NOT do:** we did not run plain `aws configure` and paste in an access key. We only set *region* and *output format*. The credentials come from the IAM role, invisibly. That's the whole point.

### Step 11 — Set up Python properly (this trips up everyone)

Ubuntu 24.04 enforces **PEP 668**. If you try `pip install kafka-python`, you get:

```
error: externally-managed-environment
× This environment is externally managed
```

This is Ubuntu protecting itself. System Python is used by system tools (`apt` itself is written in Python!). If you `pip install` a package that upgrades a shared library, you can genuinely break your ability to install *anything*, including the thing that would fix it. People have bricked servers this way.

The correct fix is a **virtual environment** — an isolated Python sandbox with its own package folder.

```bash
# Create a project folder
mkdir -p ~/nifi-kafka-app && cd ~/nifi-kafka-app

# Create a venv named .venv
python3 -m venv .venv

# Activate it. Your prompt now shows (.venv)
source .venv/bin/activate

# Install our libraries INSIDE the sandbox
pip install --upgrade pip
pip install requests kafka-python boto3

# Verify
python -c "import kafka, requests, boto3; print('All libraries OK')"
```

You should see `All libraries OK`.

To leave the sandbox: `deactivate`. To re-enter later: `source ~/nifi-kafka-app/.venv/bin/activate`.

> 🚨 **Never use `pip install --break-system-packages`** to force past this error, even though the error message suggests it. The flag is named "break system packages" because that is literally what it does. Use a venv.

### Step 12 — Create the S3 backend for Terraform state

Terraform's state file is precious. Keeping it on the Command Node's local disk means one accidental `rm` or one terminated instance and you've lost the map to your entire infrastructure. Store it in S3.

```bash
# Bucket names must be globally unique. Generate a random suffix.
SUFFIX=$(openssl rand -hex 4)
BUCKET="tfstate-cmdnode-${SUFFIX}"
echo "Your bucket: $BUCKET"
echo "$BUCKET" > ~/tf-bucket-name.txt    # save it, you'll need it in a minute

# Create the bucket
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1

# Turn on versioning. Every save keeps the old copy.
# This means you can ALWAYS roll back a corrupted state file. Do not skip this.
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Encrypt everything at rest
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block ALL public access. State files contain secrets. This must never be public.
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "State bucket ready: $BUCKET"
```

> **Note on state locking:** Older tutorials tell you to create a DynamoDB table for locking. As of Terraform **1.10+**, S3 has **native state locking** built in via the `use_lockfile = true` setting. DynamoDB is no longer required and is deprecated for this purpose. We'll use the modern approach. (Locking prevents two people running `terraform apply` at the same time and corrupting the state.)

### Step 13 — Configure Git

You will store your Terraform code in Git. Set your identity now:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
```

### Step 14 — Final verification

Run this to confirm everything landed:

```bash
echo "=== Command Node Status ==="
echo "Terraform : $(terraform version | head -1)"
echo "Ansible   : $(ansible --version | head -1)"
echo "AWS CLI   : $(aws --version)"
echo "Python    : $(python3 --version)"
echo "Git       : $(git --version)"
echo "jq        : $(jq --version)"
echo ""
echo "=== IAM Identity (should say 'assumed-role') ==="
aws sts get-caller-identity --query Arn --output text
echo ""
echo "=== State bucket ==="
cat ~/tf-bucket-name.txt
```

If every line prints a version and the ARN contains `assumed-role/command-node-role`, **your Command Node is complete.** 🎉

You now have a chair to direct from.

### Step 15 — Note the Command Node's Security Group ID

Terraform is going to need this so it can write the firewall rule that says "let the Command Node talk to Kafka."

```bash
# Ask the instance metadata service who we are, then look up our own security group.
# IMDSv2 requires a token first (this is a security improvement over IMDSv1).
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "Instance ID: $INSTANCE_ID"

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{SG:SecurityGroups[0].GroupId,VPC:VpcId,CIDR:PrivateIpAddress}' \
  --output table
```

Copy the `SG` value (looks like `sg-0a1b2c3d4e5f67890`) and the `VPC` value. **Write them down.** You'll paste them into Terraform in the next section.

> **What is `169.254.169.254`?** It's the **Instance Metadata Service** — a magic address that only exists *inside* an EC2 instance. From there, an instance can ask questions about itself: its ID, its region, its IP, and critically, its **temporary IAM role credentials**. This is exactly how the "no keys on disk" magic works. The AWS SDK quietly curls this address, gets a temporary credential, and uses it. The `TOKEN` step is **IMDSv2**, which requires a PUT request first — this was added specifically to defeat SSRF attacks where a tricked web app could be made to fetch credentials from this address. Always use v2.
---

## 5. PART TWO — The Big Terraform Build

Now we describe the entire rest of the system in text, and let Terraform build it.

### 5.1 Set up the project folder

On the **Command Node**:

```bash
mkdir -p ~/infra && cd ~/infra
mkdir -p ansible/roles python-app
git init
```

We'll split the Terraform into several files. Terraform doesn't care about filenames — it reads *every* `.tf` file in the folder and mashes them together. The split is purely for human readability.

```
~/infra/
├── versions.tf      <- Terraform + provider versions, S3 backend
├── variables.tf     <- Every knob you can turn
├── network.tf       <- VPC, subnets, gateways, routes, peering
├── security.tf      <- ALL the security groups (the heart of it)
├── s3.tf            <- The bucket and its VPC endpoint
├── iam.tf           <- The NiFi instance role
├── compute.tf       <- The NiFi and Kafka EC2 instances
├── alb.tf           <- Load balancer, certificate, DNS
├── outputs.tf       <- What Terraform prints when it's done
└── terraform.tfvars <- YOUR actual values (git-ignored!)
```

### 5.2 Protect yourself from committing secrets

**Do this before you write a single line of code.** People leak AWS keys by committing them, and it costs them dearly.

```bash
cat > .gitignore <<'EOF'
# NEVER commit these
*.tfvars
*.tfvars.json
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
crash.log
*.pem
*.key
.venv/
__pycache__/
EOF

git add .gitignore && git commit -m "Add gitignore before anything else"
```

> **Why is `*.tfvars` ignored?** Because that file holds *your* values: your account details, your domain, potentially secrets. It's the one file that shouldn't be shared. Everything else (`.tf` files) is generic code that's safe to publish.

### 5.3 `versions.tf` — pin everything

```hcl
# versions.tf
# ------------------------------------------------------------------
# Pins Terraform + provider versions and configures remote state.
# Pinning matters: without it, a provider releases v6.0 with breaking
# changes overnight and your build spontaneously fails on Monday.
# ------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"   # allows 5.70 -> 5.99, blocks 6.0
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state in S3, with NATIVE locking (Terraform 1.10+).
  # No DynamoDB table needed anymore.
  backend "s3" {
    bucket       = "REPLACE_WITH_YOUR_BUCKET"   # from Step 12
    key          = "nifi-kafka/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true                          # <-- the modern way
  }
}

provider "aws" {
  region = var.aws_region

  # Tag EVERY resource automatically. Future-you will be grateful when
  # the bill arrives and you can filter by Project.
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

> **The `~>` operator** is the "pessimistic constraint." `~> 5.70` means *"at least 5.70, but don't you dare go to 6.x."* Major version bumps (5→6) are where breaking changes live. This one line prevents a whole class of 3am incidents.

### 5.4 `variables.tf` — every knob

```hcl
# variables.tf
# ------------------------------------------------------------------
# Variables are the "settings menu" of your infrastructure.
# Values come from terraform.tfvars.
# ------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to build in"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name, used as a prefix on every resource"
  type        = string
  default     = "nifi-platform"
}

variable "environment" {
  description = "dev / staging / prod"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Who owns this (for tags/billing)"
  type        = string
}

# ---------- NETWORK ----------

variable "vpc_cidr" {
  description = "Address range for the NEW data VPC"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be valid CIDR notation, e.g. 10.20.0.0/16"
  }
}

variable "public_subnet_cidrs" {
  description = "Two public subnets (required: ALB needs 2 AZs)"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "An ALB requires at least 2 subnets in 2 different AZs."
  }
}

variable "private_subnet_cidrs" {
  description = "Two private subnets (NiFi + Kafka live here)"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]
}

# ---------- COMMAND NODE (the box you're sitting on) ----------

variable "command_node_sg_id" {
  description = "Security Group ID of the Command Node. From Part One, Step 15."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.command_node_sg_id))
    error_message = "Must look like sg-0a1b2c3d4e5f67890"
  }
}

variable "command_node_vpc_id" {
  description = "VPC ID the Command Node lives in (usually your default VPC)"
  type        = string
}

variable "command_node_vpc_cidr" {
  description = "CIDR of the Command Node's VPC. Default VPC is usually 172.31.0.0/16"
  type        = string
  default     = "172.31.0.0/16"
}

# ---------- DOMAIN ----------

variable "domain_name" {
  description = "Your root domain, e.g. example.com"
  type        = string
}

variable "nifi_subdomain" {
  description = "Subdomain NiFi will live at"
  type        = string
  default     = "nifi"
}

variable "route53_zone_id" {
  description = "Route53 Hosted Zone ID for your domain"
  type        = string
}

# ---------- ACCESS ----------

variable "my_ip_cidr" {
  description = "Your public IP with /32. Who may reach the ALB."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "Must be CIDR, e.g. 203.0.113.45/32"
  }
}

variable "ssh_key_name" {
  description = "Name of the EC2 key pair (we imported 'aws-command-node')"
  type        = string
  default     = "aws-command-node"
}

# ---------- SIZING ----------

variable "nifi_instance_type" {
  description = "NiFi is a JVM app. Give it RAM."
  type        = string
  default     = "t3.large"
}

variable "kafka_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "nifi_volume_size" {
  description = "GB. NiFi's repositories eat disk."
  type        = number
  default     = 100
}

variable "kafka_volume_size" {
  description = "GB. Kafka logs eat disk."
  type        = number
  default     = 100
}

# ---------- APP CONFIG ----------

variable "kafka_topic" {
  type    = string
  default = "nifi-s3-files"
}

variable "nifi_http_listener_port" {
  description = "Port where NiFi listens for our Python trigger"
  type        = number
  default     = 9999
}
```

> **Those `validation` blocks are worth their weight in gold.** They catch a typo in 200 milliseconds instead of letting Terraform run for 6 minutes, half-build your VPC, and *then* explode with a cryptic AWS API error. Always validate.

### 5.5 `network.tf` — the VPC, subnets, and plumbing

```hcl
# network.tf
# ------------------------------------------------------------------
# Builds the new "data VPC" where NiFi and Kafka will live, and
# peers it back to the Command Node's VPC.
# ------------------------------------------------------------------

# Ask AWS which AZs exist right now. Don't hardcode "us-east-1a" --
# not every AZ supports every instance type, and this adapts automatically.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
  nifi_fqdn = "${var.nifi_subdomain}.${var.domain_name}"
}

# ============================================================
# THE VPC
# ============================================================
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both of these must be true for AWS-internal DNS to work.
  # Without them, your VPC S3 Endpoint silently fails and you will
  # lose an hour wondering why S3 calls time out.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# ============================================================
# INTERNET GATEWAY -- the door to the internet.
# Attach it to the VPC; a subnet becomes "public" ONLY when its
# route table has a route pointing at this gateway.
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
# No route to the internet gateway = unreachable from outside. Period.
# ============================================================
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # NOTE: map_public_ip_on_launch is ABSENT. It defaults to false.
  # That single omission is what makes this subnet private.

  tags = {
    Name = "${local.name}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ============================================================
# NAT GATEWAY -- lets private servers reach OUT (to download
# NiFi, Java, apt packages) while blocking anything reaching IN.
#
# Think of it as a one-way mirror.
#
# 💰 COST WARNING: ~$32/month + $0.045/GB processed. This is the
# single most expensive thing in this build. See section 13 for
# cheaper alternatives.
# ============================================================
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # NAT itself must sit in a PUBLIC subnet

  tags       = { Name = "${local.name}-nat" }
  depends_on = [aws_internet_gateway.main]
}

# ============================================================
# ROUTE TABLES -- the signposts that decide where packets go.
# ============================================================

# Public route table: "anything not local? -> Internet Gateway"
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"          # 0.0.0.0/0 means "literally anywhere"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

# Private route table: "anything not local? -> NAT Gateway"
# NOTE: no route to the Internet Gateway. That's the whole point.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-private" }
}

# A route table does nothing until you ASSOCIATE it with a subnet.
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
# WHY? Because the requirement says Kafka must be reachable from
# the Command Node. Without peering, the Command Node would have
# to reach Kafka over the public internet, which would mean giving
# Kafka a public IP. We are not doing that. Peering keeps ALL of
# this traffic on Amazon's private backbone -- it never touches
# the internet at all.
#
# Peering has NO hourly charge. You pay only for data transferred.
# ============================================================
resource "aws_vpc_peering_connection" "command_to_data" {
  vpc_id      = var.command_node_vpc_id   # requester (Command Node VPC)
  peer_vpc_id = aws_vpc.main.id           # accepter (new data VPC)
  auto_accept = true                      # works because both VPCs are in OUR account

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = { Name = "${local.name}-peering" }
}

# A peering connection is just a pipe. Nothing flows until you add
# ROUTES at BOTH ends telling packets to use it. Forgetting one
# direction is the #1 peering mistake -- traffic goes out and the
# reply never comes back.

# Data VPC -> Command VPC
resource "aws_route" "data_to_command" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.command_node_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.command_to_data.id
}

# Command VPC -> Data VPC  (we must edit the DEFAULT VPC's route tables)
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

### 5.6 `security.tf` — **THE MOST IMPORTANT FILE**

Read every comment in this file. This is where the assignment's core requirement lives.

```hcl
# security.tf
# ==================================================================
# THE SECURITY MODEL, IN ONE PICTURE:
#
#   Internet ──(443 only)──> [ALB SG]
#                               │
#                        (8443 only)
#                               │
#                               v
#   You (via SSH tunnel) ──> [NiFi SG] ──(9092)──> [Kafka SG]
#                               ^                      ^
#                               │                      │
#                       [Command Node SG] ─────(9092)──┘
#
# Kafka accepts connections from EXACTLY TWO badges: NiFi and
# Command Node. Nothing else in the universe can reach port 9092.
# ==================================================================

# ------------------------------------------------------------------
# ALB SECURITY GROUP -- the only thing touching the public internet
# ------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public entry point. HTTPS only."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }

  lifecycle {
    create_before_destroy = true   # avoids "SG in use" errors on updates
  }
}

resource "aws_security_group_rule" "alb_in_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]   # <-- ONLY YOU.
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from my IP only"

  # To open NiFi to the world you'd set this to ["0.0.0.0/0"].
  # DON'T. NiFi's UI is a powerful admin console -- someone who
  # reaches it can build a flow that reads your entire S3 bucket.
  # Keep it locked to your IP, or better, put it behind a VPN.
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
# NIFI SECURITY GROUP
# ------------------------------------------------------------------
resource "aws_security_group" "nifi" {
  name        = "${local.name}-nifi-sg"
  description = "NiFi. Reachable ONLY from the ALB and the Command Node."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-nifi-sg" }

  lifecycle { create_before_destroy = true }
}

# --- NiFi INBOUND ---

resource "aws_security_group_rule" "nifi_in_from_alb" {
  type                     = "ingress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.nifi.id
  description              = "NiFi web UI, from the ALB ONLY"
}

resource "aws_security_group_rule" "nifi_in_ssh_from_command" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = var.command_node_sg_id     # <-- the Command Node badge
  security_group_id        = aws_security_group.nifi.id
  description              = "SSH from Command Node ONLY (this is how Ansible gets in)"
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

# --- NiFi OUTBOUND ---
# We are DELIBERATELY specific here. The lazy thing is to allow all
# egress. But if NiFi is ever compromised, unrestricted egress is how
# an attacker exfiltrates your data. Least privilege applies OUTBOUND too.

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
  description       = "HTTPS out: for S3 (via VPC endpoint) and apt/downloads via NAT"
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
# 🔒 KAFKA SECURITY GROUP -- THE CENTREPIECE
#
# Requirement: "only allow access from the EC2 command server and
#               nifi on this subnet security group"
#
# This is how you satisfy it. TWO ingress rules on 9092. Both use
# source_security_group_id (badges), not cidr_blocks (addresses).
#
# NOT specified anywhere:
#   - 0.0.0.0/0            (the internet)
#   - 10.20.0.0/16         (the whole VPC)
#   - any hardcoded IP
#
# Therefore: unreachable by anything else. Full stop.
# ==================================================================
resource "aws_security_group" "kafka" {
  name        = "${local.name}-kafka-sg"
  description = "Kafka. Port 9092 open to EXACTLY two security groups."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-kafka-sg" }

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

# ==== THERE IS NO SOURCE #3. THAT IS THE POINT. ====

# SSH into Kafka, also only from the Command Node (Ansible needs this)
resource "aws_security_group_rule" "kafka_in_ssh_from_command" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = var.command_node_sg_id
  security_group_id        = aws_security_group.kafka.id
  description              = "SSH from Command Node ONLY (for Ansible)"
}

# Kafka egress: only what it needs to install itself.
resource "aws_security_group_rule" "kafka_out_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.kafka.id
  description       = "HTTPS out for package downloads via NAT"
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
# VPC ENDPOINT SG (for the Interface endpoints)
# ------------------------------------------------------------------
resource "aws_security_group" "vpce" {
  name        = "${local.name}-vpce-sg"
  description = "Allows private subnets to reach AWS API endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
    description = "HTTPS from private subnets"
  }

  tags = { Name = "${local.name}-vpce-sg" }
}
```

> ### 🎯 Why `source_security_group_id` beats `cidr_blocks`, restated
>
> This is the single most important idea in the tutorial, so here it is one final time.
>
> | | `cidr_blocks = ["10.20.11.47/32"]` | `source_security_group_id = aws_security_group.nifi.id` |
> |---|---|---|
> | NiFi reboots, gets new IP | ❌ **Silently breaks** | ✅ Still works |
> | You replace NiFi with a new instance | ❌ Breaks | ✅ Still works |
> | You scale to 3 NiFi nodes | ❌ Must edit rules | ✅ Automatic |
> | Someone launches a rogue box in the same subnet | ❌ **They can reach Kafka** | ✅ **Blocked — no badge** |
> | Reads clearly in an audit | ❌ "What is 10.20.11.47?" | ✅ "Ah — NiFi. Obviously." |
>
> That fourth row is the security argument. If you allow `10.20.0.0/16`, **every single machine in that VPC — including ones you didn't create — can hit Kafka.** With badges, only what you explicitly named gets in.

### 5.7 `s3.tf` — the bucket and the free private route to it

```hcl
# s3.tf

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "nifi_data" {
  bucket = "${local.name}-drop-${random_id.bucket_suffix.hex}"
  tags   = { Name = "${local.name}-drop" }
}

# Versioning: every overwrite keeps the old copy. Cheap insurance.
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
# headline you have ever read was an S3 bucket without this block.
# All four flags. Always.
resource "aws_s3_bucket_public_access_block" "nifi_data" {
  bucket                  = aws_s3_bucket.nifi_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==================================================================
# S3 GATEWAY VPC ENDPOINT
#
# Without this: NiFi's S3 traffic goes out through the NAT Gateway,
#               onto the public internet, and back to S3. You pay
#               $0.045/GB, and your data leaves Amazon's network.
#
# With this:    S3 traffic takes a private road inside AWS. It NEVER
#               touches the internet. And it's completely FREE.
#
# There is no downside. Always create this. It is free money.
# ==================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # A gateway endpoint works by injecting routes into route tables.
  route_table_ids = [aws_route_table.private.id]

  tags = { Name = "${local.name}-s3-endpoint" }
}

# SSM endpoints -- let you get a shell on a private instance WITHOUT
# SSH and WITHOUT a bastion. This is the modern, keyless way in.
# (Interface endpoints DO cost ~$7/mo each. Worth it for the security.)
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.key}-endpoint" }
}
```

### 5.8 `iam.tf` — NiFi's permission to read S3

```hcl
# iam.tf
# The whole point: NiFi reads S3 with a ROLE. Zero keys on disk.

# The "trust policy": WHO is allowed to wear this uniform?
# Answer: an EC2 instance. Nobody else.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nifi" {
  name               = "${local.name}-nifi-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-nifi-role" }
}

# The "permissions policy": WHAT can the wearer do?
data "aws_iam_policy_document" "nifi_s3" {
  # Permission to LIST the bucket (see what files exist).
  # Note: this is granted on the BUCKET arn, no /*
  statement {
    sid     = "ListTheBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.nifi_data.arn]
  }

  # Permission to READ/WRITE the OBJECTS inside it.
  # Note: this is granted on arn + "/*"
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

# Let us shell in via SSM without SSH keys
resource "aws_iam_role_policy_attachment" "nifi_ssm" {
  role       = aws_iam_role.nifi.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# An "instance profile" is the wrapper that lets an EC2 instance
# actually WEAR a role. Roles can't attach to EC2 directly -- they
# need this container. It's a quirk of IAM. Everyone forgets it once.
resource "aws_iam_instance_profile" "nifi" {
  name = "${local.name}-nifi-profile"
  role = aws_iam_role.nifi.name
}

# ---- Kafka role (SSM access only; no S3 needed) ----
resource "aws_iam_role" "kafka" {
  name               = "${local.name}-kafka-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "kafka_ssm" {
  role       = aws_iam_role.kafka.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "kafka" {
  name = "${local.name}-kafka-profile"
  role = aws_iam_role.kafka.name
}
```

> ### 🔍 The `/\*` trap that catches everyone
>
> Look carefully at the two statements above:
>
> | Action | Resource ARN | Why |
> |---|---|---|
> | `s3:ListBucket` | `arn:aws:s3:::my-bucket` | Acts on the **bucket** |
> | `s3:GetObject` | `arn:aws:s3:::my-bucket/*` | Acts on the **objects inside** |
>
> These are **different resources** in IAM's eyes. A bucket and its contents are not the same thing. If you put `ListBucket` on the `/*` ARN, listing fails with AccessDenied and you will stare at it for 20 minutes. Two statements. Always.

### 5.9 `compute.tf` — the NiFi and Kafka servers

```hcl
# compute.tf

# Look up the CURRENT Ubuntu 24.04 AMI ID rather than hardcoding one.
# AMI IDs are region-specific AND they change every time Canonical
# publishes a patched image. Hardcoding one means you deploy a stale,
# unpatched OS six months from now.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================
# NIFI
# ============================================================
resource "aws_instance" "nifi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.nifi_instance_type
  subnet_id              = aws_subnet.private[0].id   # <-- PRIVATE. No public IP. Ever.
  vpc_security_group_ids = [aws_security_group.nifi.id]
  iam_instance_profile   = aws_iam_instance_profile.nifi.name
  key_name               = var.ssh_key_name

  root_block_device {
    volume_size           = var.nifi_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Force IMDSv2. Blocks SSRF attacks that steal role credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # <-- the important line
    http_put_response_hop_limit = 1
  }

  # Minimal bootstrap. Ansible does the real work -- keep user_data
  # tiny, because debugging user_data is genuinely painful (you have
  # to dig through /var/log/cloud-init-output.log).
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    apt-get update
    apt-get install -y python3 python3-pip
    echo "ready-for-ansible" > /tmp/bootstrap-done
  EOF

  tags = {
    Name = "${local.name}-nifi"
    Role = "nifi"      # <-- Ansible's dynamic inventory finds hosts by this tag
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
  key_name               = var.ssh_key_name

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

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    apt-get update
    apt-get install -y python3 python3-pip
    echo "ready-for-ansible" > /tmp/bootstrap-done
  EOF

  tags = {
    Name = "${local.name}-kafka"
    Role = "kafka"
  }
}
```

### 5.10 `alb.tf` — the public front door

```hcl
# alb.tf

# ---------- TLS CERTIFICATE (free, from AWS) ----------
resource "aws_acm_certificate" "nifi" {
  domain_name       = local.nifi_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-cert" }
}

# ACM proves you own the domain by asking you to create a specific
# DNS record. Since Terraform manages Route53 too, it does this for
# you automatically. This is genuinely one of Terraform's nicest tricks.
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

# Blocks Terraform until AWS confirms the certificate is issued.
# Typically 30 seconds to 2 minutes.
resource "aws_acm_certificate_validation" "nifi" {
  certificate_arn         = aws_acm_certificate.nifi.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- THE LOAD BALANCER ----------
resource "aws_lb" "nifi" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false                      # false = internet-facing
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id    # <-- the two AZs. Required.

  enable_deletion_protection = false   # set TRUE in production!
  drop_invalid_header_fields = true    # security hardening
  idle_timeout               = 300     # NiFi's UI holds long connections

  tags = { Name = "${local.name}-alb" }
}

# ---------- TARGET GROUP: "who is behind the door?" ----------
resource "aws_lb_target_group" "nifi" {
  name        = "${local.name}-nifi-tg"
  port        = 8443
  protocol    = "HTTPS"                # NiFi speaks HTTPS internally
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/nifi-api/system-diagnostics"
    protocol            = "HTTPS"
    matcher             = "200,401"    # 401 = "NiFi is UP but wants auth". That IS healthy!
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  # NiFi's UI is stateful -- keep a user pinned to one node.
  stickiness {
    enabled = true
    type    = "lb_cookie"
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

# Port 80: don't serve anything, just bounce people to HTTPS
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
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"   # modern TLS 1.2/1.3 only
  certificate_arn   = aws_acm_certificate_validation.nifi.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nifi.arn
  }
}

# ---------- DNS ----------
# An ALIAS record (not a CNAME). ALIAS is AWS-specific, it's free to
# query, and unlike a CNAME it can live at the zone apex. Always prefer
# ALIAS when pointing at an AWS resource.
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

### 5.11 `outputs.tf`

```hcl
# outputs.tf
# What Terraform prints when it finishes. These values feed the next steps.

output "nifi_url" {
  description = "Open this in your browser"
  value       = "https://${local.nifi_fqdn}"
}

output "nifi_private_ip" {
  value = aws_instance.nifi.private_ip
}

output "kafka_private_ip" {
  value = aws_instance.kafka.private_ip
}

output "kafka_bootstrap_server" {
  description = "Paste this into the Python consumer"
  value       = "${aws_instance.kafka.private_ip}:9092"
}

output "s3_bucket_name" {
  description = "Drop your .txt files here"
  value       = aws_s3_bucket.nifi_data.id
}

output "nifi_trigger_endpoint" {
  description = "The Python app POSTs here"
  value       = "http://${aws_instance.nifi.private_ip}:${var.nifi_http_listener_port}/trigger"
}

output "next_steps" {
  value = <<-EOT

    ============================================================
      INFRASTRUCTURE IS UP. NOW:
    ============================================================

    1. Upload a test file:
       echo "hello from s3" > test.txt
       aws s3 cp test.txt s3://${aws_s3_bucket.nifi_data.id}/incoming/

    2. Configure the servers:
       cd ~/infra/ansible && ansible-playbook -i inventory.aws_ec2.yml site.yml

    3. Open NiFi:
       ${"https://${local.nifi_fqdn}"}

    4. Trigger it:
       cd ~/infra/python-app && python trigger_nifi.py

    5. Watch it arrive:
       python consumer.py
  EOT
}
```

### 5.12 `terraform.tfvars` — your values

**This is the only file with your real data. It is git-ignored.**

```hcl
# terraform.tfvars  -- FILL IN YOUR VALUES

aws_region   = "us-east-1"
project_name = "nifi-platform"
environment  = "dev"
owner        = "your-name"

# --- from Part One, Step 15 ---
command_node_sg_id    = "sg-0REPLACE_ME"
command_node_vpc_id   = "vpc-0REPLACE_ME"
command_node_vpc_cidr = "172.31.0.0/16"

# --- your domain ---
domain_name     = "example.com"
nifi_subdomain  = "nifi"
route53_zone_id = "Z0REPLACE_ME"

# --- from `curl https://checkip.amazonaws.com` ---
my_ip_cidr = "203.0.113.45/32"

ssh_key_name = "aws-command-node"
```

Need your Route53 Zone ID?

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[].{Name:Name,Id:Id}" --output table
```

*(If you bought your domain elsewhere — GoDaddy, Namecheap — create a Route53 Hosted Zone for it, then update the nameservers at your registrar to point at the four AWS nameservers Route53 gives you. Propagation takes 15 minutes to a few hours.)*

### 5.13 Run it

Point the backend at your bucket first:

```bash
cd ~/infra
BUCKET=$(cat ~/tf-bucket-name.txt)
sed -i "s/REPLACE_WITH_YOUR_BUCKET/$BUCKET/" versions.tf
grep bucket versions.tf   # verify
```

Now, the four commands. **Always in this order.**

```bash
# 1. INIT -- downloads the AWS provider, connects to the S3 backend.
#    Run once per project, and again any time you change providers.
terraform init
```

```bash
# 2. VALIDATE -- checks your syntax. Free, instant, catches typos.
terraform validate
terraform fmt -recursive    # auto-format. Just always do this.
```

```bash
# 3. PLAN -- ⭐ THE MOST IMPORTANT COMMAND IN TERRAFORM ⭐
#    Shows exactly what will change. Changes NOTHING.
#    READ THE OUTPUT. Every time. No exceptions.
terraform plan -out=tfplan
```

Terraform prints a diff:
- `+` green = will be **created**
- `~` yellow = will be **modified in place**
- `-/+` = will be **destroyed and recreated** ⚠️ *(this is where data loss happens — read carefully!)*
- `-` red = will be **destroyed** 🚨

It should end with something like:

```
Plan: 43 to add, 0 to change, 0 to destroy.
```

> 🚨 **The single best habit you can build:** never, ever run `apply` without reading the `plan`. A `-/+` on a database or a volume means your data is about to be deleted. `plan` is your seatbelt. Wear it.

```bash
# 4. APPLY -- do the thing. Because we saved the plan, it applies
#    EXACTLY what you just reviewed. No surprises.
terraform apply tfplan
```

Go make coffee. This takes **8–12 minutes**, and it is almost entirely spent waiting on two things:
- The **NAT Gateway** (~2 min)
- The **Load Balancer** (~4 min — ALBs are genuinely slow to provision)

When it finishes:

```
Apply complete! Resources: 43 added, 0 changed, 0 destroyed.

Outputs:

kafka_bootstrap_server = "10.20.11.88:9092"
nifi_private_ip = "10.20.11.42"
nifi_url = "https://nifi.example.com"
s3_bucket_name = "nifi-platform-dev-drop-a3f9c2e1"
...
```

**You just built a 43-resource production-shaped AWS environment from a text file.** Save those outputs:

```bash
terraform output > ~/infra-outputs.txt
cat ~/infra-outputs.txt
```

Commit your code (the `.gitignore` keeps secrets out):

```bash
git add . && git commit -m "Full NiFi/Kafka platform"
```

### 5.14 Prove the security model actually works

Don't take my word for it. Test it.

```bash
# Get the IPs
KAFKA_IP=$(terraform output -raw kafka_private_ip)
NIFI_IP=$(terraform output -raw nifi_private_ip)

# ---- TEST 1: Can the Command Node reach Kafka? (SHOULD SUCCEED) ----
# The Command Node wears the badge, so this should connect.
nc -zv -w 5 "$KAFKA_IP" 9092
# Expected: Connection to 10.20.11.88 9092 port [tcp/*] succeeded!
#
# NOTE: this will only succeed AFTER Ansible installs and starts
# Kafka. Before that, the port is open at the firewall but nothing
# is listening. "Connection refused" at this stage = firewall OK,
# service not running yet. That's actually the correct behavior.

# ---- TEST 2: Is NiFi reachable from the internet? (SHOULD FAIL) ----
# NiFi has NO public IP. There is no possible route. This proves it.
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=nifi" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text
# Expected output: empty / None.
# NO PUBLIC IP = UNREACHABLE FROM THE INTERNET. Not "firewalled off."
# Genuinely unroutable.

# ---- TEST 3: Confirm Kafka's ingress list ----
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*kafka-sg" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`9092`].UserIdGroupPairs[].GroupId' \
  --output text
# Expected: exactly TWO security group IDs -- NiFi's and the Command Node's.
# If you see a third, or if you see any IpRanges at all, something is wrong.
```

That last test is the proof of the requirement. Two badges. No CIDRs. Nothing else on earth can reach port 9092.
---

## 6. PART THREE — Ansible Configures the Servers

Terraform built two empty Ubuntu boxes. They have no Java, no NiFi, no Kafka. Ansible fixes that.

### 6.1 SSH agent forwarding (so Ansible can hop)

Ansible runs on the Command Node and SSHes to the private servers. But the private key lives on your **laptop**, not the Command Node.

You have two options:

| Option | How | Verdict |
|---|---|---|
| Copy the private key to the Command Node | `scp ~/.ssh/key ubuntu@cmd:~/.ssh/` | ❌ **Don't.** Now the key exists in two places. If the Command Node is compromised, the attacker has your key. |
| **SSH Agent Forwarding** | `ssh -A` | ✅ **Do this.** The key stays on your laptop. The Command Node just *borrows* it for each connection. |

Disconnect and reconnect **with `-A`**:

```bash
# On your LAPTOP:
ssh-add ~/.ssh/aws-command-node       # load key into your local agent
ssh-add -l                            # verify it's there

ssh -A -i ~/.ssh/aws-command-node ubuntu@<COMMAND_NODE_PUBLIC_IP>
```

On the Command Node, verify the forwarding worked:

```bash
ssh-add -l
```

If it lists your key, forwarding is live. If it says *"Could not open a connection to your authentication agent,"* you forgot the `-A`. Log out and back in.

> **Security footnote:** agent forwarding does mean that *root on the Command Node* could theoretically use your agent socket while you're logged in. That's an acceptable tradeoff here (you own the box). For high-security environments, the better answer is **AWS Systems Manager Session Manager** — which we enabled with those SSM VPC endpoints. It needs no SSH keys at all.

### 6.2 Ansible config

```bash
cd ~/infra/ansible
```

**`ansible.cfg`:**

```ini
[defaults]
inventory            = inventory.aws_ec2.yml
host_key_checking    = False
remote_user          = ubuntu
interpreter_python   = /usr/bin/python3
stdout_callback      = yaml
timeout              = 60
retry_files_enabled  = False

[inventory]
enable_plugins = aws_ec2

[ssh_connection]
# ControlMaster reuses ONE tcp connection for all tasks on a host.
# This is a genuinely enormous speedup -- often 3-5x.
ssh_args    = -o ControlMaster=auto -o ControlPersist=300s -o ForwardAgent=yes
pipelining  = True
```

> `pipelining = True` alone typically cuts playbook runtime by ~40%. Without it, Ansible copies a temp file to the target for every single task. With it, it pipes the module over the existing SSH connection. There's no reason not to enable it on modern systems.

### 6.3 Dynamic inventory — never hardcode an IP

**`inventory.aws_ec2.yml`:**

```yaml
---
# This asks AWS "which instances exist right now?" every single run.
# If a server is replaced and gets a new IP, this Just Works.
# Hardcoded IP lists rot. Dynamic inventory does not.
plugin: aws_ec2
regions:
  - us-east-1

filters:
  instance-state-name: running
  tag:Project: nifi-platform

# Auto-create groups from tags. An instance tagged Role=nifi
# lands in a group called "role_nifi". That's how the playbook targets it.
keyed_groups:
  - key: tags.Role
    prefix: role
    separator: "_"

# CRITICAL: use PRIVATE IPs. These boxes have no public IP,
# and we reach them over the peering connection.
hostnames:
  - private-ip-address

compose:
  ansible_host: private_ip_address
```

Test it:

```bash
ansible-inventory --graph
```

Expected:

```
@all:
  |--@aws_ec2:
  |  |--10.20.11.42
  |  |--10.20.11.88
  |--@role_kafka:
  |  |--10.20.11.88
  |--@role_nifi:
  |  |--10.20.11.42
```

Now ping them (Ansible's "ping" is really a Python check, not ICMP):

```bash
ansible all -m ping
```

```
10.20.11.42 | SUCCESS => { "ping": "pong" }
10.20.11.88 | SUCCESS => { "ping": "pong" }
```

If you get `UNREACHABLE`, the causes, in order of likelihood:
1. You forgot `ssh -A` (most common)
2. Terraform is still finishing — wait 60 seconds and retry
3. The VPC peering routes didn't apply — re-check `terraform plan`

### 6.4 The Kafka role

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
```

**`roles/kafka/tasks/main.yml`:**

```yaml
---
# Kafka 3.9 in KRaft mode. NO ZOOKEEPER. ZooKeeper was removed in
# Kafka 4.0 and has been optional since 3.3. Any tutorial that tells
# you to install it is out of date.

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
    shell: /usr/sbin/nologin      # can't be logged into. Good.
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
    url: "https://downloads.apache.org/kafka/{{ kafka_version }}/kafka_{{ kafka_scala_version }}-{{ kafka_version }}.tgz"
    dest: "/tmp/kafka.tgz"
    mode: "0644"
    timeout: 120
  register: kafka_download
  retries: 3
  delay: 10
  until: kafka_download is succeeded

- name: Unpack Kafka
  ansible.builtin.unarchive:
    src: "/tmp/kafka.tgz"
    dest: "{{ kafka_install_dir }}"
    remote_src: true
    extra_opts: [--strip-components=1]   # drop the top-level folder
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

- name: Generate a cluster UUID (once, and only once)
  ansible.builtin.shell: |
    {{ kafka_install_dir }}/bin/kafka-storage.sh random-uuid
  register: cluster_uuid
  changed_when: false
  args:
    creates: "{{ kafka_data_dir }}/meta.properties"

- name: Format the storage directory
  ansible.builtin.shell: |
    {{ kafka_install_dir }}/bin/kafka-storage.sh format \
      -t {{ cluster_uuid.stdout }} \
      -c {{ kafka_install_dir }}/config/kraft/server.properties
  become_user: "{{ kafka_user }}"
  args:
    creates: "{{ kafka_data_dir }}/meta.properties"   # never runs twice

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
  ansible.builtin.shell: |
    {{ kafka_install_dir }}/bin/kafka-topics.sh \
      --bootstrap-server {{ ansible_default_ipv4.address }}:9092 \
      --create --if-not-exists \
      --topic {{ kafka_topic }} \
      --partitions 3 \
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
# listeners        = "what socket do I BIND to?"
# advertised.listeners = "what address do I TELL CLIENTS to use?"
#
# Kafka's protocol works like this: a client connects to the
# bootstrap server and asks "who are the brokers?" Kafka replies
# with the ADVERTISED address. The client then DISCONNECTS and
# RECONNECTS to that advertised address.
#
# If advertised.listeners says "localhost", the client will try to
# connect to ITS OWN localhost, find nothing, and hang forever.
# This produces the single most confusing error in all of Kafka --
# it connects fine, then times out with no useful message.
#
# ALWAYS advertise the address clients can actually reach.
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
# to yourself. Setting this to 3 on one broker means every topic
# creation fails.
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
default.replication.factor=1
min.insync.replicas=1

num.partitions=3
auto.create.topics.enable=true

# Keep messages 7 days
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
```

> ⚠️ **PLAINTEXT means unencrypted.** We're using it because all traffic stays inside a private VPC subnet reachable by exactly two security groups. For anything touching real data, you'd configure **SASL_SSL** with TLS certificates and SCRAM authentication. Section 10 covers the upgrade path.

**`roles/kafka/templates/kafka.service.j2`:**

```jinja
[Unit]
Description=Apache Kafka (KRaft)
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
# at the end. This is why you don't get ten restarts in a row.
- name: reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: restart kafka
  ansible.builtin.systemd:
    name: kafka
    state: restarted
```

### 6.5 The NiFi role

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
nifi_admin_password: "ChangeMe-LongPassword-123!"
```

**`roles/nifi/tasks/main.yml`:**

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

- name: Download NiFi (this is ~1.5GB -- be patient)
  ansible.builtin.get_url:
    url: "https://downloads.apache.org/nifi/{{ nifi_version }}/nifi-{{ nifi_version }}-bin.zip"
    dest: /tmp/nifi.zip
    mode: "0644"
    timeout: 600
  register: nifi_dl
  retries: 3
  delay: 15
  until: nifi_dl is succeeded

- name: Unpack NiFi
  ansible.builtin.unarchive:
    src: /tmp/nifi.zip
    dest: "{{ nifi_install_dir }}"
    remote_src: true
    extra_opts: [-j] # no; we strip below instead
    owner: "{{ nifi_user }}"
    group: "{{ nifi_user }}"
    creates: "{{ nifi_install_dir }}/bin/nifi.sh"
  # NOTE: unarchive can't --strip-components for zip. So instead:
  ignore_errors: true

- name: Flatten the extracted folder (zip has no strip-components)
  ansible.builtin.shell: |
    set -e
    cd /tmp
    rm -rf nifi-extract && mkdir nifi-extract
    unzip -q nifi.zip -d nifi-extract
    cp -a nifi-extract/nifi-{{ nifi_version }}/. {{ nifi_install_dir }}/
    chown -R {{ nifi_user }}:{{ nifi_user }} {{ nifi_install_dir }}
  args:
    creates: "{{ nifi_install_dir }}/bin/nifi.sh"

- name: Configure JVM heap
  ansible.builtin.lineinfile:
    path: "{{ nifi_install_dir }}/conf/bootstrap.conf"
    regexp: "^java.arg.3="
    line: "java.arg.3=-Xmx{{ nifi_heap }}"

- name: Configure JVM initial heap
  ansible.builtin.lineinfile:
    path: "{{ nifi_install_dir }}/conf/bootstrap.conf"
    regexp: "^java.arg.2="
    line: "java.arg.2=-Xms{{ nifi_heap }}"

# ============================================================
# 🚨 THE PROXY HEADER GOTCHA
#
# NiFi checks the HTTP Host header on every request. If it doesn't
# recognise it, it returns:
#
#   "System Error: The request contained an invalid host header"
#
# Behind an ALB, the Host header is "nifi.example.com", which NiFi
# has never heard of. So it rejects EVERY request and you get a
# blank error page.
#
# The fix is nifi.web.proxy.host -- a whitelist of hostnames NiFi
# will accept. You MUST include your ALB domain here. This trips up
# literally everyone who puts NiFi behind a load balancer.
# ============================================================
- name: Write nifi.properties
  ansible.builtin.template:
    src: nifi.properties.j2
    dest: "{{ nifi_install_dir }}/conf/nifi.properties"
    owner: "{{ nifi_user }}"
    mode: "0644"
  notify: restart nifi

- name: Set the single-user credentials
  ansible.builtin.shell: |
    {{ nifi_install_dir }}/bin/nifi.sh set-single-user-credentials \
      {{ nifi_admin_user }} '{{ nifi_admin_password }}'
  become_user: "{{ nifi_user }}"
  args:
    creates: "{{ nifi_install_dir }}/conf/login-identity-providers.xml.configured"
  notify: restart nifi

- name: Install systemd unit
  ansible.builtin.template:
    src: nifi.service.j2
    dest: /etc/systemd/system/nifi.service
    mode: "0644"
  notify:
    - reload systemd
    - restart nifi

- name: Start NiFi
  ansible.builtin.systemd:
    name: nifi
    state: started
    enabled: true
    daemon_reload: true

# NiFi is SLOW to boot. 2-4 minutes is completely normal. It is
# unpacking hundreds of NAR bundles. Do not panic. Do not restart it.
- name: Wait for NiFi (this genuinely takes several minutes)
  ansible.builtin.wait_for:
    port: "{{ nifi_web_port }}"
    host: "{{ ansible_default_ipv4.address }}"
    timeout: 400
    delay: 30
```

**`roles/nifi/templates/nifi.properties.j2`** (the important lines only — NiFi's real file is ~200 lines; keep the shipped defaults and change these):

```jinja
nifi.web.https.host=0.0.0.0
nifi.web.https.port={{ nifi_web_port }}
nifi.web.http.host=
nifi.web.http.port=

# ⭐⭐⭐ THE LINE THAT MAKES THE LOAD BALANCER WORK ⭐⭐⭐
# Without this, every request through the ALB fails with
# "invalid host header". Include the FQDN, the private IP, and the ALB DNS.
nifi.web.proxy.host={{ nifi_fqdn }}:443,{{ nifi_fqdn }},{{ ansible_default_ipv4.address }}:{{ nifi_web_port }},localhost:{{ nifi_web_port }}
nifi.web.proxy.context.path=/

nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12

nifi.remote.input.host={{ ansible_default_ipv4.address }}
nifi.remote.input.secure=true
nifi.remote.input.socket.port=10443

nifi.cluster.is.node=false

nifi.flowfile.repository.directory=./flowfile_repository
nifi.content.repository.directory.default=./content_repository
nifi.provenance.repository.directory.default=./provenance_repository
```

> **On the ALB↔NiFi certificate:** NiFi generates a *self-signed* cert on first boot. The ALB's target group speaks HTTPS to it. That's fine — **an ALB does not validate backend certificates.** It encrypts the hop and moves on. So self-signed works here. The cert your *browser* sees is the ACM one on the ALB, which is properly trusted. Two different certs, two different jobs.

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

### 6.6 The playbook

**`site.yml`:**

```yaml
---
- name: Baseline hardening on every host
  hosts: all
  become: true
  gather_facts: true

  tasks:
    - name: Update apt cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600

    - name: Install common tools
      ansible.builtin.apt:
        name:
          - curl
          - wget
          - unzip
          - vim
          - htop
          - net-tools
          - chrony        # clock sync -- Kafka is VERY sensitive to clock drift
        state: present

    - name: Enable time sync
      ansible.builtin.systemd:
        name: chrony
        state: started
        enabled: true

# ---- KAFKA FIRST ----
# Order matters. NiFi will try to connect to Kafka. If Kafka isn't
# up yet, NiFi's processor sits in a retry loop. Not fatal, but ugly.
- name: Deploy Kafka
  hosts: role_kafka
  become: true
  gather_facts: true
  roles:
    - kafka

# ---- THEN NIFI ----
- name: Deploy NiFi
  hosts: role_nifi
  become: true
  gather_facts: true
  vars:
    # Pull the Kafka broker address straight out of Ansible's fact
    # cache for the Kafka host. No hardcoding, no copy-paste.
    kafka_bootstrap: "{{ hostvars[groups['role_kafka'][0]]['ansible_default_ipv4']['address'] }}:9092"
    nifi_fqdn: "nifi.example.com"     # <-- CHANGE THIS to your domain
  roles:
    - nifi

  post_tasks:
    - name: Show the connection details
      ansible.builtin.debug:
        msg:
          - "NiFi is up on port {{ nifi_web_port }}"
          - "Kafka broker is at {{ kafka_bootstrap }}"
          - "Kafka topic: {{ kafka_topic | default('nifi-s3-files') }}"
```

### 6.7 Run it

```bash
cd ~/infra/ansible

# ALWAYS dry-run first. --check makes no changes; --diff shows what
# WOULD change. This is Ansible's equivalent of `terraform plan`.
ansible-playbook site.yml --check --diff

# Now for real
ansible-playbook site.yml
```

**This takes 10–20 minutes.** Most of it is downloading NiFi (a ~1.5 GB zip) and waiting for the JVM to unpack a few hundred NAR bundles on first boot.

Success looks like:

```
PLAY RECAP *********************************************************
10.20.11.42  : ok=22  changed=18  unreachable=0  failed=0
10.20.11.88  : ok=17  changed=14  unreachable=0  failed=0
```

**`failed=0` is the only number that matters.**

Now run it **a second time**:

```bash
ansible-playbook site.yml
```

```
PLAY RECAP *********************************************************
10.20.11.42  : ok=22  changed=0   unreachable=0  failed=0
10.20.11.88  : ok=17  changed=0   unreachable=0  failed=0
```

`changed=0`. **That is idempotency, proven.** Ansible looked at every task, saw the desired state already existed, and did nothing. This is exactly what you want, and it's why it's safe to re-run these playbooks any time.

---

## 7. PART FOUR — The Python App and the Consumer

Now the fun part. We build:
- A **NiFi flow** that listens for an HTTP poke, reads S3, and publishes to Kafka
- A **Python trigger** that sends the poke
- A **Python consumer** that `cat`s the file contents to your screen

### 7.1 Open the NiFi UI

```bash
# From the Command Node:
terraform -chdir=~/infra output -raw nifi_url
```

Open `https://nifi.yourdomain.com` in your **laptop's** browser. (Your ALB security group allows your IP.)

Log in with `admin` / the password from `roles/nifi/defaults/main.yml`.

> **Blank page or "invalid host header"?** That is the `nifi.web.proxy.host` problem. Go back to 6.5. It's always this.

### 7.2 The NiFi flow, explained before we build it

```
[HandleHttpRequest] :9999
        |  ("someone poked me!")
        v
   [ListS3]  --> emits ONE FlowFile per object in the bucket
        |       (content is empty; the s3.key is in the ATTRIBUTES)
        v
 [FetchS3Object] --> downloads the actual bytes into the FlowFile content
        |
        v
  [PublishKafka] --> writes the bytes to topic 'nifi-s3-files'
        |
        v
[HandleHttpResponse] --> tells the Python app "200 OK, done"
```

The key idea, and it's a subtle one: **`ListS3` doesn't download anything.** It emits an empty FlowFile whose *attributes* say `s3.bucket=my-bucket, filename=incoming/report.txt`. It's a *pointer*, not the data. `FetchS3Object` then reads those attributes and does the actual download.

Why split it? Because listing 10,000 files is cheap, but downloading 10,000 files is expensive. Splitting lets NiFi queue the pointers and fetch them at a controlled rate. It's the same reason `ls` is fast and `cat *` is slow.

### 7.3 Build the flow

In the NiFi canvas:

**A) `ListS3`**

Drag a Processor onto the canvas → search `ListS3` → Add.

Right-click → **Configure** → **Properties**:

| Property | Value |
|---|---|
| Bucket | *(your bucket name from `terraform output s3_bucket_name`)* |
| Region | `us-east-1` |
| Prefix | `incoming/` |
| **AWS Credentials Provider Service** | *see below* ⬇️ |

Click the **AWS Credentials Provider Service** dropdown → **Create new service** → `AWSCredentialsProviderControllerService` → click the ⚙️ gear to configure it.

**Leave every field blank.** Then click the ⚡ lightning bolt to **Enable** it.

> ### 🔑 Why blank? This is the payoff of the whole IAM section.
>
> With no credentials configured, the AWS SDK falls back to its **default credential provider chain**. On an EC2 instance, the last link in that chain is the **instance metadata service** — which hands back the temporary credentials of the IAM role we attached in `iam.tf`.
>
> So by configuring *nothing*, NiFi automatically picks up the role. **Zero keys. Zero secrets. Zero configuration.** If you had pasted an access key into those fields, you'd have created exactly the vulnerability we spent all of section 2.13 avoiding.
>
> Blank is correct. Blank is secure. Blank is the whole point.

**Scheduling** tab: set **Run Schedule** to `0 sec` and **Scheduling Strategy** to `Timer driven`. *(We'll drive it from HTTP instead, but this keeps it responsive.)*

**B) `FetchS3Object`**

| Property | Value |
|---|---|
| Bucket | `${s3.bucket}` |
| Object Key | `${filename}` |
| Region | `us-east-1` |
| AWS Credentials Provider Service | *the same service you just made* |

Those `${...}` are **NiFi Expression Language** — they read attributes off the incoming FlowFile. `ListS3` set them; `FetchS3Object` uses them.

**C) `PublishKafka`**

| Property | Value |
|---|---|
| Kafka Brokers | `<KAFKA_PRIVATE_IP>:9092` |
| Topic Name | `nifi-s3-files` |
| Delivery Guarantee | `Guarantee Replicated Delivery` |
| Use Transactions | `false` |

Get the IP: `terraform output -raw kafka_bootstrap_server`

**D) `HandleHttpRequest`**

| Property | Value |
|---|---|
| Listening Port | `9999` |
| Allowed Paths | `/trigger` |
| HTTP Context Map | *create new* `StandardHttpContextMap` → **Enable it** ⚡ |

**E) `HandleHttpResponse`**

| Property | Value |
|---|---|
| HTTP Status Code | `200` |
| HTTP Context Map | *the same context map* |

**F) Wire them together**

Drag from each processor's edge to the next:

| From | Relationship | To |
|---|---|---|
| HandleHttpRequest | `success` | ListS3 |
| ListS3 | `success` | FetchS3Object |
| FetchS3Object | `success` | PublishKafka |
| PublishKafka | `success` | HandleHttpResponse |

For **failure** relationships on FetchS3Object and PublishKafka: right-click the processor → **Configure** → **Settings** tab → check **Automatically Terminate** for `failure`. *(In production you'd route failures to a retry loop or a dead-letter queue. For a demo, terminating is fine.)*

**G) Start everything**

Select all (Ctrl+A on the canvas) → click the ▶ **Start** button in the Operate palette.

All processors should turn **green**. A red ⚠️ means a config error — hover over it and it tells you exactly what's wrong.

### 7.4 Upload test files

```bash
cd ~/nifi-kafka-app
source .venv/bin/activate

BUCKET=$(terraform -chdir=~/infra output -raw s3_bucket_name)

echo "Hello from the first file. This is line one." > file1.txt
echo "Second file. NiFi should pull this out of S3." > file2.txt
printf "Third file.\nWith multiple lines.\nAnd a third line.\n" > file3.txt

aws s3 cp file1.txt "s3://$BUCKET/incoming/"
aws s3 cp file2.txt "s3://$BUCKET/incoming/"
aws s3 cp file3.txt "s3://$BUCKET/incoming/"

aws s3 ls "s3://$BUCKET/incoming/"
```

### 7.5 `trigger_nifi.py` — the app that tells NiFi to go

**`~/nifi-kafka-app/trigger_nifi.py`:**

```python
#!/usr/bin/env python3
"""
trigger_nifi.py
================
Sends an HTTP POST to NiFi's HandleHttpRequest processor, which kicks
off the flow: ListS3 -> FetchS3Object -> PublishKafka.

Think of NiFi as a vending machine that only dispenses when you push
the button. This script pushes the button.

Run:
    python trigger_nifi.py
    python trigger_nifi.py --prefix incoming/ --wait
"""

import argparse
import json
import subprocess
import sys
import time

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


def terraform_output(name: str) -> str:
    """Read a value straight out of Terraform state.

    This is much better than hardcoding IPs. If you rebuild the
    infrastructure, the script picks up the new addresses automatically.
    """
    try:
        result = subprocess.run(
            ["terraform", "-chdir=" + INFRA_DIR, "output", "-raw", name],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"[!] Could not read terraform output '{name}'", file=sys.stderr)
        print(f"    stderr: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("[!] terraform not on PATH. Are you on the Command Node?", file=sys.stderr)
        sys.exit(1)


INFRA_DIR = "/home/ubuntu/infra"


def build_session() -> requests.Session:
    """A session with automatic retries and exponential backoff.

    NiFi can be briefly unresponsive during a flow restart. Rather than
    failing instantly, we retry with increasing delays: 1s, 2s, 4s...
    This is standard practice for ANY network call and you should do it
    everywhere.
    """
    session = requests.Session()
    retry = Retry(
        total=5,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
    )
    session.mount("http://", HTTPAdapter(max_retries=retry))
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def trigger(endpoint: str, prefix: str, session: requests.Session) -> bool:
    payload = {
        "action": "pull_from_s3",
        "prefix": prefix,
        "requested_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "requested_by": "trigger_nifi.py",
    }

    print("=" * 62)
    print("  TRIGGERING NIFI")
    print("=" * 62)
    print(f"  Endpoint : {endpoint}")
    print(f"  Payload  : {json.dumps(payload)}")
    print("-" * 62)

    try:
        response = session.post(
            endpoint,
            json=payload,
            timeout=(5, 60),   # (connect timeout, read timeout)
            headers={"Content-Type": "application/json"},
        )
    except requests.exceptions.ConnectTimeout:
        print("[!] TIMED OUT connecting to NiFi.")
        print("    Likely causes:")
        print("      - The HandleHttpRequest processor isn't STARTED (green)")
        print("      - The NiFi security group doesn't allow :9999 from here")
        return False
    except requests.exceptions.ConnectionError as e:
        print(f"[!] CONNECTION REFUSED: {e}")
        print("    Nothing is listening on 9999. Start the processor in NiFi.")
        return False

    print(f"  Status   : {response.status_code}")
    if response.text:
        print(f"  Body     : {response.text[:400]}")
    print("=" * 62)

    if response.status_code == 200:
        print("\n  ✅ NiFi accepted the trigger.")
        print("     It is now: listing S3 -> fetching objects -> publishing to Kafka.")
        print("\n     Run  python consumer.py  to watch the contents arrive.\n")
        return True

    print(f"\n  ❌ Unexpected status {response.status_code}\n")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Tell NiFi to pull from S3")
    ap.add_argument("--prefix", default="incoming/", help="S3 prefix to pull")
    ap.add_argument("--endpoint", default=None, help="Override the NiFi URL")
    ap.add_argument("--wait", action="store_true", help="Pause 10s afterwards")
    args = ap.parse_args()

    endpoint = args.endpoint or terraform_output("nifi_trigger_endpoint")
    session = build_session()

    ok = trigger(endpoint, args.prefix, session)

    if ok and args.wait:
        print("  Waiting 10s for the flow to drain...")
        for i in range(10, 0, -1):
            print(f"    {i}...", end="\r", flush=True)
            time.sleep(1)
        print("    Done.        ")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
```

### 7.6 `consumer.py` — the app that `cat`s the contents

**`~/nifi-kafka-app/consumer.py`:**

```python
#!/usr/bin/env python3
"""
consumer.py
===========
Reads messages off the Kafka topic and prints their contents to stdout,
exactly like `cat` does for a file.

REMEMBER: this only works because the Command Node's security group is
one of the TWO security groups allowed to reach Kafka on port 9092.
Run this from anywhere else and the TCP connection will simply hang.
That is the security model doing its job.

Run:
    python consumer.py                  # tail forever
    python consumer.py --from-beginning # replay everything
    python consumer.py --max 5          # stop after 5 messages
"""

import argparse
import subprocess
import sys
from datetime import datetime

from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable

INFRA_DIR = "/home/ubuntu/infra"

# ANSI colour codes -- makes the output far easier to read
CYAN, GREEN, YELLOW, GREY, BOLD, RESET = (
    "\033[96m", "\033[92m", "\033[93m", "\033[90m", "\033[1m", "\033[0m"
)


def terraform_output(name: str) -> str:
    try:
        r = subprocess.run(
            ["terraform", "-chdir=" + INFRA_DIR, "output", "-raw", name],
            capture_output=True, text=True, check=True, timeout=30,
        )
        return r.stdout.strip()
    except Exception as e:
        print(f"[!] terraform output '{name}' failed: {e}", file=sys.stderr)
        sys.exit(1)


def cat_message(msg, index: int) -> None:
    """Print one Kafka message the way `cat` would print a file."""
    ts = datetime.fromtimestamp(msg.timestamp / 1000).strftime("%H:%M:%S")

    # NiFi puts the original S3 filename in a Kafka header, if configured.
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
    print(f"{CYAN}{'━' * 66}{RESET}")
    print(f"{BOLD}  📄 MESSAGE #{index}{RESET}")
    print(f"{GREY}  file      : {filename}{RESET}")
    print(f"{GREY}  topic     : {msg.topic}  partition {msg.partition}  offset {msg.offset}{RESET}")
    print(f"{GREY}  timestamp : {ts}{RESET}")
    print(f"{GREY}  size      : {len(msg.value)} bytes{RESET}")
    print(f"{CYAN}{'━' * 66}{RESET}")
    print(f"{YELLOW}  ▼ CONTENTS (this is the `cat`){RESET}")
    print(f"{CYAN}{'─' * 66}{RESET}")

    # ---- THE ACTUAL `cat` ----
    for line in content.splitlines():
        print(f"  {GREEN}{line}{RESET}")
    if not content.strip():
        print(f"  {GREY}(empty file){RESET}")
    # --------------------------

    print(f"{CYAN}{'─' * 66}{RESET}")


def main() -> int:
    ap = argparse.ArgumentParser(description="cat the contents of S3 files, via Kafka")
    ap.add_argument("--topic", default="nifi-s3-files")
    ap.add_argument("--bootstrap", default=None, help="host:port of the broker")
    ap.add_argument("--group", default="s3-cat-consumer", help="consumer group id")
    ap.add_argument("--from-beginning", action="store_true",
                    help="replay the whole topic from offset 0")
    ap.add_argument("--max", type=int, default=0, help="stop after N messages")
    ap.add_argument("--timeout", type=int, default=0,
                    help="exit after N seconds of silence (0 = never)")
    args = ap.parse_args()

    bootstrap = args.bootstrap or terraform_output("kafka_bootstrap_server")

    print()
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"{BOLD}  KAFKA CONSUMER — cat-ing S3 text files{RESET}")
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"  broker : {bootstrap}")
    print(f"  topic  : {args.topic}")
    print(f"  group  : {args.group}")
    print(f"  offset : {'earliest (replay all)' if args.from_beginning else 'latest (tail new)'}")
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"{GREY}  Waiting for messages... (Ctrl+C to quit){RESET}")

    try:
        consumer = KafkaConsumer(
            args.topic,
            bootstrap_servers=[bootstrap],
            group_id=args.group,

            # 'earliest' = start at offset 0, replay everything ever sent.
            # 'latest'   = start at the END, only show NEW messages.
            # This ONLY applies the first time a group_id is seen. After
            # that, Kafka remembers the group's committed offset and
            # resumes from there. Change --group to force a fresh start.
            auto_offset_reset="earliest" if args.from_beginning else "latest",

            enable_auto_commit=True,
            auto_commit_interval_ms=1000,
            consumer_timeout_ms=(args.timeout * 1000) if args.timeout else -1,
            api_version_auto_timeout_ms=10000,

            # Deliberately NOT deserializing here -- we want the RAW bytes,
            # because that's the literal content of the .txt file.
            value_deserializer=None,
        )
    except NoBrokersAvailable:
        print(f"\n  ❌ Cannot reach Kafka at {bootstrap}\n")
        print("  Check, in order:")
        print("    1. Is Kafka running?")
        print(f"       ansible role_kafka -a 'systemctl is-active kafka' -b")
        print("    2. Is the port reachable from here?")
        print(f"       nc -zv {bootstrap.replace(':', ' ')}")
        print("    3. Are you on the COMMAND NODE?")
        print("       Only NiFi and the Command Node are allowed through the")
        print("       Kafka security group. From anywhere else, this WILL fail.")
        print("       (That is not a bug. That is the requirement, working.)\n")
        return 1

    count = 0
    try:
        for msg in consumer:
            count += 1
            cat_message(msg, count)
            if args.max and count >= args.max:
                print(f"\n{GREY}  Reached --max {args.max}. Stopping.{RESET}\n")
                break
    except KeyboardInterrupt:
        print(f"\n\n{GREY}  Interrupted.{RESET}")
    finally:
        consumer.close()
        print(f"\n{BOLD}  Total messages consumed: {count}{RESET}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### 7.7 Run the whole thing

**Terminal 1 — start the consumer first, so it's watching:**

```bash
cd ~/nifi-kafka-app
source .venv/bin/activate
python consumer.py --from-beginning
```

```
==================================================================
  KAFKA CONSUMER — cat-ing S3 text files
==================================================================
  broker : 10.20.11.88:9092
  topic  : nifi-s3-files
  offset : earliest (replay all)
==================================================================
  Waiting for messages... (Ctrl+C to quit)
```

**Terminal 2 — fire the trigger:**

```bash
ssh -A -i ~/.ssh/aws-command-node ubuntu@<COMMAND_NODE_IP>
cd ~/nifi-kafka-app && source .venv/bin/activate
python trigger_nifi.py
```

```
==============================================================
  TRIGGERING NIFI
==============================================================
  Endpoint : http://10.20.11.42:9999/trigger
  Payload  : {"action": "pull_from_s3", "prefix": "incoming/"}
--------------------------------------------------------------
  Status   : 200
==============================================================

  ✅ NiFi accepted the trigger.
     It is now: listing S3 -> fetching objects -> publishing to Kafka.
```

**Back in Terminal 1, within a couple of seconds:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📄 MESSAGE #1
  file      : incoming/file1.txt
  topic     : nifi-s3-files  partition 0  offset 0
  timestamp : 14:23:07
  size      : 45 bytes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ▼ CONTENTS (this is the `cat`)
──────────────────────────────────────────────────────────────────
  Hello from the first file. This is line one.
──────────────────────────────────────────────────────────────────

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📄 MESSAGE #2
  file      : incoming/file2.txt
  topic     : nifi-s3-files  partition 1  offset 0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ▼ CONTENTS (this is the `cat`)
──────────────────────────────────────────────────────────────────
  Second file. NiFi should pull this out of S3.
──────────────────────────────────────────────────────────────────

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📄 MESSAGE #3
  file      : incoming/file3.txt
  topic     : nifi-s3-files  partition 2  offset 0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ▼ CONTENTS (this is the `cat`)
──────────────────────────────────────────────────────────────────
  Third file.
  With multiple lines.
  And a third line.
──────────────────────────────────────────────────────────────────
```

🎉 **That's the whole system working.**

Trace what just happened:

1. Python sent an HTTP POST to a server **with no public IP**, over a **VPC peering connection**.
2. NiFi listed an S3 bucket using an **IAM role** — no keys anywhere.
3. It fetched the objects over a **free VPC Gateway Endpoint**, never touching the internet.
4. It published them to Kafka, allowed through the firewall **only because it wears the NiFi badge**.
5. Python consumed them, allowed through **only because the Command Node wears the Command badge**.
6. Every byte stayed inside AWS's private network the entire time.

---

## 8. Running the Whole Thing End to End

The command sequence, start to finish:

```bash
# --- ON YOUR LAPTOP ---
ssh-add ~/.ssh/aws-command-node
ssh -A -i ~/.ssh/aws-command-node ubuntu@<COMMAND_NODE_IP>

# --- ON THE COMMAND NODE ---
# 1. Build the infrastructure (8-12 min)
cd ~/infra
terraform init
terraform plan -out=tfplan     # READ THIS OUTPUT
terraform apply tfplan

# 2. Configure the servers (10-20 min)
cd ansible
ansible all -m ping            # sanity check
ansible-playbook site.yml

# 3. Load some data
BUCKET=$(terraform -chdir=~/infra output -raw s3_bucket_name)
echo "test content" > t.txt
aws s3 cp t.txt "s3://$BUCKET/incoming/"

# 4. Build the flow in the NiFi UI (see 7.3), start all processors

# 5. Watch + trigger
cd ~/nifi-kafka-app && source .venv/bin/activate
python consumer.py --from-beginning &     # background
python trigger_nifi.py
```

### Automate future runs

**`~/deploy.sh`:**

```bash
#!/bin/bash
set -euo pipefail

echo "▶ Terraform..."
cd ~/infra
terraform init -upgrade
terraform validate
terraform plan -out=tfplan
read -rp "Apply this plan? (yes/no) " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
terraform apply tfplan

echo "▶ Waiting 60s for instances to boot..."
sleep 60

echo "▶ Ansible..."
cd ansible
ansible-playbook site.yml

echo "▶ Done."
terraform -chdir=~/infra output
```

```bash
chmod +x ~/deploy.sh
```

Note the `read -rp` confirmation. **Never fully automate `terraform apply` without a human reading the plan** — not until you have a proper CI pipeline with policy checks.
---

## 9. Deep Background: How Every Piece Actually Works

Now that it's running, here's the *why* behind everything.

### 9.1 How a packet actually gets from your browser to NiFi

Follow one HTTPS request all the way down:

```
1.  Browser looks up nifi.example.com
        |
        v  DNS query -> Route53
2.  Route53 has an ALIAS record. It resolves it to the ALB's
    current IPs and returns them. (ALIAS is resolved server-side
    by AWS, which is why it's free and why it works at the apex.)
        |
        v
3.  Browser opens TCP :443 to the ALB's public IP.
    (The ALB sits in a PUBLIC subnet. It has a route to the IGW.)
        |
        v
4.  ALB Security Group check:
       "Is the source IP in [my_ip_cidr]?"
       YES -> allow.   NO -> silently DROPPED. (Not rejected. Dropped.
                             The attacker's connection just hangs.)
        |
        v
5.  TLS handshake. ALB presents the ACM certificate.
    Browser validates it against Amazon's public CA. Padlock appears.
        |
        v
6.  ALB decrypts the request. Reads the Host header. Matches the
    listener rule. Picks a healthy target from the target group.
        |
        v
7.  ALB opens a NEW connection to NiFi at 10.20.11.42:8443.
    (This is a completely separate TCP connection! The ALB is a
     PROXY, not a router. Your browser never talks to NiFi directly.)
        |
        v
8.  NiFi Security Group check:
       "Is the source SG = the ALB's SG?"
       YES -> allow.   Anything else -> DROPPED.
        |
        v
9.  NiFi checks nifi.web.proxy.host against the Host header.
       Match -> serve the page.
       No match -> "invalid host header" error. (THE classic bug.)
        |
        v
10. Response travels back the same way. Note: NO security group rule
    was needed for the reply. Security groups are STATEFUL -- the
    return path is automatically permitted.
```

**The key realization:** at step 7, the ALB opened a *new* connection. This is why NiFi never sees your browser's IP directly (it sees the ALB's), why the ALB can hold the public cert while NiFi holds a self-signed one, and why NiFi can live safely in a subnet with no internet route at all.

### 9.2 How the IAM role credential magic actually works

This is worth understanding because it's the security foundation of the whole design.

```
NiFi's Java code calls: s3Client.listObjects("my-bucket")
        |
        v
AWS SDK: "I need credentials. Let me walk the default chain."
        |
        ├─ 1. Java system properties?      -> not set
        ├─ 2. Environment variables?       -> not set
        ├─ 3. ~/.aws/credentials file?     -> DOESN'T EXIST (good!)
        └─ 4. EC2 Instance Metadata?       -> let's try...
                |
                v
        PUT http://169.254.169.254/latest/api/token
             (IMDSv2 requires a token first)
                |
                v
        GET http://169.254.169.254/latest/meta-data/iam/security-credentials/
             -> "nifi-platform-dev-nifi-role"
                |
                v
        GET .../security-credentials/nifi-platform-dev-nifi-role
                |
                v
        {
          "AccessKeyId":     "ASIA...",       <- note: ASIA, not AKIA
          "SecretAccessKey": "...",           <- TEMPORARY
          "Token":           "...",           <- SESSION TOKEN
          "Expiration":      "2026-07-13T21:00:00Z"   <- EXPIRES!
        }
                |
                v
        SDK caches these, uses them, and AUTOMATICALLY refreshes
        them ~5 minutes before expiry. Forever. With zero code.
```

Notice the access key starts with **`ASIA`**, not `AKIA`. That prefix is how AWS marks a *temporary* credential. A long-lived IAM user key starts with `AKIA` and never expires — which is exactly why they're dangerous.

Every AWS SDK in every language does this. **You write zero lines of credential code.** That's why the NiFi credentials service was blank.

And here's the killer detail: because those credentials expire in a few hours and rotate automatically, **even if an attacker steals them, they're worthless by dinnertime.** A leaked `AKIA` key works forever.

### 9.3 How Kafka's log actually works on disk

Kafka's magic is that it's mostly *not* magic — it's an append-only file, and the OS does the hard work.

```
Topic: nifi-s3-files
  |
  ├── Partition 0  --> /var/lib/kafka/nifi-s3-files-0/
  │                      ├── 00000000000000000000.log     <- the messages
  │                      ├── 00000000000000000000.index   <- offset -> byte position
  │                      └── 00000000000000000000.timeindex
  ├── Partition 1  --> /var/lib/kafka/nifi-s3-files-1/
  └── Partition 2  --> /var/lib/kafka/nifi-s3-files-2/
```

A `.log` file is literally just messages appended one after another:

```
[offset 0][length][crc][key][value: "Hello from the first file..."]
[offset 1][length][crc][key][value: "Second file. NiFi should..."]
[offset 2][length][crc][key][value: "Third file.\nWith multiple..."]
                                     ^
                                     always append here. Never seek. Never edit.
```

Why is this so fast? Three reasons:

1. **Sequential writes.** Appending to the end of a file is the fastest thing a disk can do. On spinning rust it's ~100x faster than random writes. Even on SSDs it's substantially faster.
2. **The page cache.** Kafka doesn't cache messages in the JVM heap. It writes to the OS page cache and lets Linux handle it. A message written a second ago is almost certainly still in RAM when a consumer asks for it. Kafka gets a huge cache for free and never garbage-collects it.
3. **Zero-copy (`sendfile`).** When a consumer reads, Kafka calls the `sendfile()` syscall, which copies bytes **directly from the page cache to the network card** — the data never enters userspace, never enters the JVM. This is why one modest Kafka broker can saturate a 10Gb NIC.

**Partitions are the unit of parallelism.** Three partitions means up to three consumers in a group can read simultaneously, one each. A fourth consumer in that group would sit idle. This is why partition count matters: *it is the ceiling on your consumer parallelism, and you cannot easily lower it later.*

**Ordering guarantee, precisely:** Kafka guarantees order **within a partition**, not across the topic. If you need file A processed before file B, they must land in the same partition (use the same message key). Our three test files landed in three different partitions, which is why they may print out of order.

### 9.4 How Terraform's dependency graph works

Look at this snippet:

```hcl
resource "aws_subnet" "private" {
  vpc_id = aws_vpc.main.id     # <-- reference
}
```

That single reference `aws_vpc.main.id` does something important: it tells Terraform **"the subnet depends on the VPC."** Terraform builds a DAG (directed acyclic graph) from every such reference:

```
                    aws_vpc.main
                    /     |      \
                   /      |       \
      aws_subnet.public   |    aws_internet_gateway.main
              |           |              |
              |    aws_subnet.private    |
              |           |              |
       aws_nat_gateway ───┘              |
              |                          |
      aws_route_table.private     aws_route_table.public
```

Then it walks the graph, building **everything on the same level in parallel**. Both subnets are created at the same instant. The two route tables are created at the same instant. This is why 43 resources take 8 minutes instead of 43 sequential API calls.

You almost never need `depends_on`. If you find yourself writing it, ask whether you've missed a natural reference. The exception is *implicit* dependencies that Terraform can't see — like our NAT Gateway needing the IGW to be attached first, even though it doesn't reference it. That's a legitimate `depends_on`.

### 9.5 Ansible's push model vs. an agent

| | **Ansible (push)** | **Puppet/Chef (pull + agent)** |
|---|---|---|
| Software on target | **None.** Just SSH + Python | A daemon, running forever |
| How it runs | You run it, it pushes | Agent wakes up every 30 min and pulls |
| Firewall | Needs SSH inbound | Needs outbound to a master server |
| Scale ceiling | ~hundreds of hosts comfortably | Tens of thousands |
| Drift correction | Only when you run it | Continuous, automatic |
| Learning curve | Low (it's YAML) | High (DSL + a master server to run) |

Ansible's agentless model is why it won. There is nothing to install, nothing to keep running, nothing to upgrade on the fleet. If SSH works, Ansible works.

The tradeoff: Ansible does not correct drift on its own. If someone SSHes in and edits a config file by hand, Ansible won't notice until you run the playbook again. Puppet would fix it within 30 minutes. For most teams, running Ansible in CI on every merge closes that gap adequately.

### 9.6 What NiFi's provenance is really doing

Every time a FlowFile moves through *any* processor, NiFi writes a provenance event:

```
Event 1  RECEIVE   ListS3         file: incoming/file1.txt
Event 2  FETCH     FetchS3Object  downloaded 45 bytes from S3
Event 3  SEND      PublishKafka   sent to nifi-s3-files partition 0 offset 0
```

You can click any event in the UI and see:
- The **exact bytes** of the content before and after
- Every attribute at that moment
- The full lineage graph, backwards and forwards
- **Replay** — literally re-run this exact FlowFile from this exact point

That last one is the killer feature. A bug in a downstream processor? Fix it and *replay the original data.* You don't need to re-fetch from S3. You don't need the source system to still have the data. NiFi kept it.

This is why banks and hospitals use NiFi. When an auditor asks *"prove to me what happened to this specific record on March 3rd,"* NiFi can literally show them.

The cost: provenance eats disk. The default keeps 24 hours or 1GB. Plan storage accordingly — this is why we gave NiFi a 100GB volume.

---

## 10. Best Practices (And Why They Matter)

### 10.1 Security

| ✅ Do | ❌ Don't | Why it matters |
|---|---|---|
| Use IAM roles on EC2 | Put access keys in files/env vars | Bots scan every public GitHub commit within **seconds** for `AKIA`. People have woken to $50k+ crypto-mining bills. |
| Reference security groups | Hardcode CIDRs / IPs | IPs change on reboot. Badges don't. And a CIDR lets *any* box in that range in. |
| Put data servers in private subnets | Give them public IPs | No route = unreachable. A firewall misconfiguration can't undo the absence of a road. |
| Restrict SSH to your IP | `0.0.0.0/0` on port 22 | Brute-force bots find open :22 within **minutes**. Genuinely minutes. |
| Enforce IMDSv2 (`http_tokens = required`) | Leave IMDSv1 enabled | IMDSv1 was the vector in the 2019 Capital One breach — an SSRF flaw let an attacker read role credentials. IMDSv2's token requirement kills that class of attack. |
| Encrypt EBS + S3 | Leave them plaintext | Free. Zero performance cost. Required by most compliance regimes. No reason not to. |
| Block ALL public S3 access | Trust bucket policies alone | Every "N million records exposed" headline is a public bucket. All four flags. |
| Restrict **egress** too | `0.0.0.0/0` outbound on everything | Egress is how data gets *exfiltrated*. Least privilege applies in both directions. |
| Rotate/expire secrets | Long-lived credentials | Temporary creds are worthless to an attacker within hours. |

**Scoping down the Command Node's `AdministratorAccess`:** in a real organization you'd replace it with a policy that grants only the services Terraform actually touches, and you'd add **permission boundaries** so the role can't create *another* role more powerful than itself (a classic privilege-escalation path). Tools like [iamlive](https://github.com/iann0036/iamlive) can watch a `terraform apply` and generate the exact minimal policy for you.

### 10.2 Terraform

| ✅ Do | ❌ Don't |
|---|---|
| **Always read `terraform plan` before `apply`** | Blindly apply. A `-/+` on a volume means your data is about to be destroyed. |
| Remote state in S3 with `use_lockfile = true` | Local `.tfstate` on a laptop. Lose it and Terraform forgets it owns your infra. |
| Pin provider versions with `~>` | Float on `latest`. A provider major-version release will break your build on a random Tuesday. |
| Run `terraform fmt` and `validate` in CI | Bikeshed about formatting in PRs. |
| Use variables + `.tfvars` | Hardcode account IDs and IPs in `.tf` files. |
| Add `validation` blocks | Discover a typo 6 minutes into an apply. |
| Tag everything (use `default_tags`) | Get a $400 bill and have no idea what caused it. |
| Separate state per environment | One giant state file for dev+prod. One bad apply and you've nuked prod. |
| Use `for_each` over `count` for named things | `count` — deleting item #2 from a list re-indexes and **destroys/recreates items 3, 4, 5...** This has caused real outages. |

**The `count` vs `for_each` trap, made concrete.** With `count` and a list of `["a","b","c"]`, if you remove `"b"`, Terraform sees:
- index 1 changes from `b` to `c` → **destroy and recreate**
- index 2 disappears → **destroy**

You wanted to delete one thing. You destroyed and rebuilt two. With `for_each` keyed on a map, each resource is tracked by *name*, and removing `"b"` destroys only `"b"`. Use `for_each` whenever the items have identities.

### 10.3 Ansible

| ✅ Do | ❌ Don't |
|---|---|
| Use modules (`apt:`, `template:`) | `shell:` / `command:` for everything |
| Make everything idempotent (`creates:`, `state: present`) | Write scripts that break on the second run |
| Dynamic inventory | A hardcoded list of IPs that rots |
| `--check --diff` before running for real | Discover a mistake in production |
| Roles for reusability | A single 2,000-line playbook |
| `ansible-vault` for secrets | Plaintext passwords in git |
| Enable `pipelining` | Accept a 40% slowdown for no reason |
| Handlers for restarts | Restart a service ten times in one run |

**Why `shell:` is a smell.** `shell: apt-get install -y nginx` runs every time, reports `changed` every time, and gives you no idea whether it did anything. `apt: name=nginx state=present` checks first, does nothing if it's there, and reports `ok`. Modules give you idempotency and reporting for free. Reach for `shell:` only when no module exists — and when you do, always add `creates:` or `changed_when:` so it stays honest.

### 10.4 Kafka

| ✅ Do | ❌ Don't |
|---|---|
| KRaft mode (3.3+) | Install ZooKeeper. **It was removed in Kafka 4.0.** |
| Set `advertised.listeners` to a reachable address | Leave it as `localhost` and spend an afternoon confused |
| 3+ brokers in production | Run a single broker and call it HA |
| `replication.factor >= 3`, `min.insync.replicas = 2` | RF=1 in prod (one disk dies = data gone) |
| Partition count ≥ expected consumer count | Under-partition. You can add partitions later, but **you cannot remove them**, and adding them breaks key-based ordering. |
| SASL_SSL + ACLs for real data | PLAINTEXT outside a locked-down VPC |
| Monitor consumer lag | Fly blind |
| Run `chrony`/NTP | Ignore clock drift. Kafka's timestamps and session timeouts genuinely depend on it. |

### 10.5 NiFi

| ✅ Do | ❌ Don't |
|---|---|
| Set `nifi.web.proxy.host` behind a proxy | Wonder why you get "invalid host header" (it's always this) |
| Back-pressure on connections | Let a queue grow until the disk fills and NiFi dies |
| Route `failure` somewhere real | Auto-terminate failures in production and silently lose data |
| Give the JVM real heap (4G+) | Run on a `t3.micro` and watch it OOM |
| Separate disks for the three repositories | Put flowfile/content/provenance on one volume and watch them fight for IOPS |
| Version-control flows (NiFi Registry) | Click-configure prod and have no way to roll back |
| Blank AWS credential service (use the role) | Paste an access key into the UI |

---

## 11. Pros and Cons of Every Choice We Made

### 11.1 Command Node vs. running Terraform from your laptop

| | **Command Node (what we built)** | **Laptop** | **CI/CD (GitHub Actions etc.)** |
|---|---|---|---|
| Setup effort | Medium | **Lowest** | Highest |
| Cost | ~$15/mo | **Free** | Free–$ |
| Credentials | ✅ IAM role, nothing on disk | ❌ Long-lived keys in `~/.aws` | ✅ OIDC, no keys |
| Reach private subnets | ✅ Yes, via peering | ❌ No (needs a VPN/bastion) | ⚠️ Needs a self-hosted runner |
| Consistent environment | ✅ One machine, one version | ❌ "Works on my machine" | ✅ Yes |
| Audit trail | ⚠️ Shell history | ❌ None | ✅ **Every change is a PR** |
| Team collaboration | ⚠️ Shared box, awkward | ❌ Poor | ✅ **Excellent** |
| Enforce plan review | ❌ Manual discipline | ❌ Manual discipline | ✅ **Enforced by the tool** |

**Verdict:** the Command Node is the right *learning* tool and a legitimate ops-workstation pattern. But **CI/CD is where you should end up.** The single biggest win of CI is that infrastructure changes become *pull requests* — someone else reads the `plan` before it runs.

**A modern alternative worth knowing:** skip SSH entirely and use **AWS Systems Manager Session Manager**. It gives you a shell on any instance with an SSM agent and role, through the AWS API. No SSH keys, no open port 22, no bastion. Every session is logged to CloudTrail. We already installed the SSM endpoints and roles for this — try it:

```bash
aws ssm start-session --target <instance-id>
```

If you can get this working, you can **delete every SSH rule and every key pair in the whole build.** That's a strictly better security posture.

### 11.2 EC2 for Kafka vs. Amazon MSK

| | **Self-managed on EC2 (ours)** | **Amazon MSK** | **MSK Serverless** |
|---|---|---|---|
| Monthly cost (small) | ~$30 | ~$150+ | Pay per GB |
| You patch the OS | ✅ Yes, you | ❌ AWS does | ❌ AWS does |
| You handle broker failure | ✅ Yes, at 3am | ❌ AWS does | ❌ AWS does |
| Full config control | ✅ **Total** | ⚠️ Most | ❌ Limited |
| Learning value | ✅ **Enormous** | ⚠️ Some | ❌ It's a black box |
| Time to running | ~20 min | ~30 min | ~5 min |
| Right for production? | ⚠️ Only with real ops staff | ✅ **Yes** | ✅ Yes, for spiky loads |

**Verdict:** we chose EC2 because **you learn far more.** Understanding `advertised.listeners`, KRaft, partitions, and the on-disk log format makes you dramatically better at debugging Kafka — even managed Kafka. But for anything with a real SLA, **use MSK.** Paying AWS $120/month to never get paged about a broker at 3am is an extremely good trade.

### 11.3 NiFi vs. the alternatives

| | **NiFi** | **Airflow** | **AWS Glue** | **Kafka Connect** | **A Lambda function** |
|---|---|---|---|---|---|
| Interface | Drag & drop | Python code | Managed Spark | Config files | Code |
| Best at | **Streaming, routing, real-time** | **Batch, scheduling, DAGs** | Big ETL | Kafka↔X only | Simple, event-driven |
| Data lineage | ✅ **World-class** | ⚠️ Basic | ⚠️ Some | ❌ | ❌ |
| Learning curve | Medium (UI helps a lot) | Medium (need Python) | Medium | Low | **Lowest** |
| Resource hunger | ❌ **Heavy JVM** | Medium | Serverless | Medium | **Tiny** |
| Version control | ⚠️ Needs NiFi Registry | ✅ **It's just code** | ✅ Code | ✅ Config | ✅ Code |
| Cost | Your EC2 | Your EC2 / MWAA | Per-job | Your EC2 | **~Free at low volume** |

**Honest verdict for *this specific* task:** if all you needed was "copy S3 text files into Kafka," a **20-line Lambda triggered by an S3 event** would be cheaper, simpler, and better. Genuinely.

NiFi earns its keep when you have:
- **Many** sources and sinks that keep changing
- Non-programmers who need to build and modify flows
- Regulatory requirements for **provenance and replay**
- Complex routing, enrichment, and format conversion in flight

We used NiFi here because **you asked for it** and because it teaches an enormous amount about data-flow architecture. Just know that "should I use NiFi?" has a real answer, and it's frequently "no."

### 11.4 VPC Peering vs. Transit Gateway vs. one big VPC

| | **Peering (ours)** | **Transit Gateway** | **One VPC** |
|---|---|---|---|
| Hourly cost | **$0** | ~$36/mo + attachments | $0 |
| Data cost | ~$0.01/GB | ~$0.02/GB | $0 (same-AZ) |
| Scales to N VPCs | ❌ N² connections. **10 VPCs = 45 peerings.** | ✅ **Hub & spoke, linear** | N/A |
| Transitive routing | ❌ **No.** A↔B and B↔C does NOT give A↔C. | ✅ Yes | N/A |
| Complexity | **Low** | Medium | **Lowest** |
| Blast radius | Small | Small | **Large** — one mistake affects everything |

**Verdict:** peering is right for 2 VPCs. It is *actively wrong* for 10 — the N² explosion and the lack of transitive routing will bury you. The moment you have more than about 4 VPCs, move to **Transit Gateway**.

**And yes** — you could have avoided this entirely by putting the Command Node *inside* the data VPC. That's simpler and cheaper. We used two VPCs deliberately, because separating your *control plane* from your *data plane* is a genuinely good pattern: you can destroy and rebuild the entire data VPC without touching the machine that does the destroying.

### 11.5 NAT Gateway vs. the alternatives

| | **NAT Gateway (ours)** | **NAT Instance** | **VPC Endpoints only** | **No egress at all** |
|---|---|---|---|---|
| Cost | **~$32/mo + $0.045/GB** 💸 | ~$4/mo (t3.nano) | ~$7/mo per interface endpoint | **$0** |
| Managed by AWS | ✅ | ❌ You patch it | ✅ | N/A |
| Bandwidth | Up to 45 Gbps | Limited by instance | N/A | N/A |
| Single point of failure | ❌ (AZ-redundant within an AZ) | ✅ **Yes** | ❌ | N/A |
| Can `apt install` | ✅ | ✅ | ❌ | ❌ |

**The NAT Gateway is the most expensive line item in this entire build** — roughly a third of the total. Three ways to reduce it:

1. **Add more VPC endpoints.** The S3 Gateway endpoint we built is **free** and already saves you all S3 traffic charges. Add gateway/interface endpoints for anything else you call often.
2. **Bake AMIs.** Use **Packer** to pre-build an AMI with Java, NiFi, and Kafka already installed. Then the instances never need to download anything, and you can **delete the NAT Gateway entirely.** This is the professional answer and it's a genuinely large saving.
3. **NAT instance.** A `t3.nano` running as a NAT saves ~$28/month. It's a single point of failure and you have to patch it. Fine for dev, not for prod.

### 11.6 ALB vs. NLB vs. CloudFront

| | **ALB (ours)** | **NLB** | **CloudFront + ALB** |
|---|---|---|---|
| OSI Layer | 7 (HTTP) | 4 (TCP) | 7 + global edge |
| Path-based routing | ✅ | ❌ | ✅ |
| Latency | ~ms | **µs** | Lowest for global users |
| Static IP | ❌ | ✅ | ❌ |
| WebSockets | ✅ | ✅ | ✅ |
| Built-in WAF | ✅ | ❌ | ✅ |
| Cost | ~$16/mo + LCU | ~$16/mo | + CloudFront usage |

**Verdict:** ALB is right here — NiFi speaks HTTP, and we want HTTPS termination and health checks. Use an **NLB** when you need raw TCP (e.g., exposing **Kafka** itself to external clients) or a static IP for a partner's firewall allow-list. Add **CloudFront** if users are global or you want AWS WAF + DDoS protection at the edge.

---

## 12. Troubleshooting: When Things Break

### 🔴 `Permission denied (publickey)` when SSHing

Check, in this order:
```bash
chmod 600 ~/.ssh/aws-command-node          # SSH refuses keys others can read
ssh -i ~/.ssh/aws-command-node ubuntu@IP   # Ubuntu AMI = "ubuntu", NOT "ec2-user"
ssh -vvv -i ~/.ssh/aws-command-node ubuntu@IP   # verbose: shows the real reason
```
90% of the time it's the **username**. Ubuntu is `ubuntu`. Amazon Linux is `ec2-user`. Debian is `admin`. RHEL is `ec2-user`.

### 🔴 `Unable to locate credentials`

The IAM role isn't attached, or hasn't propagated.
```bash
aws sts get-caller-identity   # should show "assumed-role/..."
# If it fails: EC2 -> Instance -> Actions -> Security -> Modify IAM role
# Then wait 30 seconds. It's not instant.
```

### 🔴 Ansible: `UNREACHABLE`

```bash
# 1. Did you SSH with -A?
ssh-add -l                    # if this errors, you forgot -A. Log out, ssh -A back in.

# 2. Can you reach the host at all?
nc -zv 10.20.11.42 22

# 3. Is the peering route actually there?
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$COMMAND_VPC_ID" \
  --query 'RouteTables[].Routes[?VpcPeeringConnectionId!=`null`]'
# If this is empty, the "command_to_data" route didn't apply.
```

### 🔴 NiFi: "System Error: invalid host header"

**It is always `nifi.web.proxy.host`.** Every time.
```bash
ansible role_nifi -b -a "grep proxy.host /opt/nifi/conf/nifi.properties"
# Must contain your ALB's FQDN. Fix roles/nifi/templates/nifi.properties.j2
# and re-run the playbook.
```

### 🔴 ALB target shows "unhealthy"

```bash
aws elbv2 describe-target-health --target-group-arn <ARN>
```

| Reason code | What it means | Fix |
|---|---|---|
| `Target.Timeout` | ALB can't reach NiFi | NiFi SG must allow 8443 **from the ALB's SG** |
| `Target.ResponseCodeMismatch` | NiFi replied, but with the wrong code | Health check `matcher` must include **`401`** — NiFi returns 401 when healthy-but-unauthenticated! |
| `Target.FailedHealthChecks` | NiFi is genuinely down or still booting | `systemctl status nifi`. **Give it 4 minutes** — NiFi boots slowly. |

That `401` one catches everyone. A 401 means *"I'm alive and asking who you are"* — which is a **healthy** NiFi. If your matcher is only `200`, the ALB will mark a perfectly working NiFi as unhealthy forever.

### 🔴 Kafka: consumer connects, then hangs forever

**This is `advertised.listeners`. It is essentially always `advertised.listeners`.**

```bash
ansible role_kafka -b -a "grep advertised /opt/kafka/config/kraft/server.properties"
```

It **must** be the private IP the client can actually reach. If it says `localhost`, the client dutifully reconnects to *its own* localhost, finds nothing, and waits until the heat death of the universe. No error. Just silence.

### 🔴 Kafka: `NoBrokersAvailable`

```bash
# Is it running?
ansible role_kafka -b -a "systemctl is-active kafka"

# Look at the actual error
ansible role_kafka -b -a "tail -50 /opt/kafka/logs/server.log"

# Can you reach the port from here?
nc -zv 10.20.11.88 9092
```

If `nc` fails **and** Kafka is running, it's the security group. Confirm the Command Node's SG is in Kafka's ingress list (test 3 in section 5.14).

If you're running the consumer from **anywhere except the Command Node or NiFi**, it *will* fail — and **that is the requirement working correctly**, not a bug.

### 🔴 Terraform: `Error acquiring the state lock`

Someone (maybe a crashed previous run) holds the lock.
```bash
# Only after you're CERTAIN no other apply is running:
terraform force-unlock <LOCK_ID>
```
Never force-unlock while a colleague might be mid-apply. You'll corrupt the state.

### 🔴 The `error: externally-managed-environment` pip error

You forgot the venv.
```bash
source ~/nifi-kafka-app/.venv/bin/activate
```
**Do not** use `--break-system-packages`. It does what it says.

### 🔴 Messages published but the consumer sees nothing

```bash
# Is there actually anything in the topic?
ansible role_kafka -b -a \
  "/opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
   --bootstrap-server localhost:9092 --topic nifi-s3-files"
# Output like "nifi-s3-files:0:3" means partition 0 has 3 messages.
# All zeros? NiFi never published. Check NiFi's PublishKafka bulletin.
```

If messages **are** there but your consumer shows nothing: your consumer group already committed past them. Either:
```bash
python consumer.py --from-beginning --group brand-new-group-name
```
A fresh `group_id` has no committed offset, so `auto_offset_reset=earliest` applies and it replays from 0.

---

## 13. Cost Estimate and How to Turn It All Off

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
| Elastic IP (for NAT) | in use | $0.00 |
| SSM Interface Endpoints | 3 × ~$7.30 | $21.90 |
| S3 Gateway Endpoint | — | **$0.00** ✅ |
| Route53 hosted zone | 1 | $0.50 |
| ACM certificate | 1 | **$0.00** ✅ |
| S3 storage | ~1 GB | $0.02 |
| VPC peering | hourly | **$0.00** ✅ |
| | **TOTAL** | **≈ $197/month** |

### 💰 Cutting it down

| Action | Saves | Trade-off |
|---|---|---|
| **Stop instances when not in use** | ~$85/mo | You pay only EBS. **Biggest single win.** |
| Delete the 3 SSM endpoints | $22/mo | Lose keyless SSM shell; back to SSH |
| Bake an AMI with Packer, delete NAT GW | **$33/mo** | Real effort, but the *right* fix |
| NAT instance instead of NAT GW | $28/mo | Single point of failure, you patch it |
| Downsize NiFi to t3.medium | $30/mo | NiFi will be sluggish; may OOM |
| Delete the ALB, use an SSH tunnel | $16/mo | No public endpoint, no TLS |
| Buy a 1-yr Savings Plan | ~30% off EC2 | You're committed for a year |

**Stop, don't destroy, between sessions:**

```bash
# Stop (you keep the disks and the config; you pay only ~$18/mo for EBS)
aws ec2 stop-instances --instance-ids \
  $(aws ec2 describe-instances \
     --filters "Name=tag:Project,Values=nifi-platform" \
                "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' --output text)

# Start again tomorrow
aws ec2 start-instances --instance-ids <ids>
```

> ⚠️ **Stopped instances get NEW private IPs when restarted** (unless you attached an Elastic Network Interface). After a start, **re-run the Ansible playbook** so NiFi learns Kafka's new address. This is a great argument for using an ENI or DNS names instead of raw IPs in production.

### 🔥 Destroy everything

```bash
cd ~/infra

# Empty the bucket first -- Terraform CANNOT delete a non-empty bucket,
# and versioning means "delete all objects" isn't enough.
BUCKET=$(terraform output -raw s3_bucket_name)
aws s3 rm "s3://$BUCKET" --recursive
aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
  --bucket "$BUCKET" --output json \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true

# Now destroy. READ THE PLAN.
terraform plan -destroy
terraform destroy
```

Type `yes`. Takes ~5 minutes (the NAT Gateway and ALB are slow to delete).

**Then clean up the manual bits:**
1. Terminate the `command-node` instance (Terraform doesn't manage it — you built it by hand)
2. Delete the `command-node-sg` security group
3. Delete the `command-node-role` IAM role
4. Empty and delete the `tfstate-cmdnode-*` bucket
5. **Check the Billing dashboard tomorrow.** Confirm charges have stopped.

**Verify nothing survived:**

```bash
# NAT Gateways are the expensive thing. Make SURE they're gone.
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId'
# Should be: []

aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
# Should be: []

aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
# Should be: []
```

---

## 14. Glossary

| Term | Plain English |
|---|---|
| **AMI** | Amazon Machine Image — a snapshot of a whole OS, used as the template for a new server |
| **ACM** | AWS Certificate Manager — gives you free HTTPS certificates |
| **ALB** | Application Load Balancer — the doorman that understands HTTP |
| **Ansible** | Tool that SSHes into servers and configures them. No agent needed. |
| **Availability Zone (AZ)** | One physical data center building |
| **Bastion / Jump box** | A server you SSH into first, to reach others. (Our Command Node.) |
| **CIDR** | `10.0.0.0/16` — a way to write "a range of IP addresses" |
| **Consumer group** | A team of Kafka readers sharing one bookmark. Adding readers to a group splits the work. |
| **Declarative** | You describe the *result*; the tool figures out the steps |
| **DAG** | Directed acyclic graph — a dependency map with no loops |
| **Egress** | Traffic going **out** |
| **FlowFile** | NiFi's data package: content + attributes (an envelope with a label) |
| **IAM Role** | A uniform of permissions that a *machine* can wear. **The correct alternative to access keys.** |
| **Idempotent** | Running it twice gives the same result as running it once |
| **IGW** | Internet Gateway — the door between a VPC and the internet |
| **IMDSv2** | The token-protected instance metadata service. Where role credentials come from. |
| **Ingress** | Traffic coming **in** |
| **Instance Profile** | The wrapper that lets an EC2 instance actually wear an IAM role |
| **KRaft** | Kafka's built-in coordination mode. **Replaced ZooKeeper.** |
| **NAT Gateway** | One-way mirror: private servers can reach out, nothing can reach in. **Expensive.** |
| **Offset** | A consumer's bookmark in a Kafka partition |
| **Partition** | One slice of a Kafka topic. Determines max consumer parallelism. |
| **PEP 668** | The rule that makes Ubuntu 24.04 refuse `pip install` outside a venv |
| **Private subnet** | A subnet with **no route** to the internet. Not "firewalled" — *unroutable*. |
| **Processor** | One box on the NiFi canvas that does one job |
| **Provenance** | NiFi's complete audit trail of everything that happened to every FlowFile |
| **Route table** | The signposts that decide where a packet goes next |
| **Security Group** | A stateful, allow-only firewall around an instance. **Can reference other SGs — this is the key trick.** |
| **State (Terraform)** | The file mapping "what I called X" → "the real AWS resource ID". Guard it. |
| **Stateful (firewall)** | If you allow it in, the reply is automatically allowed out |
| **Target group** | The ALB's list of "who is actually behind the door" |
| **Terraform** | Turns a text file into cloud infrastructure |
| **Topic** | One Kafka logbook |
| **venv** | An isolated Python sandbox |
| **VPC** | Your own private network inside AWS |
| **VPC Endpoint** | A private road from your VPC straight to an AWS service. The **S3 Gateway one is free** — always use it. |
| **VPC Peering** | A private tunnel between two VPCs. No hourly cost. Not transitive. |
| **Zero-copy** | Kafka sending bytes straight from page cache to NIC, never entering userspace. Why it's so fast. |

---

## Where to Go Next

You now have a working, security-conscious data platform. Here's the honest list of what's still missing before this is production-grade — roughly in priority order:

1. **Move Terraform into CI/CD.** GitHub Actions with OIDC (no stored AWS keys). Infrastructure changes become pull requests that someone reviews. This is the single biggest maturity jump available to you.
2. **Kafka: 3 brokers, RF=3, `min.insync.replicas=2`.** One broker is not high availability, it's a single point of data loss.
3. **Enable Kafka SASL_SSL + ACLs.** PLAINTEXT is only acceptable because of the security group lockdown. Belt *and* braces.
4. **NiFi Registry.** Put your flows in version control. Clicking config into prod with no rollback is how outages happen.
5. **Bake AMIs with Packer.** Faster boots, reproducible builds, and it lets you **delete the NAT Gateway** — a real $33/month saving and one less moving part.
6. **Observability.** CloudWatch alarms on ALB 5xx, Kafka consumer lag, disk usage. You cannot operate what you cannot see.
7. **Auto Scaling Group for NiFi.** Right now, if NiFi's instance dies, it stays dead. An ASG replaces it automatically.
8. **AWS WAF on the ALB.** Rate limiting and common-exploit rules at the edge.
9. **Ditch SSH entirely for SSM Session Manager.** We already built the endpoints and roles. If you get this working, you can delete every key pair and every port-22 rule in the build.
10. **Backups.** EBS snapshots on a schedule. S3 versioning is already on. Test a restore — an untested backup is not a backup.

But you have the foundation. And more importantly, you understand *why* every piece is there:

- Why Kafka's security group names **exactly two badges** and not a single IP address
- Why NiFi has **no public IP** and why that's stronger than any firewall rule
- Why the AWS credentials field in NiFi is **blank** — and why blank is the *most secure* possible value
- Why `terraform plan` is the most important command you will ever type
- Why `advertised.listeners` will be the first thing you check the next time a Kafka client hangs

That understanding is the actual deliverable. The infrastructure is just what fell out of it.
