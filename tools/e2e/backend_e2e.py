#!/usr/bin/env python3
"""Backend-level end-to-end check: the built backend talks to the installed root
component over the pipe protocol and brings up a real tunnel with a temporary identity.

usage: backend_e2e.py <backend> <store dir> <config.yaml> <seconds>
Exit codes: 0 passed, 1 failed, 2 precondition missing (component absent, outdated or busy).
Prints states, counts and codes only — never addresses, names or credentials.
"""
import json
import subprocess
import sys
import time

backend, store, config, seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
process = subprocess.Popen([backend, "serve", "--store", store], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
sent = 0


def call(method, **fields):
    global sent
    sent += 1
    process.stdin.write(json.dumps({"version": 1, "id": str(sent), "method": method, **fields}) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    if not line:
        finish(1, f"backend closed the pipe during {method}")
    reply = json.loads(line)
    if reply.get("id") != str(sent):
        finish(1, f"{method}: reply id does not match the request")
    return reply.get("result"), (reply.get("error") or {}).get("code")


def finish(code, message):
    print(("PASS " if code == 0 else "SKIP " if code == 2 else "FAIL ") + message)
    try:
        process.stdin.close()
        exited = process.wait(timeout=20)
        if code == 0 and exited != 0:
            print(f"FAIL backend exited with {exited}")
            code = 1
    except Exception:
        process.kill()
        code = code or 1
    sys.exit(code)


def expect(condition, message):
    if not condition:
        # Leave no tunnel behind when an assertion fails after connect.
        call("disconnect")
        finish(1, message)


authorization, _ = call("authorization")
if not authorization or not authorization.get("available"):
    finish(2, "the connection component is not installed; enable it in the App first")
if authorization.get("updateRequired"):
    finish(2, "the installed connection component needs an upgrade; upgrade it in the App first")

preview, error = call("preview", path=config, name="E2E")
if error:
    finish(1, f"preview rejected the temporary identity: {error}")
profile, error = call("import", path=config, name="E2E", digest=preview["digest"])
if error:
    finish(1, f"import failed: {error}")

status, error = call("connect", profileID=profile["id"])
if error == "already_connected":
    finish(2, "the connection component is busy with another session; disconnect in Nebula first")
if error or status["state"] != "started":
    finish(1, f"connect failed: {error or status['state']}")

log_entries, polls, deadline = 0, 0, time.time() + seconds
while time.time() < deadline:
    page, error = call("logs")
    expect(not error and page["available"], f"logs failed: {error}")
    log_entries = max(log_entries, len(page["entries"]))
    if polls % 3 == 0:
        status, error = call("status")
        expect(not error and status["state"] == "started" and not status.get("error"),
               f"tunnel did not stay started: {error or status['state']}")
    polls += 1
    time.sleep(1)
expect(log_entries > 0, "the kernel produced no log entries")

status, error = call("rebind")
expect(not error and status["state"] == "started", f"rebind failed: {error}")
status, error = call("disconnect")
if error or status["state"] != "disconnected" or status.get("error"):
    finish(1, f"disconnect failed: {error or status['state']}")
events, _ = call("events")
codes = [event["code"] for event in events]
if codes != ["profile_imported", "tunnel_started", "network_refresh_requested", "tunnel_stopped"]:
    finish(1, f"unexpected events: {codes}")
finish(0, f"backend: {sent} requests, {log_entries} kernel log entries, clean disconnect")
