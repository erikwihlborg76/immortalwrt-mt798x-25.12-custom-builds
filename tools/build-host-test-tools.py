#!/usr/bin/env python3
"""Build the locked UCI and ucode host binaries for isolated integration tests."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location("source_lock", Path(__file__).with_name("lock-build-sources.py"))
LOCK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCK)


def run(*args):
    subprocess.run(args, check=True)


def build_tools(lock_path, work_dir, prefix):
    lock = json.loads(Path(lock_path).read_text(encoding="utf-8"))
    if lock.get("schema_version") != 1:
        raise ValueError("Unsupported source-lock schema")
    work = Path(work_dir).resolve()
    install = Path(prefix).resolve()
    work.mkdir(parents=True, exist_ok=True)
    install.mkdir(parents=True, exist_ok=True)
    common = [
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_INSTALL_PREFIX=" + str(install),
        "-DCMAKE_INSTALL_LIBDIR=lib",
        "-DCMAKE_PREFIX_PATH=" + str(install),
        "-DCMAKE_INSTALL_RPATH=" + str(install / "lib"),
        "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON",
        "-DBUILD_LUA=OFF", "-DBUILD_EXAMPLES=OFF",
    ]
    for name in ("libubox", "uci", "ucode"):
        source = lock["host_test_tools"][name]
        commit = source["commit"]
        if not LOCK.COMMIT.fullmatch(commit):
            raise ValueError("A full host-tool commit SHA is required: " + name)
        checkout = work / (name + "-src")
        actual = LOCK.checkout(source["repository"], commit, checkout)
        if actual.lower() != commit.lower():
            raise ValueError("Host-tool checkout differs from lock: " + name)
        options = list(common)
        if name == "ucode":
            # Only filesystem access is needed by converter tests. No live
            # network, ubus, UCI or proprietary driver bindings are loaded.
            for module in ("DEBUG", "IO", "MATH", "UBUS", "UCI", "RTNL", "NL80211",
                           "RESOLV", "STRUCT", "ULOOP", "LOG", "SOCKET", "ZLIB", "DIGEST"):
                options.append("-D" + module + "_SUPPORT=OFF")
            options.append("-DFS_SUPPORT=ON")
        binary_dir = work / (name + "-build")
        run("cmake", "-S", str(checkout), "-B", str(binary_dir), *options)
        run("cmake", "--build", str(binary_dir), "--parallel", str(os.cpu_count() or 2))
        run("cmake", "--install", str(binary_dir))
    for name in ("uci", "ucode"):
        if not (install / "bin" / name).is_file():
            raise ValueError("Host tool was not installed: " + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--prefix", required=True)
    args = parser.parse_args()
    build_tools(args.lock, args.work_dir, args.prefix)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        if getattr(error, "stderr", None):
            print(error.stderr.strip(), file=sys.stderr)
        print("Host test tools failed: " + str(error), file=sys.stderr)
        sys.exit(1)
