# icinga2-el9

Internal rebuild pipeline that produces native Enterprise Linux 9 (`.el9`) RPM
packages for **Icinga 2 only**, because Icinga no longer publishes official
EL9 binaries. The newest Fedora 44 Icinga 2 SRPM is used strictly as a source
and packaging baseline; every package is rebuilt from source inside a genuine
EL9 build root.

> **Disclaimer:** The packages produced by this repository are an **internal,
> unofficial rebuild**. They are not produced, signed, or supported by Icinga.
> Use at your own risk and validate in a non-production environment first.

## 1. Purpose and scope

- Builds only the `icinga2` package (no Icinga Web, Director, Icinga DB, or
  modules).
- Target: x86_64, Enterprise Linux 9 (RHEL 9 / AlmaLinux 9 / Rocky Linux 9
  compatible).
- Fully automated via GitHub Actions: discovery, verification, build, test,
  and optional release.

## 2. Repository layout

```
.github/workflows/build-icinga2-el9.yml  GitHub Actions pipeline
scripts/find-latest-srpm.sh              Discover/download/verify newest SRPM
scripts/build-icinga2-el9.sh             Patch, rebuild SRPM, run mock, validate output
scripts/check-existing-release.sh        New-version detection for scheduled runs
scripts/generate-manifest.sh             Build manifest JSON generator
scripts/test-install-el9.sh              Fresh-install validation (no service start)
packaging/icinga2-el9.patch              EL9 compatibility patch (currently a no-op)
mock/icinga2-el9-x86_64.cfg              Standalone mock chroot definition
```

## 3. Why the Fedora SRPM is used only as a source baseline

Icinga publishes source RPMs for Fedora 44 only. The SRPM contains the
authoritative upstream source tarball, patches, and packaging logic Icinga
maintains — reusing it avoids re-inventing the spec file. However, a Fedora
44 **binary** RPM is not ABI/dependency compatible with EL9 (different glibc,
OpenSSL, Boost, systemd, and compiler versions), so binary Fedora RPMs are
never installed or relabeled; only the **source** RPM is reused.

## 4. Why the package is rebuilt inside EL9

Rebuilding from source inside an EL9 root guarantees the resulting binaries
are linked against EL9's actual OpenSSL, Boost, systemd, and libc, and that
the `.el9` release tag accurately reflects the build environment.

## 5. Selected EL9 build-root distribution and justification

**AlmaLinux 9** was selected as the mock chroot and CI host distribution:

- 1:1 binary-compatible rebuild of RHEL 9 (matches RHEL 9 package versions
  and ABI), so packages built here install cleanly on RHEL 9, Rocky Linux 9,
  and AlmaLinux 9.
- Actively maintained with fast, reliable public mirrors suitable for CI.
- Rocky Linux 9 would be an equally valid choice; either satisfies the EL9
  compatibility requirement. AlmaLinux was chosen here for CI mirror
  stability; swapping to Rocky only requires editing the `baseurl`s and GPG
  key paths in [`mock/icinga2-el9-x86_64.cfg`](mock/icinga2-el9-x86_64.cfg).

## 6. Enabled build repositories

Inside the mock chroot (see `mock/icinga2-el9-x86_64.cfg`):

- AlmaLinux 9 BaseOS
- AlmaLinux 9 AppStream
- AlmaLinux 9 CRB (CodeReady Builder / `crb`)
- EPEL 9 (`Everything/x86_64`)

All repos have `gpgcheck=1` with keys sourced from the `distribution-gpg-keys`
package (installed on the CI host from EPEL 9). No repository is added with
GPG checking disabled, and `--nogpgcheck` is never used.

## 7. Required GitHub permissions and secrets

- No secrets are required. The workflow uses the default `GITHUB_TOKEN` only.
- Top-level workflow permissions are `contents: read`. Only the `release`
  job elevates to `contents: write`, scoped to that job alone, to create
  GitHub Releases.
- Third-party actions (`actions/checkout`, `actions/upload-artifact`,
  `actions/download-artifact`, `actions/cache`) are pinned to immutable
  commit SHAs.

## 8. Manual workflow instructions

Run **Actions → Build Icinga 2 for EL9 → Run workflow** with optional inputs:

- `srpm_url` — explicit SRPM URL, bypassing discovery.
- `version_override` — restrict discovery to a specific upstream version.
- `target_arch` — currently `x86_64` only.
- `debug_mode` — verbose logging in build scripts.
- `create_release` — attach a GitHub Release to this run's build.

## 9. Scheduled workflow behavior

The workflow runs weekly (`cron: "17 3 * * 1"`). On schedule triggers only,
`scripts/check-existing-release.sh` checks whether the newest upstream
version has already been published as a GitHub Release; if so, the build,
test, and release jobs are skipped and the job summary states why. A
previously **failed** run is never treated as "published", so a failed
scheduled build will be retried on the next run.

## 10. How newest-version detection works

`scripts/find-latest-srpm.sh` parses the Icinga directory listing at
`https://packages.icinga.com/fedora/44/release/src/icinga2/`, extracts all
`icinga2-<version>-<release>.src.rpm` filenames (excluding debug packages,
binaries, and non-package links), and selects the highest EVR using
`rpmdev-vercmp` (RPM-aware comparison, not lexical sort).

## 11. How SRPM signature verification works

1. The official Icinga signing key is downloaded over HTTPS from
   `https://packages.icinga.com/icinga.key`.
2. The key is imported into the local RPM keyring (`rpm --import`).
3. `rpmkeys --checksig` is run against the downloaded SRPM; the workflow
   fails unless the output shows a valid `gpg`/`pgp` signature and no
   `NOT OK`, `BAD`, or `MISSING KEYS` markers.
4. If verification cannot be completed for any reason, the script fails
   with a clear, non-silent error — it never falls back to skipping the
   check.

## 12. How to reproduce the build locally

On an EL9-family host (or inside a privileged AlmaLinux 9 / Rocky Linux 9
container) with `mock`, `rpmdevtools`, `rpm-build`, `rpmlint`,
`distribution-gpg-keys`, `gnupg2`, and `curl` installed:

```bash
git clone <this-repo> && cd icinga2-el9
export WORKDIR="$PWD/work"
scripts/find-latest-srpm.sh

SRPM_PATH="$(ls "$WORKDIR"/*.src.rpm)"
export SRPM_PATH PATCH_PATH=packaging/icinga2-el9.patch \
       MOCK_CONFIGDIR=mock MOCK_ROOT=icinga2-el9-x86_64 RESULT_DIR=result
sudo -E scripts/build-icinga2-el9.sh
```

`mock` requires root or membership in the `mock` group and typically needs
elevated container privileges (bind mounts, namespaces).

## 13. How to inspect the generated RPMs

```bash
rpm -qpi result/icinga2-*.el9.x86_64.rpm      # package info
rpm -qpR result/icinga2-*.el9.x86_64.rpm      # dependencies
rpm -qp --provides result/icinga2-*.el9.x86_64.rpm
rpm -qp --scripts result/icinga2-*.el9.x86_64.rpm
sha256sum -c result/checksums.sha256
cat result/build-manifest.json
```

## 14. How to test installation on AlmaLinux 9, Rocky Linux 9, and RHEL 9

Copy the RPMs from the `icinga2-el9-<version>-x86_64` artifact into a fresh
VM or container of the target distribution, then:

```bash
dnf install -y ./icinga2-*.el9.x86_64.rpm
icinga2 --version
rpm -ql icinga2
```

The CI pipeline's `test-install` job performs an equivalent check
automatically on AlmaLinux 9 for every build; it does **not** start the
`icinga2` service, since that requires a full runtime configuration.

## 15. How to update the compatibility patch

1. Extract the current spec: `rpm2cpio icinga2-*.src.rpm | cpio -idmv`.
2. Make the minimal edit needed for EL9 compatibility directly on
   `icinga2.spec`.
3. Generate a diff: `diff -u icinga2.spec.orig icinga2.spec > packaging/icinga2-el9.patch`.
4. Keep the patch scoped to build compatibility only — never change
   `Version:`, `Source0`, or upstream functionality.
5. Document the reason for the change in this section (update this file)
   and reference the specific upstream SRPM NEVRA the patch was written
   against.

`scripts/build-icinga2-el9.sh` automatically detects whether the patch file
contains real diff hunks; an empty/no-op patch (the current state) is
logged and skipped cleanly.

## 16. Known limitations

- Only `x86_64` is currently supported.
- `mock` requires a privileged container (`options: --privileged` on the
  `build` job); GitHub-hosted runners generally support this, but
  self-hosted runners with stricter Docker daemon policies may need
  additional capabilities enabled.
- The rebuilt RPMs are unsigned; no private signing key is provisioned in
  this pipeline.
- `packaging/icinga2-el9.patch` is currently empty — it must be reviewed
  and updated the first time a real Fedora-only construct is discovered in
  a newer SRPM.

## 17. Security considerations

- All network fetches use `https://` with `curl --fail --location --show-error`
  plus retry/timeout limits; TLS verification is never disabled.
- The Icinga SRPM's GPG signature is mandatory and verified before any
  build step runs; `--nogpgcheck` is never used anywhere in this pipeline.
- Downloaded shell scripts are never executed; only the SRPM (rebuilt via
  `rpmbuild`/`mock`) is processed.
- All third-party GitHub Actions are pinned to immutable commit SHAs.
- The default `GITHUB_TOKEN` is used with least-privilege permissions;
  `contents: write` is scoped only to the `release` job.
- A concurrency group prevents overlapping duplicate builds per ref.
- The `build` job's privileged container is required by `mock` for chroot
  and namespace operations; the Docker socket itself is never mounted or
  exposed to the workflow.

## 18. Troubleshooting missing BuildRequires

If mock fails with an unresolved `BuildRequires`:

1. Check whether the package exists in BaseOS/AppStream/CRB/EPEL 9 — search
   at <https://mirror.stream.centos.org/9-stream/> or the AlmaLinux/EPEL
   package browsers.
2. If it is EL9/EPEL9-available but missing from this pipeline's repo list,
   add it to `mock/icinga2-el9-x86_64.cfg`.
3. If the dependency genuinely does not exist for EL9 (Fedora-only package),
   it must be rebuilt separately as its own EL9 SRPM — **do not** pull a
   Fedora binary RPM into the mock root. Document the missing dependency and
   fail the build clearly; this is treated as a hard blocker, not worked
   around.

## 19. Disclaimer

This project produces an **internal rebuild** of Icinga 2 for EL9. It is
**not** an official Icinga-supported package, is not affiliated with or
endorsed by Icinga GmbH, and carries no support guarantee. Validate
thoroughly before using in production.
