#!/usr/bin/env bash
# Discover, download and signature-verify the newest Icinga 2 SRPM published
# under the Fedora 44 release tree, or use an explicit SRPM URL if provided.
#
# Outputs (written to $GITHUB_OUTPUT when set, always echoed to stdout):
#   srpm_path      - local path to the downloaded (and verified) SRPM
#   srpm_filename  - filename of the SRPM
#   srpm_url       - URL the SRPM was downloaded from
#   rpm_name       - RPM "Name" tag
#   rpm_epoch      - RPM "Epoch" tag (or "(none)")
#   rpm_version    - RPM "Version" tag
#   rpm_release    - RPM "Release" tag
#   rpm_nevra      - full NEVRA string
#   sha256         - sha256 checksum of the downloaded SRPM
#   gpg_verified   - "true" if the SRPM header signature was verified
set -Eeuo pipefail

SRC_DIR_URL="${SRC_DIR_URL:-https://packages.icinga.com/fedora/44/release/src/icinga2/}"
ICINGA_GPG_KEY_URL="${ICINGA_GPG_KEY_URL:-https://packages.icinga.com/icinga.key}"
EXPLICIT_SRPM_URL="${EXPLICIT_SRPM_URL:-}"
VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
WORKDIR="${WORKDIR:-$(pwd)/work}"
CURL_OPTS=(--fail --location --show-error --silent --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 15 --max-time 300 --proto '=https' --tlsv1.2)

mkdir -p "$WORKDIR"
cd "$WORKDIR"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

emit() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$value"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for c in curl rpm rpmkeys rpmdev-vercmp grep sha256sum; do
  require_cmd "$c"
done

# --- Step 1: determine the SRPM URL -----------------------------------------
srpm_url=""

if [[ -n "$EXPLICIT_SRPM_URL" ]]; then
  [[ "$EXPLICIT_SRPM_URL" == https://* ]] || die "explicit SRPM URL must use HTTPS: $EXPLICIT_SRPM_URL"
  srpm_url="$EXPLICIT_SRPM_URL"
  log "Using explicit SRPM URL: $srpm_url"
else
  [[ "$SRC_DIR_URL" == https://* ]] || die "source directory URL must use HTTPS: $SRC_DIR_URL"
  log "Fetching directory listing: $SRC_DIR_URL"
  index_html="$(curl "${CURL_OPTS[@]}" "$SRC_DIR_URL")" || die "failed to fetch directory listing"

  # Extract href values that look like an Icinga 2 SRPM filename, excluding
  # debuginfo/debugsource packages, binary RPMs, and any non-icinga2 hrefs
  # (parent directory links, query-string sort links, etc).
  mapfile -t candidates < <(
    printf '%s\n' "$index_html" \
      | grep -oE 'href="[^"]+"' \
      | sed -E 's/^href="([^"]+)"$/\1/' \
      | grep -E '^icinga2-[0-9][^\"]*\.src\.rpm$' \
      | grep -vE 'debuginfo|debugsource' \
      | sort -u
  )

  [[ "${#candidates[@]}" -gt 0 ]] || die "no candidate Icinga 2 SRPMs found at $SRC_DIR_URL"

  log "Found ${#candidates[@]} candidate SRPM(s):"
  printf '  - %s\n' "${candidates[@]}" >&2

  # Parse "version-release" out of each filename for RPM-aware comparison.
  best_file=""
  best_evr=""
  for f in "${candidates[@]}"; do
    if [[ "$f" =~ ^icinga2-([0-9][0-9A-Za-z.~^+]*)-([0-9][0-9A-Za-z.~^+]*)\.src\.rpm$ ]]; then
      ver="${BASH_REMATCH[1]}"
      rel="${BASH_REMATCH[2]}"
    else
      log "Skipping unparsable filename: $f"
      continue
    fi

    if [[ -n "$VERSION_OVERRIDE" && "$ver" != "$VERSION_OVERRIDE" ]]; then
      continue
    fi

    evr="${ver}-${rel}"
    if [[ -z "$best_file" ]]; then
      best_file="$f"; best_evr="$evr"
      continue
    fi

    set +e
    rpmdev-vercmp "$evr" "$best_evr" >/tmp/vercmp.out 2>&1
    rc=$?
    set -e
    case "$rc" in
      11) best_file="$f"; best_evr="$evr" ;;   # candidate is newer
      0|12) : ;;                                # equal or older, keep current best
      *) die "rpmdev-vercmp failed comparing '$evr' vs '$best_evr': $(cat /tmp/vercmp.out)" ;;
    esac
  done

  [[ -n "$best_file" ]] || die "no valid Icinga 2 SRPM matched the requested criteria (version override: '${VERSION_OVERRIDE:-any}')"
  srpm_url="${SRC_DIR_URL%/}/${best_file}"
  log "Selected newest SRPM: $best_file (EVR: $best_evr)"
fi

srpm_filename="$(basename "$srpm_url")"
srpm_path="$WORKDIR/$srpm_filename"

# --- Step 2: download the SRPM ----------------------------------------------
log "Downloading: $srpm_url"
curl "${CURL_OPTS[@]}" --output "$srpm_path" "$srpm_url" || die "failed to download SRPM from $srpm_url"
[[ -s "$srpm_path" ]] || die "downloaded SRPM is empty: $srpm_path"

sha256="$(sha256sum "$srpm_path" | awk '{print $1}')"
log "SHA-256: $sha256"

# --- Step 3: import Icinga signing key and verify the SRPM signature --------
[[ "$ICINGA_GPG_KEY_URL" == https://* ]] || die "Icinga GPG key URL must use HTTPS: $ICINGA_GPG_KEY_URL"
key_path="$WORKDIR/icinga.key"
log "Downloading Icinga signing key: $ICINGA_GPG_KEY_URL"
curl "${CURL_OPTS[@]}" --output "$key_path" "$ICINGA_GPG_KEY_URL" || die "failed to download Icinga signing key"
[[ -s "$key_path" ]] || die "downloaded Icinga signing key is empty"

log "Importing Icinga signing key into local RPM keyring"
rpm --import "$key_path" || die "failed to import Icinga signing key"

log "Verifying SRPM header/payload signature"
set +e
checksig_output="$(rpmkeys --checksig "$srpm_path" 2>&1)"
checksig_rc=$?
set -e
printf '%s\n' "$checksig_output" >&2

# Confirm a GPG signature tag actually exists in the header (rpm's
# --checksig summary line does not always name "gpg"/"pgp" explicitly
# across rpm versions, e.g. "digests signatures OK"), independent of the
# wording of the summary line above.
sig_tags="$(rpm -qp --qf '%{SIGPGP:pgpsig} %{SIGGPG:pgpsig}\n' "$srpm_path" 2>/dev/null || true)"
log "Signature header tags: $sig_tags"

gpg_verified="false"
if [[ $checksig_rc -eq 0 ]] \
   && printf '%s' "$checksig_output" | grep -qi 'OK' \
   && ! printf '%s' "$checksig_output" | grep -qiE 'NOT OK|MISSING KEYS|BAD' \
   && printf '%s' "$sig_tags" | grep -qivE '^\(none\)[[:space:]]*\(none\)$'; then
  gpg_verified="true"
fi

if [[ "$gpg_verified" != "true" ]]; then
  die "SRPM signature verification FAILED for $srpm_filename. rpmkeys output: $checksig_output"
fi
log "Signature verification result: OK (gpg signature present and valid)"

# --- Step 4: inspect RPM metadata -------------------------------------------
rpm_name="$(rpm -qp --qf '%{NAME}' "$srpm_path")"
rpm_epoch="$(rpm -qp --qf '%{EPOCH}' "$srpm_path")"
rpm_version="$(rpm -qp --qf '%{VERSION}' "$srpm_path")"
rpm_release="$(rpm -qp --qf '%{RELEASE}' "$srpm_path")"
rpm_nevra="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$srpm_path")"

[[ "$rpm_name" == "icinga2" ]] || die "downloaded SRPM does not appear to be the icinga2 package (got name: $rpm_name)"

log "Selected SRPM NEVRA: $rpm_nevra"

emit srpm_path "$srpm_path"
emit srpm_filename "$srpm_filename"
emit srpm_url "$srpm_url"
emit rpm_name "$rpm_name"
emit rpm_epoch "$rpm_epoch"
emit rpm_version "$rpm_version"
emit rpm_release "$rpm_release"
emit rpm_nevra "$rpm_nevra"
emit sha256 "$sha256"
emit gpg_verified "$gpg_verified"
