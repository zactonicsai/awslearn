# Building the NiFi Flow

Terraform and Ansible get NiFi *running*. You still have to draw the flow. NiFi's whole point is that this part is drag-and-drop.

## The flow

```
[HandleHttpRequest] :9999
        |  ("the Python app poked me")
        v
   [ListS3]  ---> emits ONE FlowFile per object in the bucket.
        |         Content is EMPTY. The s3 key is in the ATTRIBUTES.
        |         It's a pointer, not the data.
        v
 [FetchS3Object] ---> reads those attributes, downloads the actual
        |             bytes into the FlowFile content.
        v
  [PublishKafka] ---> writes the bytes to topic 'nifi-s3-files'
        |
        v
[HandleHttpResponse] ---> "200 OK" back to the Python app
```

**Why split List and Fetch?** Listing 10,000 files is cheap. Downloading 10,000 files is not. Splitting them lets NiFi queue the pointers and fetch at a controlled rate. Same reason `ls` is fast and `cat *` is slow.

## Open the UI

```bash
terraform -chdir=terraform output -raw nifi_url
```

Open it in your **laptop's** browser — the ALB security group allows your IP.

Log in with `admin` and the password from `ansible/roles/nifi/defaults/main.yml`.

> **Blank page or "invalid host header"?** That's `nifi.web.proxy.host`. It's always that. See TROUBLESHOOTING.md.

## A) ListS3

Drag a Processor onto the canvas → search `ListS3` → Add. Right-click → **Configure** → **Properties**:

| Property | Value |
|---|---|
| Bucket | *your bucket* (`terraform output -raw s3_bucket_name`) |
| Region | `us-east-1` |
| Prefix | `incoming/` |
| AWS Credentials Provider Service | *see below* |

Click the **AWS Credentials Provider Service** dropdown → **Create new service** → `AWSCredentialsProviderControllerService` → click the gear to configure it.

### Leave every field blank. Then enable it.

> ### This is the payoff of the whole IAM design.
>
> With nothing configured, the AWS SDK falls back to its **default credential provider chain**. On EC2, the last link in that chain is the **instance metadata service** — which hands back the temporary credentials of the IAM role Terraform attached.
>
> So by configuring **nothing**, NiFi picks up the role automatically. Zero keys. Zero secrets. Nothing on disk to leak.
>
> If you paste an access key into those fields, you have just created exactly the vulnerability this entire build was designed to avoid. **Blank is correct. Blank is secure.**

**Scheduling** tab: Run Schedule `0 sec`, Timer driven.

## B) FetchS3Object

| Property | Value |
|---|---|
| Bucket | `${s3.bucket}` |
| Object Key | `${filename}` |
| Region | `us-east-1` |
| AWS Credentials Provider Service | *the same service* |

The `${...}` is **NiFi Expression Language** — it reads attributes off the incoming FlowFile. `ListS3` set them; `FetchS3Object` uses them.

## C) PublishKafka

| Property | Value |
|---|---|
| Kafka Brokers | `<KAFKA_IP>:9092` (`terraform output -raw kafka_bootstrap_server`) |
| Topic Name | `nifi-s3-files` |
| Delivery Guarantee | `Guarantee Replicated Delivery` |
| Use Transactions | `false` |

This connection works **only** because NiFi's security group is one of the two allowed sources on Kafka's port 9092.

## D) HandleHttpRequest

| Property | Value |
|---|---|
| Listening Port | `9999` |
| Allowed Paths | `/trigger` |
| HTTP Context Map | *create new* → `StandardHttpContextMap` → **enable it** |

## E) HandleHttpResponse

| Property | Value |
|---|---|
| HTTP Status Code | `200` |
| HTTP Context Map | *the same context map* |

## F) Wire it up

Drag from each processor's edge to the next:

| From | Relationship | To |
|---|---|---|
| HandleHttpRequest | `success` | ListS3 |
| ListS3 | `success` | FetchS3Object |
| FetchS3Object | `success` | PublishKafka |
| PublishKafka | `success` | HandleHttpResponse |

For the `failure` relationships on FetchS3Object and PublishKafka: right-click → **Configure** → **Settings** → check **Automatically Terminate**.

> In production you'd route failures to a retry loop or a dead-letter queue instead. Auto-terminating failures means silently dropping data. Fine for a demo; not fine for real.

## G) Start

Ctrl+A on the canvas → click ▶ **Start**.

Everything should turn **green**. A red warning triangle means a config error — hover over it and it tells you exactly what's wrong.

## Test it

```bash
BUCKET=$(terraform -chdir=terraform output -raw s3_bucket_name)
echo "Hello from the first file." > file1.txt
printf "Third file.\nWith multiple lines.\n" > file3.txt
aws s3 cp file1.txt "s3://$BUCKET/incoming/"
aws s3 cp file3.txt "s3://$BUCKET/incoming/"

source ~/.venvs/nifi-kafka/bin/activate
cd python-app
python consumer.py --from-beginning &
python trigger_nifi.py
```

The consumer prints each file's contents, `cat`-style.

## Save your work

The canvas is not in version control. If the instance dies, your flow is gone.

- **Right-click canvas → Download flow definition** → commit the JSON to git.
- Or run **NiFi Registry** and version flows properly.

Clicking config into a production system with no rollback path is how outages happen.
