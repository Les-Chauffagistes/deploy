#!/usr/bin/env python3
"""Check staging HTTPS, exact source revision and absence of local device routes."""
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = "https://api.chauffassistant.staging.chauffagistes-btc.fr"
stack = Path("stacks/staging/chauffassistant-backend.yml").read_text()
match = re.search(r'^x-chauffassistant-source-ref: "([0-9a-f]{40})"$', stack, re.M)
if not match:
    raise SystemExit("Missing immutable cloud source reference")
expected = match.group(1)
deadline = time.monotonic() + 120
last_error = "not checked"
while time.monotonic() < deadline:
    try:
        for path in ("/healthz", "/readyz", "/api/v1/health"):
            with urllib.request.urlopen(BASE + path, timeout=8) as response:
                data = json.load(response)
            assert data["status"] == "ok" and data["mode"] == "cloud", data
            assert data["remote_access_enabled"] is True, data
            assert data["revision"] == expected, data
        break
    except (OSError, ValueError, KeyError, AssertionError) as error:
        last_error = str(error)
        time.sleep(3)
else:
    raise SystemExit("Cloud health checks failed: " + last_error)

for path in ("/api/v1/devices", "/api/v1/heating", "/api/v1/installation"):
    try:
        urllib.request.urlopen(BASE + path, timeout=8).close()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            continue
        raise SystemExit(f"Unexpected HTTP {error.code} for {path}")
    raise SystemExit("Local API unexpectedly exposed: " + path)
for path in ("/api/v1/account", "/api/v1/installations"):
    try:
        urllib.request.urlopen(BASE + path, timeout=8).close()
    except urllib.error.HTTPError as error:
        if error.code == 401:
            continue
        raise SystemExit(f"Unexpected HTTP {error.code} for {path}")
    raise SystemExit("Unauthenticated account API unexpectedly accessible: " + path)
print("ChauffAssistant cloud HTTPS and revision verified; accounts require authentication and local hardware APIs are absent.")
