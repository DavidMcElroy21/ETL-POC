#!/usr/bin/env python3
"""Fail if any AI-agent instruction file is tracked by git.

This repository is published for model testing. Assistant instruction files
(CLAUDE.md, AGENTS.md, .cursorrules, ...) would become part of the evaluation
corpus and bias results, so they must never be committed. .gitignore expresses
the intent; this script enforces it.

Exit code 0 when the working tree is clean of such files, 1 otherwise.
"""

from __future__ import annotations

import fnmatch
import subprocess
import sys

# Exact filenames, matched against the basename of every tracked path.
FORBIDDEN_NAMES = {
    "claude.md",
    "claude.local.md",
    "agents.md",
    "agent.md",
    "gemini.md",
    "copilot-instructions.md",
    ".cursorrules",
    ".windsurfrules",
    ".clinerules",
    ".aider.conf.yml",
}

# Directory names; a match anywhere in a tracked path's parents is a failure.
FORBIDDEN_DIRS = {
    ".claude",
    ".cursor",
    ".roo",
    ".continue",
    ".aider",
    ".github/instructions",
}

# Glob patterns applied to the full tracked path.
FORBIDDEN_GLOBS = (
    ".aider*",
    "**/*.prompt.md",
    "**/.claude/**",
)


def tracked_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def violations(paths: list[str]) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for path in paths:
        lowered = path.lower()
        parts = lowered.split("/")
        basename = parts[-1]

        if basename in FORBIDDEN_NAMES:
            found.append((path, f"forbidden filename '{basename}'"))
            continue

        matched_dir = next((d for d in FORBIDDEN_DIRS if d in parts), None)
        if matched_dir is not None:
            found.append((path, f"inside forbidden directory '{matched_dir}/'"))
            continue

        matched_glob = next(
            (g for g in FORBIDDEN_GLOBS if fnmatch.fnmatch(lowered, g)), None
        )
        if matched_glob is not None:
            found.append((path, f"matches forbidden pattern '{matched_glob}'"))

    return found


def main() -> int:
    try:
        paths = tracked_files()
    except subprocess.CalledProcessError:
        print("error: not a git repository (or git is unavailable)", file=sys.stderr)
        return 2

    found = violations(paths)
    if found:
        print("Agent instruction files must not be committed to this repository:\n")
        for path, reason in found:
            print(f"  {path}\n      {reason}")
        print(
            "\nRemove them with 'git rm --cached <path>' and confirm .gitignore "
            "covers the pattern."
        )
        return 1

    print(f"OK: {len(paths)} tracked files, no agent instruction files found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
