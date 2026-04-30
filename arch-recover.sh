#!/usr/bin/env bash
set -Eeuo pipefail

# Arch boot recovery helper for this specific layout:
#   ROOT  = /dev/mapper/vg_arch-lv_root (Btrfs, subvol=@)
#   BOOT  = /dev/sda2                  (ext4, mounted at /boot)
#   EFI   = /dev/sda1                  (vfat, mounted at /boot/EFI)
#
# What it does:
#   1) activates LVM
#   2) mounts root, /boot and EFI
#   3) chroots into the installed system
#   4) removes stale pacman lock and broken texlive-fontsextra local db entry
#   5) reinstalls only the packages needed to restore boot artifacts
#   6) regenerates grub.cfg
#   7) prints final validation and next steps
#
# Notes:
#   - This intentionally does NOT install generic nvidia/nvidia-utils packages.
#   - It is based on a recovery flow that already worked for this machine.
#   - Requires network connectivity in the Arch live environment before pacman runs.

ROOT_DEV="${ROOT_DEV:-/dev/mapper/vg_arch-lv_root}"
BOOT_DEV="${BOOT_DEV:-/dev/sda2}"
EFI_DEV="${EFI_DEV:-/dev/sda1}"
ROOT_SUBVOL="${ROOT_SUBVOL:-@}"
MNT="${MNT:-/mnt}"

COLOR_INFO="\033[1;34m"
COLOR_OK="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERR="\033[1;31m"
COLOR_OFF="\033[0m"

info() { printf "%b[INFO]%b %s\n" "$COLOR_INFO" "$COLOR_OFF" "$*"; }
ok()   { printf "%b[ OK ]%b %s\n" "$COLOR_OK" "$COLOR_OFF" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$COLOR_WARN" "$COLOR_OFF" "$*"; }
err()  { printf "%b[ERR ]%b %s\n" "$COLOR_ERR" "$COLOR_OFF" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Command not found: $1"
    exit 1
  }
}

cleanup_on_error() {
  err "Recovery aborted."
  err "Mounted filesystems may still be present under ${MNT}."
}
trap cleanup_on_error ERR

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this script as root."
  exit 1
fi

for c in vgchange mount arch-chroot pacman grub-mkconfig findmnt ls grep ping; do
  need_cmd "$c"
done

info "Configuration:"
printf '  ROOT_DEV=%s\n  BOOT_DEV=%s\n  EFI_DEV=%s\n  ROOT_SUBVOL=%s\n  MNT=%s\n' \
  "$ROOT_DEV" "$BOOT_DEV" "$EFI_DEV" "$ROOT_SUBVOL" "$MNT"

info "Activating LVM..."
vgchange -ay
ok "LVM activated."

mkdir -p "${MNT}" "${MNT}/boot" "${MNT}/boot/EFI"

if mountpoint -q "${MNT}"; then
  warn "${MNT} is already mounted; keeping current mount."
else
  info "Mounting root Btrfs subvolume ${ROOT_SUBVOL} on ${MNT}..."
  mount -o "subvol=${ROOT_SUBVOL}" "${ROOT_DEV}" "${MNT}"
  ok "Root mounted."
fi

if mountpoint -q "${MNT}/boot"; then
  warn "${MNT}/boot is already mounted; keeping current mount."
else
  info "Mounting /boot on ${MNT}/boot..."
  mount "${BOOT_DEV}" "${MNT}/boot"
  ok "/boot mounted."
fi

if mountpoint -q "${MNT}/boot/EFI"; then
  warn "${MNT}/boot/EFI is already mounted; keeping current mount."
else
  info "Mounting EFI on ${MNT}/boot/EFI..."
  mount "${EFI_DEV}" "${MNT}/boot/EFI"
  ok "EFI mounted."
fi

info "Current mount state:"
findmnt | grep "${MNT}" || true

info "Checking basic network connectivity from live environment..."
if ping -c 1 -W 3 archlinux.org >/dev/null 2>&1; then
  ok "Network looks OK."
else
  warn "Network test failed. pacman may fail if the live environment is offline."
fi

info "Entering installed system and restoring boot artifacts..."
arch-chroot "${MNT}" /bin/bash <<'CHROOTEOF'
set -Eeuo pipefail

echo "========== mounts =========="
mount | grep -E ' on / | on /boot | on /boot/EFI ' || true

echo "========== cleaning pacman state =========="
rm -rf /var/lib/pacman/local/texlive-fontsextra-2026.1-1
rm -f /var/lib/pacman/db.lck

echo "========== reinstalling boot-related packages =========="
pacman -Sy --noconfirm linux mkinitcpio lvm2 btrfs-progs grub grub-btrfs intel-ucode

echo "========== regenerating grub config =========="
grub-mkconfig -o /boot/grub/grub.cfg

echo "========== final /boot state =========="
ls -lah /boot
ls -lah /boot/vmlinuz-linux
ls -lah /boot/initramfs-linux.img
ls -lah /boot/initramfs-linux-fallback.img
ls -lah /boot/intel-ucode.img 2>/dev/null || true

echo "========== grub.cfg references =========="
grep -E '/vmlinuz-linux|/initramfs-linux|/intel-ucode' /boot/grub/grub.cfg | head -n 20 || true
CHROOTEOF

ok "Recovery commands finished."