#!/usr/bin/env python3
"""Sync DNS records from YAML files to TransIP via their REST API."""

import base64
import json
import os
import sys
import uuid
from glob import glob
from pathlib import Path

import requests
import yaml
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

TRANSIP_API = "https://api.transip.nl/v6"
DOMAINS_DIR = "/config/domains"


def get_access_token(account_name: str, private_key: str) -> str:
    """Authenticate with TransIP API and return a bearer token."""
    body = json.dumps({
        "login": account_name,
        "nonce": uuid.uuid4().hex,
        "read_only": False,
        "expiration_time": "5 minutes",
        "global_key": True,
    })

    key = serialization.load_pem_private_key(private_key.encode(), password=None)
    signature = key.sign(body.encode(), padding.PKCS1v15(), hashes.SHA512())
    signature_b64 = base64.b64encode(signature).decode()

    resp = requests.post(
        f"{TRANSIP_API}/auth",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Signature": signature_b64,
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def sync_domain(domain: str, records: list, token: str) -> None:
    """Replace all DNS entries for a domain."""
    entries = []
    for r in records:
        entries.append({
            "name": r["name"],
            "expire": r["expire"],
            "type": r["type"],
            "content": r["content"],
        })

    resp = requests.put(
        f"{TRANSIP_API}/domains/{domain}/dns",
        json={"dnsEntries": entries},
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        timeout=30,
    )
    resp.raise_for_status()
    print(f"Synced {len(entries)} records for {domain}")


def main():
    account_name = os.environ.get("TRANSIP_ACCOUNT_NAME")
    private_key_path = os.environ.get("TRANSIP_PRIVATE_KEY_PATH", "/secrets/private_key")

    if not account_name:
        print("ERROR: TRANSIP_ACCOUNT_NAME not set")
        sys.exit(1)

    private_key = Path(private_key_path).read_text().strip()

    print("Authenticating with TransIP API...")
    token = get_access_token(account_name, private_key)

    domain_files = sorted(glob(f"{DOMAINS_DIR}/*.yaml"))
    if not domain_files:
        print("No domain files found")
        sys.exit(0)

    errors = 0
    for filepath in domain_files:
        domain = Path(filepath).stem
        print(f"Processing {domain}...")
        try:
            with open(filepath) as f:
                data = yaml.safe_load(f)
            sync_domain(domain, data["records"], token)
        except Exception as e:
            print(f"ERROR syncing {domain}: {e}")
            errors += 1

    if errors:
        print(f"Completed with {errors} error(s)")
        sys.exit(1)

    print("All domains synced successfully")


if __name__ == "__main__":
    main()
