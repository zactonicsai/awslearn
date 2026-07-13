#!/usr/bin/env python3
"""
consumer.py
===========
Reads messages off the Kafka topic and prints their contents to stdout,
exactly like `cat` does for a file.

WHY THIS ONLY WORKS FROM THE COMMAND NODE
------------------------------------------
Kafka's security group has exactly TWO ingress rules on port 9092:

    1. source_security_group_id = <NiFi's SG>
    2. source_security_group_id = <Command Node's SG>

That's it. No CIDR blocks. No 0.0.0.0/0. No port 22 anywhere on the
box either -- the whole build is SSM-only.

So if you run this from your laptop, or from any other EC2 instance,
the TCP connection will simply hang and then time out. That is not a
bug. That is the requirement, working exactly as specified.

Usage:
    python consumer.py                   # tail new messages
    python consumer.py --from-beginning  # replay everything
    python consumer.py --max 5           # stop after 5
"""

import argparse
import os
import subprocess
import sys
from datetime import datetime

from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable

INFRA_DIR = os.environ.get(
    "INFRA_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "terraform")),
)

# ANSI colour codes -- makes the output far easier to read
CYAN, GREEN, YELLOW, GREY, BOLD, RESET = (
    "\033[96m",
    "\033[92m",
    "\033[93m",
    "\033[90m",
    "\033[1m",
    "\033[0m",
)


def terraform_output(name: str) -> str:
    try:
        r = subprocess.run(
            ["terraform", f"-chdir={INFRA_DIR}", "output", "-raw", name],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        return r.stdout.strip()
    except Exception as e:  # noqa: BLE001
        print(f"[!] terraform output '{name}' failed: {e}", file=sys.stderr)
        sys.exit(1)


def cat_message(msg, index: int) -> None:
    """Print one Kafka message the way `cat` would print a file."""
    ts = datetime.fromtimestamp(msg.timestamp / 1000).strftime("%H:%M:%S")

    # NiFi puts the original S3 filename in a Kafka header.
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
    print(
        f"{GREY}  topic     : {msg.topic}  partition {msg.partition}  "
        f"offset {msg.offset}{RESET}"
    )
    print(f"{GREY}  timestamp : {ts}{RESET}")
    print(f"{GREY}  size      : {len(msg.value)} bytes{RESET}")
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
    ap = argparse.ArgumentParser(description="cat the contents of S3 text files, via Kafka")
    ap.add_argument("--topic", default="nifi-s3-files")
    ap.add_argument("--bootstrap", default=None, help="host:port of the broker")
    ap.add_argument("--group", default="s3-cat-consumer", help="consumer group id")
    ap.add_argument(
        "--from-beginning",
        action="store_true",
        help="replay the whole topic from offset 0",
    )
    ap.add_argument("--max", type=int, default=0, help="stop after N messages")
    ap.add_argument(
        "--timeout",
        type=int,
        default=0,
        help="exit after N seconds of silence (0 = never)",
    )
    args = ap.parse_args()

    bootstrap = args.bootstrap or terraform_output("kafka_bootstrap_server")

    print()
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"{BOLD}  KAFKA CONSUMER -- cat-ing S3 text files{RESET}")
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"  broker : {bootstrap}")
    print(f"  topic  : {args.topic}")
    print(f"  group  : {args.group}")
    offset_mode = "earliest (replay all)" if args.from_beginning else "latest (tail new)"
    print(f"  offset : {offset_mode}")
    print(f"{BOLD}{'=' * 66}{RESET}")
    print(f"{GREY}  Waiting for messages... (Ctrl+C to quit){RESET}")

    try:
        consumer = KafkaConsumer(
            args.topic,
            bootstrap_servers=[bootstrap],
            group_id=args.group,
            # 'earliest' = start at offset 0, replay everything ever sent.
            # 'latest'   = start at the END, only show NEW messages.
            #
            # This ONLY applies the first time a group_id is seen. After
            # that, Kafka remembers the group's committed offset and
            # resumes from there. Change --group to force a fresh start.
            auto_offset_reset="earliest" if args.from_beginning else "latest",
            enable_auto_commit=True,
            auto_commit_interval_ms=1000,
            consumer_timeout_ms=(args.timeout * 1000) if args.timeout else -1,
            api_version_auto_timeout_ms=10000,
            # Deliberately NOT deserializing -- we want the RAW bytes,
            # because that IS the literal content of the .txt file.
            value_deserializer=None,
        )
    except NoBrokersAvailable:
        print(f"\n  Cannot reach Kafka at {bootstrap}\n")
        print("  Check, in order:")
        print("    1. Is Kafka running?")
        print("         ansible role_kafka -a 'systemctl is-active kafka'")
        print("       or get a shell (no SSH needed):")
        print("         aws ssm start-session --target <kafka-instance-id>")
        print()
        print("    2. Is the port reachable from here?")
        print(f"         nc -zv {bootstrap.replace(':', ' ')}")
        print()
        print("    3. ARE YOU ON THE COMMAND NODE?")
        print("       Only NiFi and the Command Node are in Kafka's security")
        print("       group ingress list. From anywhere else this WILL hang.")
        print("       That is not a bug -- that is the requirement working.\n")
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
