#!/usr/bin/env bash
# Keep the Dockerfile's GIT_COMMIT pin pointing at the current application source.
#
# The image clones its source from the published repository at an exact commit
# rather than copying the build context, so every download happens at build time
# and the container needs no network at run time. That pin has to stay in step
# with the source.
#
#   ./scripts/pin_source_commit.sh            update the pin to HEAD
#   ./scripts/pin_source_commit.sh --check    exit 1 if the pin is stale
#
# What "stale" means here
# -----------------------
# Not "older than HEAD" -- a pin is fine as long as the commit it names contains
# the same source tree as HEAD for every path the image copies. That is the
# property that actually matters: it is what makes the built image identical.
#
# It also resolves the ordering problem. The commit that updates this pin edits
# only the Dockerfile, which the image never copies, so pinning to HEAD before
# making that commit leaves the pin correct afterwards.
#
# Changing the Dockerfile, docker-compose.yml, the docs or CI never requires a
# re-pin, because none of those is copied into the image.
set -euo pipefail

# Exactly the paths the Dockerfile copies out of the source stage.
SOURCE_PATHS=(
  pipeline
  ingest
  dbt
  scripts
  requirements
  dagster.yaml
  workspace.yaml
  docker-entrypoint.sh
)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/Dockerfile"
cd "${repo_root}"

# sed rather than grep -P: PCRE mode is unavailable in some locales.
current_pin="$(sed -n 's/^ARG GIT_COMMIT=\([0-9a-f]\{40\}\)$/\1/p' "${dockerfile}" | head -1)"
head_commit="$(git rev-parse HEAD)"

# Hash of each source path at a given commit. Identical output for two commits
# means an image built from either would contain byte-identical source.
source_fingerprint() {
  local commit="$1" path
  for path in "${SOURCE_PATHS[@]}"; do
    # Missing paths are reported rather than skipped, so a deletion counts as a
    # difference instead of silently matching.
    printf '%s %s\n' "${path}" "$(git rev-parse "${commit}:${path}" 2>/dev/null || echo MISSING)"
  done
}

if [ -z "${current_pin}" ]; then
  echo "error: no ARG GIT_COMMIT=<40-hex> line found in ${dockerfile}" >&2
  exit 2
fi

pin_is_current=false
if git cat-file -e "${current_pin}^{commit}" 2>/dev/null; then
  if [ "$(source_fingerprint "${current_pin}")" = "$(source_fingerprint "${head_commit}")" ]; then
    pin_is_current=true
  fi
fi

if [ "${1:-}" = "--check" ]; then
  if [ "${pin_is_current}" = true ]; then
    echo "OK: pinned ${current_pin:0:12} has the same source tree as HEAD."
    exit 0
  fi
  {
    echo "Dockerfile GIT_COMMIT is stale."
    echo
    echo "  pinned: ${current_pin}"
    echo "  HEAD:   ${head_commit}"
    echo
    echo "The pinned commit does not contain the current source, so a default"
    echo "build would produce an image from different code than this working"
    echo "tree. Differing paths:"
    echo
    diff <(source_fingerprint "${current_pin}" 2>/dev/null || true) \
         <(source_fingerprint "${head_commit}") || true
    echo
    echo "Run ./scripts/pin_source_commit.sh and commit the result."
  } >&2
  exit 1
fi

if [ "${pin_is_current}" = true ]; then
  echo "Already current: ${current_pin:0:12} matches the HEAD source tree."
  exit 0
fi

# Pinning to a commit that was never pushed produces a Dockerfile nobody else
# can build, so say so rather than failing obscurely at build time.
if ! git branch -r --contains "${head_commit}" 2>/dev/null | grep -q .; then
  echo "note: ${head_commit:0:12} is not yet on a remote branch." >&2
  echo "      Push it before building, or the default build cannot fetch it." >&2
fi

sed -i "s/^ARG GIT_COMMIT=.*/ARG GIT_COMMIT=${head_commit}/" "${dockerfile}"

echo "Pinned Dockerfile source to ${head_commit}"
echo "  (was ${current_pin})"
