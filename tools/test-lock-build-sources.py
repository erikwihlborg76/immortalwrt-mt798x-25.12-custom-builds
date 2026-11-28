#!/usr/bin/env python3
"""Offline source-lock regression tests using local Git repositories."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("source_lock", Path(__file__).with_name("lock-build-sources.py"))
LOCK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCK)
PATCH_SPEC = importlib.util.spec_from_file_location("build_patches", Path(__file__).with_name("apply-build-patches.py"))
PATCHES = importlib.util.module_from_spec(PATCH_SPEC)
PATCH_SPEC.loader.exec_module(PATCHES)


class FeedParsingTests(unittest.TestCase):
    def test_branch_and_existing_pin(self):
        branch = LOCK.parse_feed("src-git packages https://example.invalid/packages.git;release")
        self.assertEqual(branch["ref"], "release")
        self.assertEqual(branch["repository"], "https://example.invalid/packages.git")
        pinned = LOCK.parse_feed("src-git-full packages https://example.invalid/packages.git^" + "a" * 40)
        self.assertEqual(pinned["commit"], "a" * 40)
        self.assertEqual(pinned["type"], "src-git-full")

    def test_comments_and_head(self):
        self.assertIsNone(LOCK.parse_feed("# a comment"))
        self.assertIsNone(LOCK.parse_feed(""))
        self.assertEqual(LOCK.parse_feed("src-git packages /local/repo # comment")["ref"], "HEAD")

    def test_reject_unsupported_or_ambiguous_entries(self):
        for entry in (
            "src-link packages /local/packages",
            "src-git bad/name /local/repo",
            "src-git packages",
            "src-git packages /local/repo;",
            "src-git packages /local/repo^abc123",
            "src-git packages /local/repo;release^" + "a" * 40,
            "src-git packages /local/repo unexpected",
        ):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                LOCK.parse_feed(entry)

    def test_makefile_source_fields(self):
        makefile = "PKG_SOURCE_URL=$(PROJECT_GIT)/project/uci.git\nPKG_SOURCE_VERSION:=" + "a" * 40 + "\n"
        source = LOCK.package_source(makefile)
        self.assertEqual(source["repository"], "https://git.openwrt.org/project/uci.git")
        self.assertEqual(source["commit"], "a" * 40)
        with self.assertRaises(ValueError):
            LOCK.package_source(makefile.replace("a" * 40, "$(UNKNOWN)"))


class LocalGitTests(unittest.TestCase):
    def setUp(self):
        fixtures = Path(__file__).resolve().parent.parent / "logs" / "build-sources"
        fixtures.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="test-", dir=fixtures))
        self.repo = self.root / "feed"
        self.repo.mkdir()
        self.git("init", "--quiet", str(self.repo))
        self.git("config", "user.name", "Source lock fixture", cwd=self.repo)
        self.git("config", "user.email", "source-lock@example.invalid", cwd=self.repo)
        self.git("checkout", "--quiet", "-b", "release", cwd=self.repo)
        self.commit = self.commit_file(self.repo, "first.txt", "first")

    @staticmethod
    def git(*args, cwd=None):
        result = subprocess.run(["git", "-c", "core.autocrlf=false", *args], cwd=cwd, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def commit_file(self, repo, name, text):
        (repo / name).write_text(text, encoding="utf-8")
        self.git("add", "--", name, cwd=repo)
        self.git("commit", "--quiet", "-m", "Fixture revision", cwd=repo)
        return self.git("rev-parse", "HEAD", cwd=repo)

    def test_resolve_head_and_branch(self):
        for suffix in ("", ";release"):
            feed = LOCK.resolve_feed(LOCK.parse_feed("src-git packages " + self.repo.as_posix() + suffix))
            self.assertEqual(feed["commit"], self.commit)

    def test_lock_stays_pinned_when_branch_advances(self):
        feeds, pinned = LOCK.pin_feeds("# preserved\nsrc-git packages " + self.repo.as_posix() + ";release\n")
        self.assertEqual(feeds[0]["commit"], self.commit)
        next_commit = self.commit_file(self.repo, "second.txt", "second")
        self.assertNotEqual(next_commit, self.commit)
        pinned_feed = LOCK.resolve_feed(LOCK.parse_feed(pinned.splitlines()[1]))
        self.assertEqual(pinned_feed["commit"], self.commit)
        self.assertIn("# preserved\n", pinned)

    def test_missing_ref_and_duplicate_names_fail(self):
        with self.assertRaises(subprocess.CalledProcessError):
            LOCK.resolve_feed(LOCK.parse_feed("src-git packages " + self.repo.as_posix() + ";missing"))
        with self.assertRaises(ValueError):
            LOCK.pin_feeds(("src-git packages " + self.repo.as_posix() + "\n") * 2)
        with self.assertRaises(ValueError):
            LOCK.pin_feeds("# no feeds\n")

    def test_full_lock_contains_checkout_and_host_tool_commits(self):
        upstream = self.root / "upstream"
        upstream.mkdir()
        self.git("init", "--quiet", str(upstream))
        self.git("config", "user.name", "Source lock fixture", cwd=upstream)
        self.git("config", "user.email", "source-lock@example.invalid", cwd=upstream)
        self.git("checkout", "--quiet", "-b", "release", cwd=upstream)
        for path in LOCK.HOST_PACKAGES.values():
            target = upstream / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("PKG_SOURCE_URL=" + self.repo.as_posix() + "\nPKG_SOURCE_VERSION:=" + self.commit + "\n", encoding="utf-8")
        (upstream / "feeds.conf.default").write_text("src-git packages " + self.repo.as_posix() + ";release\n", encoding="utf-8")
        self.git("add", ".", cwd=upstream)
        self.git("commit", "--quiet", "-m", "Fixture source", cwd=upstream)
        expected = self.git("rev-parse", "HEAD", cwd=upstream)
        lock = LOCK.create_lock(str(upstream), "refs/heads/release", self.root / "checkout", self.root / "output")
        self.assertEqual(lock["upstream"]["commit"], expected)
        self.assertEqual(lock["feeds"][0]["commit"], self.commit)
        self.assertEqual(lock["host_test_tools"]["uci"]["commit"], self.commit)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.root / "checkout"), expected)
        self.assertEqual(json.loads((self.root / "output/source-lock.json").read_text())["upstream"]["commit"], expected)
        self.assertEqual((self.root / "output/feeds.conf").read_text(), "src-git packages " + self.repo.as_posix() + "^" + self.commit + "\n")
        lock_path = self.root / "output/source-lock.json"
        feed_dir = self.root / "checkout/feeds/packages"
        LOCK.checkout(str(self.repo), self.commit, feed_dir)
        LOCK.verify_lock(lock_path, self.root / "checkout")
        newer = self.commit_file(self.repo, "second.txt", "second")
        self.git("fetch", "--quiet", "origin", newer, cwd=feed_dir)
        self.git("checkout", "--quiet", "--detach", newer, cwd=feed_dir)
        with self.assertRaisesRegex(ValueError, "Feed checkout differs"):
            LOCK.verify_lock(lock_path, self.root / "checkout")

    def test_patch_encoding_and_hard_failure(self):
        patches = self.root / "patches"
        patches.mkdir()
        change = "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-first\n\\ No newline at end of file\n+edited\n"
        (patches / "001-change.patch").write_bytes(change.replace("\n", "\r\n").encode("utf-16"))
        PATCHES.apply_patches(self.repo, patches)
        self.assertEqual((self.repo / "first.txt").read_text(), "edited\n")
        # Re-applying a patch that no longer matches must fail, not silently skip.
        with self.assertRaisesRegex(ValueError, "Unable to apply patch"):
            PATCHES.apply_patches(self.repo, patches)
        self.assertTrue((patches / "001-change.patch").read_bytes().startswith(b"\xff\xfe"))


if __name__ == "__main__":
    unittest.main()
