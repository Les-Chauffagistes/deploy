#!/usr/bin/env python3
"""Read build metadata, without checking out source, starting builds or logging secrets."""
import json
import os
import urllib.error
import urllib.request

ref = os.environ["CLOUD_SOURCE_REF"]
token = os.environ.get("ORG_PAT")
if not token:
    raise SystemExit(0)
base = "https://api.github.com/repos/Les-Chauffagistes/ChauffAssistant"

def get(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)

try:
    runs = get("/actions/runs?head_sha=" + ref + "&per_page=20")["workflow_runs"]
    matching = [r for r in runs if r["name"] == "Cloud image" and r["head_sha"] == ref]
    if matching:
        run = matching[0]
        print("Source Cloud image:", run["status"], run["conclusion"] or "pending")
        if run["status"] == "completed" and run["conclusion"] != "success":
            jobs = get("/actions/runs/" + str(run["id"]) + "/jobs")["jobs"]
            for job in jobs:
                if job["conclusion"] == "failure":
                    print("Failed source job:", job["name"])
                    for step in job.get("steps", []):
                        if step["conclusion"] == "failure":
                            print("Failed source step:", step["name"])
            raise SystemExit("Cloud image build failed; no staging service was changed.")
except (urllib.error.URLError, ValueError, KeyError):
    print("Source build status unavailable; continuing registry verification.")
