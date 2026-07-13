# Troubleshooting

Ordered roughly by how often each one actually happens.

---

## SSM

### Instance doesn't appear in SSM / `TargetNotConnected`

**There is no SSH fallback in this build.** If SSM is broken, you have no access. Work this list in order — it's almost always #3.

```bash
# 1. Wait. A fresh instance takes ~90 seconds to register. Don't panic early.

# 2. Is the role attached, and does it have the right policy?
aws ec2 describe-instances --instance-ids i-0abc \
  --query 'Reservations[0].Instances[0].IamInstanceProfile'
aws iam list-attached-role-policies --role-name nifi-platform-dev-nifi-role
# Must include AmazonSSMManagedInstanceCore.

# 3. DO ALL THREE VPC ENDPOINTS EXIST?   <-- usually this
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-0abc" \
  --query 'VpcEndpoints[].ServiceName' --output text
```

You must see **all three**:
- `com.amazonaws.us-east-1.ssm`
- `com.amazonaws.us-east-1.ssmmessages`
- `com.amazonaws.us-east-1.ec2messages` ← **the one everyone forgets**

`ec2messages` sounds legacy and optional. It is neither. Without it the agent registers and then immediately shows "Connection lost."

```bash
# 4. Is private DNS on?
aws ec2 describe-vpc-endpoints \
  --query 'VpcEndpoints[].{Svc:ServiceName,DNS:PrivateDnsEnabled}' --output table
# All three must be true. If false, the agent resolves the PUBLIC endpoint
# and tries to go out via NAT. It'll hang.

# 5. Can the instance egress on 443?
# The instance SG needs an EGRESS rule for 443. The agent connects OUT.
# Lock egress to nothing and you have permanently locked yourself out.
```

### "I think I locked myself out"

You mostly can't — that's the point of SSM. As long as the instance runs, the agent lives, and the role is attached, you're in. There's no key to lose.

But if you **detach the IAM role** or **delete the SSM endpoints**, you have. Recovery: re-attach the role via the AWS API (a control-plane operation — still available to you), wait 90 seconds, reconnect.

---

## Ansible

### Vague S3 or AccessDenied error on every task

Three causes:

1. **`ANSIBLE_AWS_SSM_BUCKET` isn't set.**
   ```bash
   export ANSIBLE_AWS_SSM_BUCKET=$(terraform -chdir=terraform output -raw ssm_transfer_bucket)
   ```
   `site.yml` has a preflight assert that catches this with a clear message. If you skipped the preflight, this is your problem.

2. **The *instance* role lacks `s3:GetObject` on the transfer bucket.** The controller uploading the module isn't enough — the *target host* has to download it. Both roles need the `ssm_transfer_access` policy.

3. **`session-manager-plugin` isn't installed on the controller.**
   ```bash
   bash scripts/install-session-manager-plugin.sh
   ```

### `UNREACHABLE` / plugin not found

The `community.aws` collection isn't installed:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

### Everything is slow

It is. Every Ansible module round-trips through S3 (SSM has no file channel). Expect 1.5–3× slower than SSH. Raise `forks` in `ansible.cfg`.

**Do not enable `pipelining`.** It's an SSH optimization; it breaks the SSM plugin.

### Inventory shows IPs instead of instance IDs

Your `inventory.aws_ec2.yml` has `hostnames: private-ip-address`. SSM addresses hosts by **instance ID**, not IP. It must be:

```yaml
hostnames:
  - instance-id
```

Get this wrong and you'll see `TargetNotConnected` against something like `10.20.11.42` — a maddening error, because it's a *hostname* problem masquerading as a *network* problem.

---

## NiFi

### "System Error: The request contained an invalid host header"

**It is `nifi.web.proxy.host`.** It is always `nifi.web.proxy.host`.

NiFi validates the HTTP `Host` header. Behind an ALB that header is `nifi.yourdomain.com`, which NiFi has never heard of, so it rejects every request.

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw nifi_instance_id)
sudo grep proxy.host /opt/nifi/conf/nifi.properties
```

It must contain your ALB's FQDN. Fix `ansible/roles/nifi/tasks/main.yml` and re-run the playbook.

### ALB target is "unhealthy"

```bash
aws elbv2 describe-target-health --target-group-arn <ARN>
```

| Reason | Meaning | Fix |
|---|---|---|
| `Target.Timeout` | ALB can't reach NiFi | NiFi's SG must allow 8443 **from the ALB's SG** |
| `Target.ResponseCodeMismatch` | Wrong status code | The health check `matcher` **must include `401`** |
| `Target.FailedHealthChecks` | NiFi is down or still booting | Wait 4 minutes. NiFi boots slowly. |

That `401` catches everyone. A 401 means *"I'm alive and asking who you are"* — that's a **healthy** NiFi. If your matcher is only `200`, the ALB marks a perfectly working NiFi as unhealthy forever.

### NiFi takes forever to start

2–4 minutes is normal. It's unpacking hundreds of NAR bundles. Don't restart it; you'll just start the clock over.

---

## Kafka

### Consumer connects, then hangs forever with no error

**It is `advertised.listeners`.** It is essentially always `advertised.listeners`.

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw kafka_instance_id)
sudo grep advertised /opt/kafka/config/kraft/server.properties
```

Kafka's protocol: the client connects to the bootstrap server, asks "who are the brokers?", gets back the **advertised** address, then **disconnects and reconnects** to that address.

If it advertises `localhost`, the client dutifully reconnects to *its own* localhost, finds nothing, and waits forever. No error. Just silence. It must be the private IP the client can actually reach.

### `NoBrokersAvailable`

```bash
# Is it even running?
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=kafka" \
  --parameters 'commands=["systemctl is-active kafka"]'

# Can you reach the port?
nc -zv <kafka-ip> 9092
```

**If you're running the consumer from anywhere except the Command Node or NiFi, it will fail — and that is correct.** Kafka's security group admits exactly two source SGs. That's the requirement working, not a bug.

### Messages published but the consumer sees nothing

```bash
# Is anything actually in the topic?
aws ssm send-command --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=kafka" \
  --parameters 'commands=["/opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell --bootstrap-server localhost:9092 --topic nifi-s3-files"]'
```

Output like `nifi-s3-files:0:3` means partition 0 has 3 messages. All zeros → NiFi never published; check NiFi's PublishKafka bulletin.

Messages *are* there but you see nothing? Your consumer group already committed past them. Use a fresh group:

```bash
python consumer.py --from-beginning --group brand-new-name
```

A new `group_id` has no committed offset, so `auto_offset_reset=earliest` applies and it replays from 0.

---

## Terraform

### `Error acquiring the state lock`

A crashed run holds it. **Only** after you're certain nobody else is applying:

```bash
terraform force-unlock <LOCK_ID>
```

Force-unlocking while a colleague is mid-apply will corrupt your state.

### `BucketNotEmpty` on destroy

Versioned buckets keep old versions *and* delete markers. `aws s3 rm --recursive` isn't enough. Use `scripts/destroy.sh`, which purges both.

---

## Python

### `error: externally-managed-environment`

Ubuntu 24.04 enforces PEP 668. Use the venv:

```bash
source ~/.venvs/nifi-kafka/bin/activate
```

**Do not** use `--break-system-packages`. It is named after what it does. System Python runs `apt` itself; break it and you can lose the ability to install the thing that would fix it.
