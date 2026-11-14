#!/usr/bin/env python3
"""Verify the fixed certificate and optionally cross-check identity across two different builds."""
import argparse
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("apps", nargs="+", type=Path)
args = parser.parse_args()
identity = os.environ.get("WEFT_SIGNING_IDENTITY")
if not identity:
    identity = (Path.home() / ".sign_keys_macos_app/identity.sha1").read_text().strip()
if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
    raise SystemExit("Invalid signing certificate fingerprint")
required = f'identifier "me.weishu.Weft" and certificate leaf = H"{identity}"'
requirements = []
hashes = []
for app in args.apps:
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + required, str(app)], check=True)
    info = subprocess.run(["codesign", "-d", "-r-", "--verbose=4", str(app)], capture_output=True, text=True, check=True)
    text = info.stdout + info.stderr
    requirement = re.search(r"designated => (.+)", text).group(1)
    requirements.append(requirement)
    hashes.append(re.search(r"CDHash=(.+)", text).group(1))
    print(app.name + ": fixed certificate verified")
for requirement in requirements:
    for app in args.apps:
        subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(app)], check=True)
if len(args.apps) > 1:
    if len(set(hashes)) == 1:
        raise SystemExit("Builds are identical; this does not prove identity survives content changes")
    if len(set(requirements)) != 1:
        raise SystemExit("Designated requirement changed across builds")
    print("Different code hashes, identical designated requirements, cross-verification passed")
