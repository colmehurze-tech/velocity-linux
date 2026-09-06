FROM archlinux:latest

# Install dependencies for building the Velocity ISO
# NOTE: This Dockerfile is for local development use. CI uses archlinux:latest
#       with inline bash commands instead.
# Compression (zstd) is configured directly in releng/profiledef.sh
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm archiso squashfs-tools git sudo && \
    pacman -Scc --noconfirm

WORKDIR /build
