#!/usr/bin/env python3
"""OpenClaude PR review gate (AMOS Layer 04).

Runs in CI on a GitHub-hosted runner as the AMOS safety gate. It scans the
PR diff for committed secrets and destructive commands (Non-Negotiable
Rules 5 and 6). Safe PRs are approved and auto-merged (squash); unsafe PRs
are commented on, labeled for human review, and never merged.

This is a heuristic gate. The cost-optimized upgrade path is to run the
same checks behind a local Ollama model on a self-hosted runner once local
AI is operational (see docs/integrations/headroom.md).
"""
import os
import re
import subprocess
import sys

PR_NUMBER = os.environ.get("PR_NUMBER")
REPO = os.environ.get("REPO")
BASE_SHA = os.environ.get("BASE_SHA")
HEAD_SHA = os.environ.get("HEAD_SHA")

# (label, regex) matched against ADDED diff lines only.
SECRET_PATTERNS = [
    ("AWS access key id", r"AKIA[0-9A-Z]{16}"),
    ("Private key block",
     r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"),
    ("Generic secret assignment",
     r"(?i)(api[_-]?key|secret|token|passwd|password)\s*[:=]\s*"
     r"['\"][A-Za-z0-9_\-]{16,}['\"]"),
    ("Slack token", r"xox[baprs]-[0-9A-Za-z-]{10,}"),
    ("Google API key", r"AIza[0-9A-Za-z_\-]{35}"),
    ("GitHub token", r"gh[pousr]_[0-9A-Za-z]{36,}"),
]

DESTRUCTIVE_PATTERNS = [
    ("Recursive force remove",
     r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\b|\brm\s+-[a-zA-Z]*f[a-zA-Z]*r\b"),
    ("Filesystem format", r"\bmkfs(\.\w+)?\b"),
    ("Raw disk write", r"\bdd\s+if="),
    ("Fork bomb", r":\(\)\s*\{\s*:\|:&\s*\}\s*;\s*:"),
    ("Pipe remote script to shell",
     r"curl\s+[^|]*\|\s*(?:sudo\s+)?(?:ba)?sh"),
    ("Force push to main/master",
     r"git\s+push\b.*--force.*\b(?:origin\s+)?(?:main|master)\b"),
    ("Drop database/table", r"(?i)\bDROP\s+(?:TABLE|DATABASE)\b"),
]


def sh(args):
    return subprocess.run(args, capture_output=True, text=True)


def added_lines():
    """Return added ('+') diff lines between base and head."""
    diff = None
    if BASE_SHA and HEAD_SHA:
        diff = sh(["git", "diff", BASE_SHA, HEAD_SHA])
    if diff is None or diff.returncode != 0:
        diff = sh(["git", "diff", "HEAD~1", "HEAD"])
    lines = []
    for line in diff.stdout.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
    return lines


def scan(lines):
    findings = []
    joined = "\n".join(lines)
    for label, pat in SECRET_PATTERNS:
        if re.search(pat, joined):
            findings.append(f"Possible secret: {label}")
    for label, pat in DESTRUCTIVE_PATTERNS:
        if re.search(pat, joined):
            findings.append(f"Destructive command: {label}")
    return findings


def comment(body):
    sh(["gh", "pr", "comment", PR_NUMBER, "--repo", REPO, "--body", body])


def add_label(label):
    sh(["gh", "pr", "edit", PR_NUMBER, "--repo", REPO, "--add-label", label])


def merge():
    # Prefer auto-merge (respects branch protection); fall back to direct.
    r = sh(["gh", "pr", "merge", PR_NUMBER, "--repo", REPO,
            "--squash", "--delete-branch", "--auto"])
    if r.returncode != 0:
        r = sh(["gh", "pr", "merge", PR_NUMBER, "--repo", REPO,
                "--squash", "--delete-branch"])
    return r


def main():
    if not PR_NUMBER or not REPO:
        print("PR_NUMBER/REPO not set; nothing to do.")
        return 0

    findings = scan(added_lines())
    if findings:
        body = ("OpenClaude safety gate: **held for human review**.\n\n"
                + "\n".join(f"- {f}" for f in findings)
                + "\n\nNo merge performed (Non-Negotiable Rules 5/6). "
                "Resolve the findings or merge manually after review.")
        comment(body)
        add_label("needs-human-review")
        print("Unsafe diff detected; held for human review.")
        return 0

    comment("OpenClaude safety gate: no secrets or destructive commands "
            "detected. Approving and merging (squash).")
    result = merge()
    print(result.stdout or result.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
