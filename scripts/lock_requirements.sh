#!/usr/bin/env bash
# Regenerate the fully-transitive, hash-pinned lock files.
#
# The Dockerfile installs the .lock files with --require-hashes, so nothing is
# resolved at image build time. Refreshing versions is therefore a deliberate
# act: edit requirements/*.txt, run this script, review the lock diff, commit.
#
# Resolution runs inside the same base image the Dockerfile uses, pinned by
# digest, so the locks match the interpreter and platform that will install
# them.
set -euo pipefail

BASE_IMAGE="python@sha256:0bee7276f83efd4a1ee05bbbf4281d95ed28e079220a9457f25a93e3f1e3c31b"
UV_VERSION="0.12.7"

# Git Bash / MSYS rewrites anything that looks like an absolute path, which
# corrupts the container side of a -v mount. Disable that, and hand Docker a
# native Windows host path via `pwd -W`. Both are no-ops on Linux and macOS.
export MSYS_NO_PATHCONV=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if host_root="$(cd "${repo_root}" && pwd -W 2>/dev/null)"; then
  repo_root_for_docker="${host_root}"
else
  repo_root_for_docker="${repo_root}"
fi

docker run --rm \
  -v "${repo_root_for_docker}/requirements:/w" \
  -w /w \
  "${BASE_IMAGE}" \
  sh -eux -c "
    pip install --no-cache-dir --quiet uv==${UV_VERSION}
    for name in ingest orchestrator; do
      uv pip compile \
        --generate-hashes \
        --python-version 3.11 \
        --no-header \
        --output-file \"\${name}.lock\" \
        \"\${name}.txt\"
    done
  "

echo
echo "Regenerated:"
wc -l "${repo_root}/requirements/ingest.lock" "${repo_root}/requirements/orchestrator.lock"
