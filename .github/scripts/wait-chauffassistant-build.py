#!/usr/bin/env python3
"""Wait for the source build using metadata only. Never expose build logs or secrets."""
import json
import os
import time
import urllib.error
import urllib.request

base = "https://api.github.com/repos/Les-Chauffagistes/ChauffAssistant"
run_id = str(int(os.environ["SOURCE_RUN_ID"]))
token = os.environ["ORG_PAT"]


def get(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit("GitHub build metadata HTTP " + str(error.code)) from None
    except urllib.error.URLError:
        raise SystemExit("GitHub build metadata unavailable") from None


for attempt in range(60):
    run = get("/actions/runs/" + run_id)
    if run["status"] == "completed":
        if run["conclusion"] != "success":
            jobs = get("/actions/runs/" + run_id + "/jobs")["jobs"]
            for job in jobs:
                if job["conclusion"] == "failure":
                    name = job["name"].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                    print("::error::Source build failed: " + name)
                    for step in job.get("steps", []):
                        if step["conclusion"] == "failure":
                            print("::error::Failed step: " + step["name"])
            raise SystemExit("Source build did not succeed")
        print("::notice::Cloud image built and published successfully: sha-" + run["head_sha"][:7])
        break
    if attempt % 4 == 0:
        print("Source Cloud image:", run["status"], flush=True)
    time.sleep(15)
else:
    raise SystemExit("Source build still pending after 15 minutes; no staging deployment was triggered")
