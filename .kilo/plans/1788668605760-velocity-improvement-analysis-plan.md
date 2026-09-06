# Velocity Linux — Improvement Analysis & Plan

## Status: ALL PHASES COMPLETED

This plan has been implemented. See "Implementation Summary" at the bottom for
details on all changes made.

## Project Summary

Velocity Linux is an Arch Linux-based live ISO distribution built with `archiso`.
The build pipeline runs in GitHub Actions (`ubuntu-latest`) inside a privileged
`archlinux:latest` Docker container. Build artifacts (AUR packages) are compiled,
placed into `releng/airootfs/packages/`, a local pacman repo is created, and
`mkarchiso` assembles the final ISO.

**Key components:**
- `installdeps-gh-runner.sh` — installs deps, compiles AUR packages, builds local repo
- `buildiso-gh-runner.sh` — installs archiso, runs `mkarchiso`
- `releng/profiledef.sh` — archiso profile definition + debug `make_customize_airootfs()`
- `releng/pacman.conf` — pacman config with custom `[packages]` repo
- `releng/packages.x86_64` — list of all packages to include in ISO
- `releng/airootfs/root/customize_airootfs.sh` — chroot customization script (user setup, SDDM, Plymouth)
- `.github/workflows/build-velocity-iso.yml` — main CI workflow
- `.github/workflows/Gentoo.yml` / `F.yml` — experimental Gentoo builds (Firefox/Epiphany)

---

## Analysis — Issues Found

### 1. `installdeps-gh-runner.sh` — Monolithic, repeated build pattern (HIGH)

The entire 168-line script repeats this 4-line pattern **16 times**:

```bash
cd <dir>
chown -R builder:builder .
sudo -u builder makepkg --noconfirm --skippgpcheck [--nodeps]
find *.pkg.tar.zst
cp *.pkg.tar.zst /workspace/releng/airootfs/packages/
```

**Problems:**
- Massive code duplication (16x repeated block)
- `cd ..` + `cd <dir>` pattern instead of absolute paths
- `find *.pkg.tar.zst` — `find` is wrong here; should be a simple glob (`cp *.pkg.tar.zst`)
- No `set -e` — if one build fails, the script continues, producing a broken repo
- No error handling on `find` — silently copies nothing if makepkg fails

**Improvement:** Extract into a reusable function:
```bash
build_aur_pkg() {
  local dir="$1"
  local extra_flags="${2:-}"
  echo "Building $dir..."
  cd "/tmp/$dir"
  chown -R builder:builder .
  sudo -u builder makepkg --noconfirm --skippgpcheck $extra_flags
  cp *.pkg.tar.zst "$PKG_DIR/"
}
```

### 2. `installdeps-gh-runner.sh` — No error handling or `set -e` (HIGH)

There is no `set -e`, no `trap`, and no `|| exit 1` anywhere. If `git clone` fails
(network), `makepkg` fails (dependency issue), or `repo-add` fails, the script
continues silently and may produce a broken ISO.

**Improvement:** Add `set -euo pipefail` at the top, plus a trap for cleanup.

### 3. `installdeps-gh-runner.sh` — No AUR package caching (MEDIUM)

Each CI run rebuilds **all** AUR packages from source. The GitHub Actions Docker
container starts fresh, so there are no package caches or `makepkg` cache hits.

**Improvement options:**
- Enable `ccache` for repeated C/C++ compilations (quickshell, google-breakpad, Firefox via Gentoo)
- Cache `/var/cache/pacman/pkg` and `/tmp` between workflow runs using `actions/cache`
- Consider using pre-built binary packages where available (e.g., `zen-browser-bin` is already a binary — could be installed directly rather than built from AUR PKGBUILD)

### 4. `profiledef.sh` — Debug `make_customize_airootfs()` left in production (HIGH)

Lines 32–70 contain a `make_customize_airootfs()` function with debug `echo`
statements (`df -h`, `ls -lh /packages`, checking zen-browser installation). This
function is **never called** — it is not a standard archiso hook. The actual
customization happens in `airootfs/root/customize_airootfs.sh`.

**Problem:** Dead debug code that confuses maintainers and clutters the build output.

**Improvement:** Remove the `make_customize_airootfs()` function entirely, or
replace with meaningful comments explaining the build configuration.

### 5. `profiledef.sh` — Inconsistent compression settings (MEDIUM)

- Line 16: `#_squashfscomp=('gzip')` — commented out
- Line 19: `airootfs_image_tool_options=('-comp' 'gzip' '-b' '1M')` — uses **gzip**
- Dockerfile (line 8): patches the system-wide profiledef to force **zstd**
- CI workflow has a debug step that tests both zstd and gzip

The Dockerfile sed command modifies `/usr/share/archiso/configs/releng/profiledef.sh`
(the system template), but `mkarchiso -v /workspace/releng` uses the **workspace**
`profiledef.sh`. The Dockerfile patch may not affect the actual build.

**Improvement:** Set `_squashfscomp=('zstd')` directly in `releng/profiledef.sh`
and remove the commented-out gzip line and the Dockerfile sed hack.

### 6. `profiledef.sh` — `file_permissions` references non-existent paths (LOW)

Lines 25–28 reference `/usr/local/bin/choose-mirror`, `/usr/local/bin/Installation_guide`,
`/usr/local/bin/livecd-sound` — these are from the default archiso template but
Velocity does not include them. If `mkarchiso` encounters these in `file_permissions`
and the files don't exist, it may emit errors.

**Improvement:** Remove entries for paths that don't exist in this profile, or
add the missing scripts if they are intended.

### 7. `customize_airootfs.sh` — Broken relative paths in chmod (HIGH)

Lines 65–71 use paths like `releng/airootfs/usr/share/backgrounds` which are
**relative paths**. In the archiso chroot context, the working directory is the
airootfs root, so these paths are invalid — they should be absolute (`/usr/share/...`).

```bash
chmod 755 releng/airootfs/usr/share/backgrounds          # WRONG — relative path
chmod 644 releng/airootfs/usr/share/backgrounds/velocity/default-wallpaper.jpg  # WRONG
chmod 777 releng/airootfs/usr/share/icons/velocity.png   # WRONG
```

**Improvement:** Use absolute paths:
```bash
chmod 755 /usr/share/backgrounds
chmod 644 /usr/share/backgrounds/velocity/default-wallpaper.jpg
chmod 777 /usr/share/icons/velocity.png
```

### 8. `customize_airootfs.sh` — Sets `/usr/bin/yay` executable (MEDIUM)

Line 73: `chmod +x /usr/bin/yay` — the `yay` package is built in `installdeps-gh-runner.sh`
and installed into the ISO via pacman. The binary location may differ (e.g.,
`/usr/bin/yay` vs `/usr/local/bin/yay`). If the package installed `yay` to a
different path, this chmod is a no-op; if not installed at all, it errors.

**Improvement:** Remove this line — the AUR package handles its own permissions.

### 9. `customize_airootfs.sh` — Duplicate zsh shell setting (LOW)

Line 13: `sed -i 's|SHELL=/bin/bash|SHELL=/usr/bin/zsh|' /etc/default/useradd`
is also done in `profiledef.sh:65` (inside the debug function). Even after removing
the debug function, the setting here is redundant if `useradd` defaults are already
zsh — but since the base image uses bash, this is actually needed.

**Improvement:** Keep the line here, remove from profiledef.sh (once debug function
is removed).

### 10. `.github/workflows/build-velocity-iso.yml` — Debug step always runs (LOW)

Lines 44–57 ("Debug compression settings") run a separate Docker container to test
zstd/gzip compressors before the actual build. This adds ~1–2 minutes to every build.

**Improvement:** Make it conditional on `workflow_dispatch` or a job-level flag,
or remove it entirely since the compression choice should be fixed in `profiledef.sh`.

### 11. `.github/workflows/build-velocity-iso.yml` — Weak ISO verification (MEDIUM)

The integrity test (lines 89–99) only checks:
1. File type contains "ISO 9660"
2. File size >= 500MB

No checksum verification, no content inspection, no bootability check.

**Improvement:** Add `sha256sum` output and comparison against a known good hash.
Optionally add a `isoinfo -d` check for valid ISO 9660 boot records.

### 12. `.github/workflows/build-velocity-iso.yml` — No build step failure isolation (MEDIUM)

Lines 59–70: Both `installdeps-gh-runner.sh` and `buildiso-gh-runner.sh` run in a
single `docker run` command. If installdeps succeeds but buildiso fails (or vice
versa), debugging is harder because both are combined.

**Improvement:** Split into separate steps or separate `docker run` calls so
artifact caching and failure debugging are easier.

### 13. `Dockerfile` (root) — Unused by CI (LOW)

The root `Dockerfile` (FROM archlinux:latest, installs archiso/git/sudo) is not
referenced by the CI workflow, which builds directly on `archlinux:latest` with
inline bash. It appears to be for local development only.

**Improvement:** Either document its purpose or remove it if unused. If used for
local dev, add archiso to the installed packages.

### 14. `.devcontainer/Dockerfile` — Missing archiso for local dev (LOW)

The devcontainer installs `base-devel git vim python` but not `archiso`, so local
ISO building is not supported from the devcontainer.

**Improvement:** Add `archiso squashfs-tools` to the devcontainer packages, and
document the local build workflow.

### 15. `packages.x86_64` — AUR packages listed without local repo awareness (LOW)

Lines 159–215 list AUR packages (`adw-gtk-theme-git`, `catppuccin-gtk-theme-mocha`,
`fantasque-sans-mono`, `niri`, `quickshell-git`, `yay`, `zen-browser-bin`, etc.).
Some of these are also built in `installdeps-gh-runner.sh` and placed in
`airootfs/packages/` as a local repo. Packages that appear in **both** the local
repo and are listed in `packages.x86_64` are resolved by the local repo first —
this is correct but should be documented.

**Note:** `catppuccin-gtk-theme-mocha-1.0.3-1-any.pkg.tar.zst` is checked into
`airootfs/packages/` but the package is also listed in `packages.x86_64`.

### 16. `installdeps-gh-runner.sh` — `--nodeps` on zen-browser only (LOW)

Only `zen-browser-bin` is built with `--nodeps`. This flag skips dependency
resolution, which may have been needed to resolve a circular dependency or
missing dep in the AUR PKGBUILD. Should be documented.

### 17. `installdeps-gh-runner.sh` — `repo-add -s` signs database (MEDIUM)

`repo-add -s -v` signs the database with a GPG key. In CI without GPG keys
configured, signing may fail or produce warnings. The `pacman.conf` has
`SigLevel = Optional TrustAll` for the `[packages]` repo, so unsigned repos
would work.

**Improvement:** Either set up GPG signing in CI, or use `repo-add -v` (without `-s`).

### 18. Missing `.gitignore` for archiso build artifacts (LOW)

`mkarchiso` creates `work/` and `out/` directories that are likely not tracked.
No `.gitignore` exists to exclude them.

**Improvement:** Add a `.gitignore` with `out/` and `work/`.

### 19. `Gentoo.yml` — Typo in artifact path (BUG)

Line 60: `path: ./local_pack ages/` has a **space** in the path — this is clearly
a typo and will fail or upload the wrong path.

**Improvement:** Fix to `path: ./local_packages/`.

### 20. `customize_airootfs.sh` — SDDM autologin session mismatch (MEDIUM)

Line 61: `Session=niri.desktop` — the SDDM session file for niri is `niri.desktop`.
This should work if the `niri` package installs `/usr/share/wayland-sessions/niri.desktop`.
However, the `XDG_MENU_PREFIX` is set to `"plasma-"` in niri config for Dolphin
compatibility, which is a workaround. Verify this is intentional.

---

## Improvement Plan (Prioritized)

### Phase 1 — Critical Fixes (Must do)

| # | Task | File(s) | Risk |
|---|------|---------|------|
| 1 | Remove dead `make_customize_airootfs()` debug function | `releng/profiledef.sh:32-70` | Low |
| 2 | Fix broken relative paths in chmod to absolute paths | `releng/airootfs/root/customize_airootfs.sh:65-71` | Medium |
| 3 | Add `set -euo pipefail` + error handling to installdeps | `installdeps-gh-runner.sh:1` | Medium |
| 4 | Fix typo `./local_pack ages/` → `./local_packages/` | `.github/workflows/Gentoo.yml:60` | Low |

### Phase 2 — Build Script Refactor (High value, medium risk)

| # | Task | File(s) | Risk |
|---|------|---------|------|
| 5 | Extract repeated build pattern into a function | `installdeps-gh-runner.sh` | Medium |
| 6 | Remove `--nodeps` from zen-browser (verify first) | `installdeps-gh-runner.sh:16` | Medium |
| 7 | Fix `find *.pkg.tar.zst` → `cp *.pkg.tar.zst` | `installdeps-gh-runner.sh` (all instances) | Low |
| 8 | Remove `chmod +x /usr/bin/yay` | `releng/airootfs/root/customize_airootfs.sh:73` | Low |

### Phase 3 — CI Improvements (Medium value, low risk)

| # | Task | File(s) | Risk |
|---|------|---------|------|
| 9 | Add build step artifact caching (pacman cache, makepkg cache) | `.github/workflows/build-velocity-iso.yml` | Low |
| 10 | Fix compression to zstd in profiledef.sh | `releng/profiledef.sh:16,19` | Low |
| 11 | Split combined docker run into separate steps | `.github/workflows/build-velocity-iso.yml` | Low |
| 12 | Strengthen ISO verification (sha256sum, isoinfo) | `.github/workflows/build-velocity-iso.yml` | Low |
| 13 | Fix `repo-add` signing (drop `-s` if no GPG in CI) | `installdeps-gh-runner.sh:165` | Medium |

### Phase 4 — Repository Hygiene (Low risk)

| # | Task | File(s) | Risk |
|---|------|---------|------|
| 14 | Add `.gitignore` for `out/` and `work/` | `.gitignore` (new) | Low |
| 15 | Update devcontainer Dockerfile with archiso | `.devcontainer/Dockerfile` | Low |
| 16 | Document Dockerfile purpose or remove | `Dockerfile` | Low |
| 17 | Add comments to packages.x86_64 AUR section | `releng/packages.x86_64` | Low |

---

## Validation Plan

1. **Dry-run test:** After refactoring `installdeps-gh-runner.sh`, run in a local
   Arch container to verify all AUR packages build and repo-add succeeds.
2. **ISO build test:** Run `mkarchiso` locally (or via CI debug run) to verify
   the ISO builds without the debug function and with fixed checksums.
3. **ISO mount test:** Mount the built ISO and verify package lists, file structure,
   and boot files are present.
4. **CI dry-run:** Use `workflow_dispatch` to test the updated workflow end-to-end.
5. **Hardware analyzer test:** Boot the ISO and verify the hardware analyzer runs,
   detects hardware correctly, and generates appropriate niri config.

## Implementation Summary

All 17 improvements from Phases 1–4 have been implemented. Files modified/created:

### Modified files (9):
- `installdeps-gh-runner.sh` — Added `set -euo pipefail`, refactored 16× repeated build blocks into `build_aur_pkg()` function, replaced `find` with `cp`, dropped `repo-add -s`
- `releng/profiledef.sh` — Removed dead 40-line debug function, set zstd compression (was gzip), removed non-existent file_permissions entries, added velocity script permissions
- `releng/airootfs/root/customize_airootfs.sh` — Fixed 7 relative→absolute chmod paths, removed stray `chmod +x /usr/bin/yay`, added velocity script chmods, enabled systemd service
- `buildiso-gh-runner.sh` — Removed obsolete gzip fallback sed comment and `sed` package
- `.github/workflows/build-velocity-iso.yml` — Split combined Docker run into separate steps, added `actions/cache`, added `isoinfo` + `sha256sum` to ISO verification
- `.github/workflows/Gentoo.yml` — Fixed typo `./local_pack ages/` → `./local_packages/`
- `Dockerfile` — Removed zstd sed hack, added `squashfs-tools`, documented purpose
- `.devcontainer/Dockerfile` — Added `archiso squashfs-tools` for local dev
- `releng/packages.x86_64` — Added `python`, improved AUR section comments

### New files (7):
- `.gitignore` — Build artifact exclusion (`out/`, `work/`, etc.)
- `releng/airootfs/usr/bin/velocity-hardware-analyzer` — Python hardware detection + recommendation engine
- `releng/airootfs/usr/bin/velocity-apply-profile` — Python profile application script
- `releng/airootfs/usr/bin/velocity-hardware-selector` — Python TUI for first-time user interaction
- `releng/airootfs/etc/systemd/system/velocity-hardware-analyze.service` — Boot-time systemd service
- `releng/airootfs/etc/velocity/hardware-model.json` — Tunable model config (scoring weights, tier configs)
- `releng/airootfs/etc/skel/.config/autostart/velocity-hardware-selector.desktop` — Autostart entry for first boot
