#!/usr/bin/env bash
# Install the built Icinga 2 RPMs in a disposable EL9 environment and run
# non-invasive validation checks. Does NOT start the icinga2 service.
#
# Required environment variables:
#   RPM_DIR - directory containing the built *.rpm files (binary RPMs only)
set -Eeuo pipefail

RPM_DIR="${RPM_DIR:?RPM_DIR is required}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v dnf >/dev/null 2>&1 || die "dnf is required"

mapfile -t rpms < <(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm')
[[ "${#rpms[@]}" -gt 0 ]] || die "no binary RPMs found in $RPM_DIR"

# icinga2-selinux Requires icinga-selinux-common/nagios-selinux, which are
# Fedora selinux-policy subpackage names with no EL9/EPEL 9 equivalent.
# It is still built and shipped; just excluded from this install smoke test.
mapfile -t install_rpms < <(printf '%s\n' "${rpms[@]}" | grep -vE '/icinga2-selinux-[^/]+\.rpm$' || true)
[[ "${#install_rpms[@]}" -gt 0 ]] || die "no installable binary RPMs remain after excluding icinga2-selinux"

log "Installing packages via dnf with dependency resolution:"
printf '  - %s\n' "${install_rpms[@]}" >&2
dnf install -y --setopt=install_weak_deps=False "${install_rpms[@]}"

log "icinga2 --version:"
icinga2 --version || die "icinga2 --version failed"

log "Listing installed files (rpm -ql icinga2):"
rpm -ql icinga2

log "Checking for installed systemd unit file:"
unit_path="$(rpm -ql icinga2 | grep -E '/(usr/lib|lib)/systemd/system/icinga2\.service$' || true)"
if [[ -z "$unit_path" ]]; then
  die "icinga2.service systemd unit not found among installed files"
fi
[[ -f "$unit_path" ]] || die "systemd unit file listed by rpm but missing on disk: $unit_path"
log "Found systemd unit: $unit_path"

sample_config="/etc/icinga2/icinga2.conf"
if [[ -f "$sample_config" ]]; then
  log "Validating default configuration (icinga2 daemon -C); service will NOT be started"
  icinga2 daemon -C -c "$sample_config" || die "icinga2 daemon -C configuration validation failed"
else
  log "No default configuration found at $sample_config; skipping 'icinga2 daemon -C' validation"
fi

log "Installation validation completed successfully (service was not started)."
