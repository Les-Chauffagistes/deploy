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
    matching = [r for r in runs if r["head_sha"] == ref and (r["name"] == "Cloud image" or r.get("path", "").split("@")[0] == ".github/workflows/build-cloud.yml")]
    if matching:
        run = matching[0]
        print("::notice::Source Cloud image: " + run["status"] + " " + (run["conclusion"] or "pending"))
        if run["status"] == "completed" and run["conclusion"] != "success":
            jobs = get("/actions/runs/" + str(run["id"]) + "/jobs")["jobs"]
            for job in jobs:
                if job["conclusion"] == "failure":
                    print("::error::Failed source job: " + job["name"])
                    for step in job.get("steps", []):
                        if step["conclusion"] == "failure":
                            print("::error::Failed source step: " + step["name"])
            checks = get("/check-suites/" + str(run["check_suite_id"]) + "/check-runs")["check_runs"]
            for check in checks:
                if check["conclusion"] == "failure":
                    for annotation in get("/check-runs/" + str(check["id"]) + "/annotations")[:5]:
                        message = annotation.get("message", "")[:2000].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                        print("::error::Source build: " + message)
            raise SystemExit("Cloud image build failed; no staging service was changed.")
except (urllib.error.URLError, ValueError, KeyError):
    print("Source build status unavailable; continuing registry verification.")
