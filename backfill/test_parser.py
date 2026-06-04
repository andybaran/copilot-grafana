#!/usr/bin/env python3
"""Lightweight checks for the pure helpers in parser.py (no DB, no psycopg2 needed).

Run: ``python backfill/test_parser.py``  (exit code 0 = all passed).
Covers cross-platform project derivation so the POSIX and Windows/UNC behaviour
stay correct together.
"""
import sys

from parser import derive_project_from_cwd, normalize_project

NORMALIZE_CASES = [
    ("My Repo!", "My-Repo"),
    ("  trimmed  ", "trimmed"),
    ("a//b__c", "a-b__c"),
    ("--collapse--dashes--", "collapse-dashes"),
    ("first line\nsecond", "first-line"),
    ("x" * 100, "x" * 80),
    ("", ""),
]

# (cwd, expected_project, expected_source)
DERIVE_CASES = [
    # POSIX (unchanged behaviour)
    ("/home/me/repo", "repo", "cwd"),
    ("/Users/me/proj", "proj", "cwd"),
    ("/home/me", "unknown", "unknown"),        # user home root
    ("/Users/me", "unknown", "unknown"),
    ("/", "unknown", "unknown"),
    ("/tmp", "unknown", "unknown"),
    ("/private/tmp", "unknown", "unknown"),
    ("/srv/code/app/", "app", "cwd"),          # trailing slash
    # Windows
    ("C:\\Users\\me\\repo", "repo", "cwd"),
    ("C:\\Users\\me\\OneDrive\\Documents\\proj", "proj", "cwd"),
    ("C:\\Users\\me", "unknown", "unknown"),   # user home root
    ("C:\\", "unknown", "unknown"),            # drive root
    ("C:", "unknown", "unknown"),
    ("D:\\code\\app\\", "app", "cwd"),         # trailing backslash
    ("C:/Users/me/mixed", "mixed", "cwd"),     # mixed separators
    # UNC
    ("\\\\server\\share", "unknown", "unknown"),
    ("\\\\server\\share\\repo", "repo", "cwd"),
    # empty / missing
    ("", "unknown", "unknown"),
    (None, "unknown", "unknown"),
]


def main():
    failures = []
    for value, expected in NORMALIZE_CASES:
        got = normalize_project(value)
        if got != expected:
            failures.append(f"normalize_project({value!r}) = {got!r}, expected {expected!r}")
    for cwd, exp_proj, exp_src in DERIVE_CASES:
        proj, src = derive_project_from_cwd(cwd)
        if (proj, src) != (exp_proj, exp_src):
            failures.append(
                f"derive_project_from_cwd({cwd!r}) = {(proj, src)!r}, "
                f"expected {(exp_proj, exp_src)!r}"
            )
    if failures:
        print(f"FAILED ({len(failures)}):")
        for f in failures:
            print("  -", f)
        return 1
    print(f"OK: {len(NORMALIZE_CASES) + len(DERIVE_CASES)} cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
