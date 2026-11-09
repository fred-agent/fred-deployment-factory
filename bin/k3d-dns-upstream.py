#!/usr/bin/env python3
"""Set the upstream resolver for a local k3d CoreDNS installation."""

import ipaddress
import json
import re
import subprocess
import sys


context, upstream = sys.argv[1:]
ipaddress.IPv4Address(upstream)
command = ["kubectl", "--context", context, "-n", "kube-system"]
config = json.loads(
    subprocess.check_output([*command, "get", "configmap", "coredns", "-o", "json"])
)
corefile = config["data"]["Corefile"]
updated, count = re.subn(
    r"(?m)^([ \t]*)forward \. [^\n]+$",
    lambda match: f"{match.group(1)}forward . {upstream}",
    corefile,
)
if count != 1:
    raise SystemExit(f"Expected one CoreDNS forward directive, found {count}")
if updated == corefile:
    print(f"CoreDNS already forwards to {upstream}")
    raise SystemExit(0)

patch = [{"op": "replace", "path": "/data/Corefile", "value": updated}]
subprocess.run(
    [*command, "patch", "configmap", "coredns", "--type=json", "-p", json.dumps(patch)],
    check=True,
)
subprocess.run([*command, "rollout", "restart", "deployment/coredns"], check=True)
subprocess.run(
    [*command, "rollout", "status", "deployment/coredns", "--timeout=180s"],
    check=True,
)
print(f"CoreDNS forwards to {upstream}")
