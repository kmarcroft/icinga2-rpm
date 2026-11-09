#!/usr/bin/env bash
# Determine whether the given upstream Icinga 2 SRPM NEVRA has already been
# successfully published as a GitHub Release. Used by the scheduled workflow
# to skip rebuilding/re-releasing an already-published upstream version.
#
# Required environment variables:
#   REPO          - "owner/repo" slug (e.g. from ${{ github.repository }})
#   RPM_VERSION   - upstream Icinga 2 version (e.g. 2.16.5)
#   GH_TOKEN      - token with permission to list releases (read-only use here)
#
# A failed or draft release is never considered "published", so a previous
# failed run will not cause the build to be skipped.
#
# Output (GITHUB_OUTPUT and stdout): skip=true|false, matched_tag=<tag or empty>
set -Eeuo pipefail

REPO="${REPO:?REPO is required}"
RPM_VERSION="${RPM_VERSION:?RPM_VERSION is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for c in curl jq; do
  command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done

emit() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$value"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

prefix="icinga2-el9-${RPM_VERSION}-"
log "Checking for an existing published release with tag prefix: $prefix"

matched_tag=""
page=1
while :; do
  releases_json="$(curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GH_TOKEN" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}")" \
    || die "failed to query GitHub releases API (page $page)"

  jq -e 'type == "array"' >/dev/null <<<"$releases_json" \
    || die "GitHub releases API returned an unexpected response (page $page)"

  while IFS=$'\t' read -r tag is_draft; do
    [[ -z "$tag" ]] && continue
    [[ "$is_draft" == "true" ]] && continue
    if [[ "$tag" == "$prefix"* ]]; then
      matched_tag="$tag"
      break 2
    fi
  done < <(jq -r '.[] | [.tag_name, (.draft|tostring)] | @tsv' <<<"$releases_json")

  release_count="$(jq 'length' <<<"$releases_json")"
  (( release_count < 100 )) && break
  (( page++ ))
done

if [[ -n "$matched_tag" ]]; then
  log "Found existing published release matching this upstream version: $matched_tag"
  emit skip "true"
  emit matched_tag "$matched_tag"
else
  log "No existing published release found for upstream version $RPM_VERSION; build will proceed."
  emit skip "false"
  emit matched_tag ""
fi
