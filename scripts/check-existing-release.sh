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

command -v gh >/dev/null 2>&1 || die "gh CLI is required"

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
# gh release list only ever returns non-draft releases by default when
# --exclude-drafts is passed; we also explicitly filter out drafts here
# in case the flag is unavailable on the runner's gh version.
while IFS=$'\t' read -r tag is_draft; do
  [[ -z "$tag" ]] && continue
  [[ "$is_draft" == "true" ]] && continue
  if [[ "$tag" == "$prefix"* ]]; then
    matched_tag="$tag"
    break
  fi
done < <(gh release list --repo "$REPO" --limit 200 \
            --json tagName,isDraft \
            --jq '.[] | [.tagName, (.isDraft|tostring)] | @tsv' 2>/dev/null || true)

if [[ -n "$matched_tag" ]]; then
  log "Found existing published release matching this upstream version: $matched_tag"
  emit skip "true"
  emit matched_tag "$matched_tag"
else
  log "No existing published release found for upstream version $RPM_VERSION; build will proceed."
  emit skip "false"
  emit matched_tag ""
fi
