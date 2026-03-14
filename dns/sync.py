#!/usr/bin/env python3
"""Sync DNS records from YAML files to TransIP via their REST API."""

import base64
import json
import os
import sys
import time
import uuid
from glob import glob
from pathlib import Path

import jwt
import requests
import yaml

TRANSIP_API = "https://api.transip.nl/v6"
DOMAINS_DIR = "/config/domains"


def get_access_token(account_name: str, private_key: str) -> str:
    """Authenticate with TransIP API and return a bearer token."""
    now = int(time.time())
    payload = {
        "iss": account_name,
        "sub": account_name,
        "aud": "api.transip.nl",
        "jti": str(uuid.uuid4()),
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "global_key": True,
    }
    token = jwt.encode(payload, private_key, algorithm="RS512")
    resp = requests.post(
        f"{TRANSIP_API}/auth",
        json={"login": account_name, "nonce": payload["jti"], "global_key": True},
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
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
