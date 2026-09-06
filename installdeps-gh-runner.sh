#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="/workspace/releng/airootfs/packages"

# Download AUR helper and apps
pacman -Syu --noconfirm base-devel git go gtk3 libxt mime-types dbus-glib nss ttf-liberation systemd ffmpeg qt6-declarative qt6-base jemalloc qt6-svg libpipewire qt6-shadertools wayland-protocols cli11 ninja cmake polkit

cd /tmp
git clone https://aur.archlinux.org/zen-browser-bin.git
git clone https://aur.archlinux.org/yay.git
git clone https://aur.archlinux.org/quickshell-git.git
git clone https://aur.archlinux.org/google-breakpad.git
git clone https://github.com/snowarch/iNiR.git

# Adding a non-root user for makepkg
useradd -m builder

# Build an AUR package from a source directory, copy it to the local repo,
# and optionally install it into the build container for runtime dependencies.
build_aur_pkg() {
    local pkg_path="$1"
    local extra_flags="${2:-}"
    local install_to_system="${3:-false}"

    cd "$pkg_path"
    chown -R builder:builder .
    sudo -u builder makepkg --noconfirm --skippgpcheck $extra_flags
    cp *.pkg.tar.zst "$PKG_DIR/"
    if [ "$install_to_system" = "true" ]; then
        pacman -U --noconfirm *.pkg.tar.zst
    fi
}

# Building yay (AUR helper used by subsequent build steps)
build_aur_pkg /tmp/yay "" true

# Building google-breakpad (runtime dependency for quickshell)
build_aur_pkg /tmp/google-breakpad "" true

# Building zen-browser (--nodeps needed due to circular dependency in AUR PKGBUILD)
build_aur_pkg /tmp/zen-browser-bin "--nodeps"

# Building quickshell (depends on google-breakpad installed above)
build_aur_pkg /tmp/quickshell-git

# Building packages for iNiR
build_aur_pkg /tmp/iNiR/sdata/dist-arch/inir-core
build_aur_pkg /tmp/iNiR/sdata/dist-arch/inir-quickshell
build_aur_pkg /tmp/iNiR/sdata/dist-arch/inir-toolkit
build_aur_pkg /tmp/iNiR/sdata/dist-arch/inir-audio
build_aur_pkg /tmp/iNiR/sdata/dist-arch/inir-screencapture
build_aur_pkg /tmp/iNiR/sdata/dist-arch/inir-fonts

# Building cpptrace (missing dependency)
git clone https://aur.archlinux.org/cpptrace.git
build_aur_pkg /tmp/cpptrace "" true

# Installing AUR font dependencies for iNiR
git clone https://aur.archlinux.org/matugen-bin.git
build_aur_pkg /tmp/matugen-bin

git clone https://aur.archlinux.org/otf-space-grotesk.git
build_aur_pkg /tmp/otf-space-grotesk

git clone https://aur.archlinux.org/ttf-jetbrains-mono-nerd.git
build_aur_pkg /tmp/ttf-jetbrains-mono-nerd

git clone https://aur.archlinux.org/ttf-material-symbols-variable-git.git
build_aur_pkg /tmp/ttf-material-symbols-variable-git

git clone https://aur.archlinux.org/ttf-readex-pro.git
build_aur_pkg /tmp/ttf-readex-pro

git clone https://aur.archlinux.org/ttf-rubik-vf.git
build_aur_pkg /tmp/ttf-rubik-vf

git clone https://aur.archlinux.org/ttf-twemoji.git
build_aur_pkg /tmp/ttf-twemoji

git clone https://aur.archlinux.org/adw-gtk-theme-git.git
build_aur_pkg /tmp/adw-gtk-theme-git

# Installing the latest version of iNiR into the ISO skel
export iidir=/workspace/releng/airootfs/etc/skel/.config/quickshell/ii/
git clone https://github.com/snowarch/inir.git "$iidir"
rm -rf "$iidir/dots/.config/niri"
cp -r "$iidir/dots/.config/"* /workspace/releng/airootfs/etc/skel/.config/

# Setting up custom local repository
cd "$PKG_DIR"
repo-add -v packages.db.tar.gz *.pkg.tar.zst
ln -sf packages.db.tar.gz packages.db
ln -sf packages.files.tar.gz packages.files
ls -la packages.*
