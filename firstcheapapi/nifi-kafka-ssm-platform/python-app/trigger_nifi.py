#!/usr/bin/env python3
"""
trigger_nifi.py
===============
Sends an HTTP POST to NiFi's HandleHttpRequest processor, which kicks
off the flow:  ListS3 -> FetchS3Object -> PublishKafka.

Think of NiFi as a vending machine that only dispenses when you push
the button. This script pushes the button.

This runs on the COMMAND NODE. It reaches NiFi on port 9999, which is
allowed because the Command Node's security group is the only source
permitted on that port.

Note: there is no SSH anywhere in this system. This is a plain HTTP
call over the VPC peering connection.

Usage:
    python trigger_nifi.py
    python trigger_nifi.py --prefix incoming/ --wait
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

# Where the terraform code lives, relative to this file.
INFRA_DIR = os.environ.get(
    "INFRA_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "terraform")),
)


def terraform_output(name: str) -> str:
    """Read a value straight out of Terraform state.

    Much better than hardcoding IPs: if you rebuild the infrastructure,
    this picks up the new addresses automatically.
    """
    try:
        result = subprocess.run(
            ["terraform", f"-chdir={INFRA_DIR}", "output", "-raw", name],
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
        print("[!] terraform is not on PATH. Are you on the Command Node?", file=sys.stderr)
        sys.exit(1)


def build_session() -> requests.Session:
    """A session with automatic retries and exponential backoff.

    NiFi can be briefly unresponsive during a flow restart. Rather than
    failing instantly, retry with increasing delays: 1s, 2s, 4s...
    This is standard practice for ANY network call.
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
            timeout=(5, 60),  # (connect timeout, read timeout)
            headers={"Content-Type": "application/json"},
        )
    except requests.exceptions.ConnectTimeout:
        print("[!] TIMED OUT connecting to NiFi.")
        print("    Likely causes:")
        print("      - The HandleHttpRequest processor isn't STARTED (green)")
        print("      - The NiFi security group doesn't allow :9999 from here")
        print("      - You aren't running this on the Command Node")
        return False
    except requests.exceptions.ConnectionError as e:
        print(f"[!] CONNECTION REFUSED: {e}")
        print("    Nothing is listening on 9999. Start the processor in NiFi.")
        print("    Get a shell to check:  aws ssm start-session --target <nifi-instance-id>")
        return False

    print(f"  Status   : {response.status_code}")
    if response.text:
        print(f"  Body     : {response.text[:400]}")
    print("=" * 62)

    if response.status_code == 200:
        print("\n  NiFi accepted the trigger.")
        print("  It is now: listing S3 -> fetching objects -> publishing to Kafka.")
        print("\n  Run  python consumer.py  to watch the contents arrive.\n")
        return True

    print(f"\n  Unexpected status {response.status_code}\n")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Tell NiFi to pull text files from S3")
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
