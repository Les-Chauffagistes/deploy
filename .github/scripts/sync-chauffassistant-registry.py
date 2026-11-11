#!/usr/bin/env python3
"""Copy only the two authorised registry secrets through GitHub sealed boxes.

No value is logged, saved to disk or returned as an output. ORG_PAT is only used
as an API credential and is never copied to the destination repository.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

from nacl.public import PublicKey, SealedBox

REPOSITORY = "Les-Chauffagistes/ChauffAssistant"
BASE = "/repos/" + REPOSITORY
SECRET_NAMES = ("REGISTRY_USER", "REGISTRY_PASSWORD")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class GitHub:
    def __init__(self, token):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def call(self, method, path, body=None):
        request = urllib.request.Request(
            "https://api.github.com" + path,
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with self.opener.open(request, timeout=20) as response:
                data = response.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            # Never print response bodies, headers or request objects.
            raise RuntimeError(f"GitHub API HTTP {error.code} during {method} {path.split('?')[0]}") from None
        except urllib.error.URLError:
            raise RuntimeError("GitHub API unavailable") from None


def sync_registry(client, values):
    if any(not values.get(name) for name in SECRET_NAMES):
        raise RuntimeError("Both source registry secrets must be present; nothing was copied")
    if any(len(values[name].encode()) > 48 * 1024 for name in SECRET_NAMES):
        raise RuntimeError("Registry secret exceeds GitHub's size limit")
    repository = client.call("GET", BASE)
    if repository["full_name"].lower() != REPOSITORY.lower():
        raise RuntimeError("Unexpected destination repository")
    key = client.call("GET", BASE + "/actions/secrets/public-key")
    sealed = SealedBox(PublicKey(base64.b64decode(key["key"], validate=True)))
    for name in SECRET_NAMES:
        ciphertext = sealed.encrypt(values[name].encode())
        client.call("PUT", BASE + "/actions/secrets/" + name, {
            "key_id": key["key_id"],
            "encrypted_value": base64.b64encode(ciphertext).decode(),
        })
        metadata = client.call("GET", BASE + "/actions/secrets/" + name)
        if metadata["name"] != name:
            raise RuntimeError("Unexpected secret metadata")
        print("Registry secret configured:", name)


def dispatch_build(client):
    path = BASE + "/actions/workflows/build-cloud.yml"
    previous = {r["id"] for r in client.call("GET", path + "/runs?per_page=20")["workflow_runs"]}
    client.call("POST", path + "/dispatches", {"ref": "main"})
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        for run in client.call("GET", path + "/runs?per_page=20")["workflow_runs"]:
            if run["id"] not in previous and run["event"] == "workflow_dispatch" and run["head_branch"] == "main":
                output = os.environ.get("GITHUB_OUTPUT")
                if output:
                    with open(output, "a") as stream:
                        stream.write("run_id=" + str(int(run["id"])) + "\n")
                print("::notice::Cloud image workflow dispatched; run " + str(int(run["id"])))
                return
        time.sleep(3)
    raise RuntimeError("Build dispatched but its run could not be located; check Cloud image before retrying")


def main():
    token = os.environ.get("ORG_PAT")
    if not token:
        raise RuntimeError("ORG_PAT is required for the authorised repository secret setup")
    client = GitHub(token)
    if sys.argv[1:] == ["sync"]:
        sync_registry(client, {name: os.environ.get(name, "") for name in SECRET_NAMES})
    elif sys.argv[1:] == ["dispatch"]:
        dispatch_build(client)
    else:
        raise RuntimeError("Expected sync or dispatch")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError) as error:
        text = str(error).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error::" + text)
        raise SystemExit(1)
