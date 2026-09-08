#!/usr/bin/env bash
# Rebuild the Icinga 2 SRPM as a native EL9 package inside a mock chroot.
#
# Required environment variables:
#   SRPM_PATH      - path to the (already downloaded, signature-verified) SRPM
#   PATCH_PATH     - path to packaging/icinga2-el9.patch (may be a no-op patch)
#   MOCK_CONFIGDIR - directory containing the mock chroot config
#   MOCK_ROOT      - mock config name (config_opts['root'] value)
#   RESULT_DIR     - directory to place all build outputs, logs, and reports
#
# Optional:
#   DEBUG_MODE     - "true" to enable verbose (set -x) tracing
#
# Fails the build if zero binary RPMs are produced, or if any output RPM
# does not carry an ".el9" release tag, or if any output RPM still carries
# an ".fc44" release tag.
set -Eeuo pipefail

SRPM_PATH="${SRPM_PATH:?SRPM_PATH is required}"
PATCH_PATH="${PATCH_PATH:?PATCH_PATH is required}"
MOCK_CONFIGDIR="${MOCK_CONFIGDIR:?MOCK_CONFIGDIR is required}"
MOCK_ROOT="${MOCK_ROOT:?MOCK_ROOT is required}"
RESULT_DIR="${RESULT_DIR:?RESULT_DIR is required}"
DEBUG_MODE="${DEBUG_MODE:-false}"

# Resolve to absolute paths up front: later steps `cd` into a scratch
# workdir, at which point relative paths would no longer resolve.
SRPM_PATH="$(readlink -f "$SRPM_PATH")"
PATCH_PATH="$(readlink -f "$PATCH_PATH")"
MOCK_CONFIGDIR="$(readlink -f "$MOCK_CONFIGDIR")"
mkdir -p "$RESULT_DIR"
RESULT_DIR="$(readlink -f "$RESULT_DIR")"

if [[ "$DEBUG_MODE" == "true" ]]; then
  set -x
fi

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

WORKDIR="$(mktemp -d /tmp/icinga2-el9-build.XXXXXX)"
EXTRACT_DIR="$WORKDIR/extract"
RPMBUILD_TOP="$WORKDIR/rpmbuild"
mkdir -p "$EXTRACT_DIR" "$RPMBUILD_TOP" "$RESULT_DIR" "$RESULT_DIR/metadata" "$RESULT_DIR/rpmlint" "$RESULT_DIR/mock-logs"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
for c in rpm rpm2cpio cpio rpmbuild rpmdev-setuptree mock sha256sum; do
  require_cmd "$c"
done

# --- Step 1: log input SRPM metadata ----------------------------------------
log "Input SRPM metadata:"
{
  echo "=== rpm -qpi ==="
  rpm -qpi "$SRPM_PATH"
  echo "=== rpm -qpR ==="
  rpm -qpR "$SRPM_PATH"
  echo "=== rpm -qp --provides ==="
  rpm -qp --provides "$SRPM_PATH"
} | tee "$RESULT_DIR/metadata/input-srpm-metadata.txt" >&2

# --- Step 2: extract the spec file and sources ------------------------------
log "Extracting SRPM contents to $EXTRACT_DIR"
(cd "$EXTRACT_DIR" && rpm2cpio "$SRPM_PATH" | cpio -idmv) 2>&1 | tail -n 20 >&2

spec_file="$(find "$EXTRACT_DIR" -maxdepth 1 -name '*.spec' | head -n1)"
[[ -n "$spec_file" ]] || die "no .spec file found inside SRPM"
log "Found spec file: $(basename "$spec_file")"

# --- Step 3: detect Fedora-specific conditionals for diagnostics ------------
log "Scanning spec file for Fedora-specific markers (informational only):"
grep -nE '%\{?fedora\}?|\.fc[0-9]+|%fedora|fedora-release' "$spec_file" || log "  none found"

# --- Step 4: apply the EL9 compatibility patch, if it contains real hunks ---
patch_has_hunks="false"
if [[ -s "$PATCH_PATH" ]] && grep -qE '^(---|\+\+\+|@@)' "$PATCH_PATH"; then
  patch_has_hunks="true"
fi

if [[ "$patch_has_hunks" == "true" ]]; then
  log "Applying EL9 compatibility patch: $PATCH_PATH"
  (cd "$EXTRACT_DIR" && patch -p1 --forward --no-backup-if-mismatch < "$PATCH_PATH") \
    || die "failed to apply packaging/icinga2-el9.patch to spec file"
else
  log "No EL9 compatibility hunks present in $PATCH_PATH; current SRPM builds unchanged on EL9 apart from the release tag rewrite."
fi

# --- Step 5: rewrite Release to a clearly-identifiable internal EL9 build ---
# The Fedora spec may already use %{?dist} in Release:, or it may hardcode
# a literal Fedora release suffix (e.g. "1.fc44") that is also repeated
# verbatim in subpackage Requires/Conflicts lines (e.g.
# "Requires: icinga2-bin = 2.16.5-1.fc44"). Both forms must end up
# rewritten consistently so subpackage dependencies still resolve against
# the rebuilt NVR.
version_value="$(grep -E '^Version:' "$spec_file" | head -n1 | sed -E 's/^Version:[[:space:]]*//')"
old_release_value="$(grep -E '^Release:' "$spec_file" | head -n1 | sed -E 's/^Release:[[:space:]]*//')"
[[ -n "$version_value" && -n "$old_release_value" ]] || die "could not read Version/Release from spec file"

if [[ "$old_release_value" == *'%{?dist}'* ]]; then
  new_release_value="${old_release_value/\%\{?dist\}/.internal1%{?dist}}"
elif [[ "$old_release_value" =~ ^(.+)\.fc[0-9]+$ ]]; then
  new_release_value="${BASH_REMATCH[1]}.internal1%{?dist}"
  # Rewrite the literal upstream NVR (e.g. "2.16.5-1.fc44") to the
  # relocatable %{version}-%{release} form wherever it is hardcoded.
  old_nvr="${version_value}-${old_release_value}"
  spec_content="$(cat "$spec_file")"
  spec_content="${spec_content//$old_nvr/%{version}-%{release}}"
  printf '%s\n' "$spec_content" > "$spec_file"
else
  die "spec file Release: tag ('$old_release_value') uses neither %{?dist} nor a recognizable .fcNN suffix; refusing to guess a release rewrite"
fi

sed -i -E "s#^Release:.*#Release:        ${new_release_value}#" "$spec_file"
log "Rewritten Release line: $(grep -E '^Release:' "$spec_file")"

# --- Step 6: rebuild the SRPM with the patched/rewritten spec ---------------
log "Rebuilding SRPM with rpmbuild -bs"
HOME="$WORKDIR" rpmdev-setuptree
cp "$EXTRACT_DIR"/* "$WORKDIR"/rpmbuild/SOURCES/ 2>/dev/null || true
rm -f "$WORKDIR"/rpmbuild/SOURCES/*.spec
HOME="$WORKDIR" rpmbuild --define "_topdir $WORKDIR/rpmbuild" --define "dist .el9" \
  -bs "$spec_file" 2>&1 | tee "$RESULT_DIR/metadata/rpmbuild-bs.log" >&2

new_srpm="$(find "$WORKDIR/rpmbuild/SRPMS" -maxdepth 1 -name '*.src.rpm' | head -n1)"
[[ -n "$new_srpm" ]] || die "rpmbuild did not produce a rebuilt SRPM"
log "Rebuilt SRPM: $new_srpm"
cp "$new_srpm" "$RESULT_DIR/"

# --- Step 7: run the build inside the EL9 mock chroot -----------------------
log "Running mock build (root: $MOCK_ROOT)"
mock --configdir="$MOCK_CONFIGDIR" --root "$MOCK_ROOT" \
  --resultdir "$RESULT_DIR/mock-logs" \
  --rebuild "$new_srpm" \
  --no-clean --cleanup-after \
  || { cp "$RESULT_DIR/mock-logs"/*.log "$RESULT_DIR/mock-logs/" 2>/dev/null || true; die "mock build failed; see $RESULT_DIR/mock-logs"; }

# --- Step 8: collect and validate resulting binary RPMs ---------------------
mapfile -t built_rpms < <(find "$RESULT_DIR/mock-logs" -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm')
[[ "${#built_rpms[@]}" -gt 0 ]] || die "mock build produced zero binary RPMs"

log "Built ${#built_rpms[@]} binary RPM(s):"
for rpm_file in "${built_rpms[@]}"; do
  fname="$(basename "$rpm_file")"
  printf '  - %s\n' "$fname" >&2

  [[ "$fname" == *.el9.* || "$fname" == *.el9*.rpm ]] || die "output RPM missing .el9 release tag: $fname"
  [[ "$fname" != *.fc44.* ]] || die "output RPM still carries a Fedora .fc44 release tag: $fname"

  arch="$(rpm -qp --qf '%{ARCH}' "$rpm_file")"
  [[ "$arch" == "x86_64" || "$arch" == "noarch" ]] || die "unexpected architecture '$arch' for $fname"

  cp "$rpm_file" "$RESULT_DIR/"
done

# --- Step 9: rpmlint, metadata, checksums -----------------------------------
log "Running rpmlint (best-effort; report retained regardless of findings)"
if command -v rpmlint >/dev/null 2>&1; then
  rpmlint "${built_rpms[@]}" > "$RESULT_DIR/rpmlint/rpmlint-report.txt" 2>&1 || true
else
  echo "rpmlint not available in this environment" > "$RESULT_DIR/rpmlint/rpmlint-report.txt"
fi

: > "$RESULT_DIR/metadata/output-rpm-metadata.txt"
: > "$RESULT_DIR/checksums.sha256"
for rpm_file in "$RESULT_DIR"/*.rpm; do
  fname="$(basename "$rpm_file")"
  {
    echo "=== $fname ==="
    echo "--- rpm -qpi ---"
    rpm -qpi "$rpm_file"
    echo "--- rpm -qpR ---"
    rpm -qpR "$rpm_file"
    echo "--- rpm -qp --provides ---"
    rpm -qp --provides "$rpm_file"
    echo "--- rpm -qp --scripts ---"
    rpm -qp --scripts "$rpm_file" || true
    echo
  } >> "$RESULT_DIR/metadata/output-rpm-metadata.txt"
  sha256sum "$rpm_file" >> "$RESULT_DIR/checksums.sha256"
done

log "Build complete. Artifacts staged in $RESULT_DIR"
