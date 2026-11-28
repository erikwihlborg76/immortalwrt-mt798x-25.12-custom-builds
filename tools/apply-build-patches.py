#!/usr/bin/env python3
"""Apply local source patches without modifying their checked-in encodings."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def apply_patches(source_dir, patch_dir, commit=False):
    source = Path(source_dir).resolve()
    patches = sorted(path for path in Path(patch_dir).rglob("*")
                     if path.is_file() and path.suffix.lower() in (".patch", ".diff"))
    if not patches:
        raise ValueError("No source patches found")
    fixture_root = Path(__file__).resolve().parent.parent / "logs" / "patches"
    fixture_root.mkdir(parents=True, exist_ok=True)
    normalized_dir = Path(tempfile.mkdtemp(prefix="apply-", dir=fixture_root))
    for index, path in enumerate(patches):
        data = path.read_bytes()
        encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        normalized = normalized_dir / (str(index) + ".patch")
        normalized.write_bytes(data.decode(encoding).replace("\r\n", "\n").encode("utf-8"))
        for strip in (1, 0, 2):
            args = ["git", "-C", str(source), "apply", "--index", "--whitespace=fix", "-p" + str(strip)]
            checked = subprocess.run([*args, "--check", str(normalized)], capture_output=True, text=True)
            if checked.returncode == 0:
                subprocess.run([*args, str(normalized)], check=True)
                if commit:
                    subprocess.run(["git", "-C", str(source), "commit", "--quiet", "-m", "Apply " + path.name], check=True)
                print("Applied " + path.name)
                break
        else:
            raise ValueError("Unable to apply patch: " + str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir")
    parser.add_argument("patch_dir")
    parser.add_argument("--commit", action="store_true")
    args = parser.parse_args()
    apply_patches(args.source_dir, args.patch_dir, args.commit)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError, subprocess.CalledProcessError) as error:
        print("Patch application failed: " + str(error), file=sys.stderr)
        sys.exit(1)
