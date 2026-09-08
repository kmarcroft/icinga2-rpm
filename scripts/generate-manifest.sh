#!/usr/bin/env bash
# Generate a JSON build manifest describing this build's provenance.
#
# Required environment variables:
#   RESULT_DIR        - directory containing the built RPMs/SRPM
#   RUN_ID            - GitHub Actions workflow run ID
#   COMMIT_SHA        - Git commit SHA that triggered the build
#   RUNNER_IMAGE_NAME  - description of the runner/container image used
#   TARGET_DIST       - target distribution tag, e.g. "el9"
#   TARGET_ARCH       - target architecture, e.g. "x86_64"
#   UPSTREAM_SRPM_URL - URL the upstream SRPM was downloaded from
#   UPSTREAM_NEVRA    - upstream SRPM NEVRA string
#   GPG_VERIFIED      - "true"/"false" upstream signature verification result
#   REPO_DEFINITIONS  - human-readable summary of repos used during the build
set -Eeuo pipefail

RESULT_DIR="${RESULT_DIR:?RESULT_DIR is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
COMMIT_SHA="${COMMIT_SHA:?COMMIT_SHA is required}"
RUNNER_IMAGE_NAME="${RUNNER_IMAGE_NAME:?RUNNER_IMAGE_NAME is required}"
TARGET_DIST="${TARGET_DIST:?TARGET_DIST is required}"
TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH is required}"
UPSTREAM_SRPM_URL="${UPSTREAM_SRPM_URL:?UPSTREAM_SRPM_URL is required}"
UPSTREAM_NEVRA="${UPSTREAM_NEVRA:?UPSTREAM_NEVRA is required}"
GPG_VERIFIED="${GPG_VERIFIED:?GPG_VERIFIED is required}"
REPO_DEFINITIONS="${REPO_DEFINITIONS:?REPO_DEFINITIONS is required}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v rpm >/dev/null 2>&1 || { echo "ERROR: rpm is required" >&2; exit 1; }

build_date_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

output_nevras="[]"
for rpm_file in "$RESULT_DIR"/*.rpm; do
  [[ -e "$rpm_file" ]] || continue
  nevra="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$rpm_file")"
  output_nevras="$(jq -c --arg n "$nevra" '. + [$n]' <<<"$output_nevras")"
done

jq -n \
  --arg run_id "$RUN_ID" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg build_date_utc "$build_date_utc" \
  --arg runner_image "$RUNNER_IMAGE_NAME" \
  --arg target_dist "$TARGET_DIST" \
  --arg target_arch "$TARGET_ARCH" \
  --arg upstream_srpm_url "$UPSTREAM_SRPM_URL" \
  --arg upstream_nevra "$UPSTREAM_NEVRA" \
  --arg gpg_verified "$GPG_VERIFIED" \
  --arg repo_definitions "$REPO_DEFINITIONS" \
  --argjson output_nevras "$output_nevras" \
  '{
    workflow_run_id: $run_id,
    git_commit_sha: $commit_sha,
    build_date_utc: $build_date_utc,
    runner_image: $runner_image,
    target_distribution: $target_dist,
    architecture: $target_arch,
    upstream_srpm_url: $upstream_srpm_url,
    upstream_srpm_nevra: $upstream_nevra,
    upstream_signature_verified: ($gpg_verified == "true"),
    output_rpm_nevras: $output_nevras,
    repository_definitions: $repo_definitions,
    disclaimer: "This is an internally rebuilt package set for EL9. It is not an official Icinga-supported EL9 package."
  }' > "$RESULT_DIR/build-manifest.json"

echo "Build manifest written to $RESULT_DIR/build-manifest.json" >&2
cat "$RESULT_DIR/build-manifest.json" >&2
