#!/usr/bin/env python3
"""Resolve one upstream checkout and immutable Git feed inputs for a build run."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

COMMIT = re.compile(r"[0-9a-fA-F]{40}")
FEED_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
HOST_PACKAGES = {
    "libubox": "package/libs/libubox/Makefile",
    "uci": "package/system/uci/Makefile",
    "ucode": "package/utils/ucode/Makefile",
}


def git(*arguments, cwd=None):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(
        ["git", "-c", "core.autocrlf=false", *arguments],
        cwd=cwd, env=env, text=True, capture_output=True, check=True,
    )
    return result.stdout.strip()


def checkout(repository, ref, destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    git("init", "--quiet", str(destination))
    git("-C", str(destination), "remote", "add", "origin", repository)
    git("-C", str(destination), "fetch", "--quiet", "--depth=1", "--filter=blob:none", "origin", ref)
    commit = git("-C", str(destination), "rev-parse", "FETCH_HEAD")
    if not COMMIT.fullmatch(commit):
        raise ValueError("The upstream reference did not resolve to a full commit")
    git("-C", str(destination), "checkout", "--quiet", "--detach", commit)
    return commit


def parse_feed(line):
    fields = line.split()
    if not fields or fields[0].startswith("#"):
        return None
    if len(fields) < 3 or (len(fields) > 3 and not fields[3].startswith("#")):
        raise ValueError("Invalid feeds.conf entry: " + line)
    kind, name, location = fields[:3]
    if kind not in ("src-git", "src-git-full") or not FEED_NAME.fullmatch(name):
        raise ValueError("Only named Git feeds can be locked: " + line)
    if "^" in location:
        repository, commit = location.rsplit("^", 1)
        if not repository or ";" in repository or not COMMIT.fullmatch(commit):
            raise ValueError("A pinned feed requires a full commit SHA: " + line)
        return {"type": kind, "name": name, "repository": repository, "ref": commit.lower(), "commit": commit.lower()}
    repository, separator, branch = location.partition(";")
    if not repository or (separator and not branch):
        raise ValueError("Missing feed repository or branch: " + line)
    return {"type": kind, "name": name, "repository": repository, "ref": branch if separator else "HEAD"}


def resolve_feed(feed):
    feed = dict(feed)
    if "commit" not in feed:
        ref = feed["ref"]
        remote_ref = "HEAD" if ref == "HEAD" else "refs/heads/" + ref
        rows = git("ls-remote", "--exit-code", feed["repository"], remote_ref).splitlines()
        matches = [row.split()[0] for row in rows if len(row.split()) == 2 and row.split()[1] == remote_ref]
        if len(matches) != 1 or not COMMIT.fullmatch(matches[0]):
            raise ValueError("Feed reference did not resolve uniquely: " + feed["name"])
        feed["commit"] = matches[0].lower()
    return feed


def pin_feeds(text):
    feeds, lines, seen = [], [], set()
    for line in text.splitlines():
        feed = parse_feed(line)
        if feed is None:
            lines.append(line)
            continue
        if feed["name"] in seen:
            raise ValueError("Duplicate feed name: " + feed["name"])
        seen.add(feed["name"])
        feed = resolve_feed(feed)
        feeds.append(feed)
        lines.append("{type} {name} {repository}^{commit}".format(**feed))
    if not feeds:
        raise ValueError("Upstream feeds.conf.default contains no Git feeds")
    return feeds, "\n".join(lines) + "\n"


def package_source(makefile):
    def value(name):
        match = re.search(r"^" + re.escape(name) + r"\s*:?=\s*(\S+)\s*$", makefile, re.MULTILINE)
        if not match:
            raise ValueError("Missing package source field " + name)
        return match.group(1)
    commit = value("PKG_SOURCE_VERSION")
    repository = value("PKG_SOURCE_URL").replace("$(PROJECT_GIT)", "https://git.openwrt.org")
    if "$" in repository or not COMMIT.fullmatch(commit):
        raise ValueError("Host tool source must use a literal URL and full commit SHA")
    return {"repository": repository, "commit": commit.lower()}


def create_lock(repository, ref, checkout_dir, output_dir):
    commit = checkout(repository, ref, checkout_dir)
    upstream = Path(checkout_dir)
    feeds, pinned = pin_feeds((upstream / "feeds.conf.default").read_text(encoding="utf-8"))
    host_tools = {name: package_source((upstream / path).read_text(encoding="utf-8")) for name, path in HOST_PACKAGES.items()}
    lock = {
        "schema_version": 1,
        "resolved_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "upstream": {"repository": repository, "ref": ref, "commit": commit},
        "feeds": feeds,
        "host_test_tools": host_tools,
    }
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    (output / "source-lock.json").write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    (output / "feeds.conf").write_text(pinned, encoding="utf-8")
    return lock


def verify_lock(lock_path, checkout_dir):
    lock = json.loads(Path(lock_path).read_text(encoding="utf-8"))
    if lock.get("schema_version") != 1:
        raise ValueError("Unsupported source-lock schema")
    upstream = Path(checkout_dir)
    if git("rev-parse", "HEAD", cwd=upstream) != lock["upstream"]["commit"]:
        raise ValueError("Upstream checkout differs from the run's source lock")
    for feed in lock["feeds"]:
        if not FEED_NAME.fullmatch(feed["name"]):
            raise ValueError("Invalid locked feed name")
        actual = git("rev-parse", "HEAD", cwd=upstream / "feeds" / feed["name"])
        if actual != feed["commit"]:
            raise ValueError("Feed checkout differs from the run's source lock: " + feed["name"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository")
    parser.add_argument("--ref")
    parser.add_argument("--checkout-dir")
    parser.add_argument("--output-dir")
    parser.add_argument("--verify-checkout")
    parser.add_argument("--lock")
    args = parser.parse_args()
    if args.verify_checkout:
        if not args.lock:
            parser.error("--lock is required with --verify-checkout")
        verify_lock(args.lock, args.verify_checkout)
        print("Source and feed checkouts match the run's source lock")
        return
    if not all((args.repository, args.ref, args.checkout_dir, args.output_dir)):
        parser.error("--repository, --ref, --checkout-dir and --output-dir are required")
    lock = create_lock(args.repository, args.ref, args.checkout_dir, args.output_dir)
    print(lock["upstream"]["commit"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if getattr(error, "stderr", None):
            print(error.stderr.strip(), file=sys.stderr)
        print("Source lock failed: " + str(error), file=sys.stderr)
        sys.exit(1)
