# Getting tools to build the iso
pacman -Syu --noconfirm archiso squashfs-tools

# Build the ISO (compression is zstd by default in releng/profiledef.sh)
cd /workspace
mkarchiso -v /workspace/releng