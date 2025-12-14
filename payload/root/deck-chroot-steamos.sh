#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

STEAMOS_ROOT_BASE="${STEAMOS_ROOT_BASE:-/run/deck-os}"
STEAMOS_BOOT_BASE="${STEAMOS_BOOT_BASE:-/run/deck-boot}"

TEMP_MOUNTS=()
BIND_MOUNTS=()

cleanup() {
  local m
  for m in "${BIND_MOUNTS[@]-}"; do
    umount -R "$m" 2>/dev/null || umount "$m" 2>/dev/null || true
  done
  cleanup_mounts TEMP_MOUNTS
}
trap cleanup EXIT

bind_mount() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  if mountpoint -q "$dest"; then
    return
  fi
  mount --rbind "$src" "$dest"
  mount --make-rslave "$dest" 2>/dev/null || true
  BIND_MOUNTS+=("$dest")
}

bind_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if findmnt -rno TARGET -T "$dest" >/dev/null 2>&1; then
    return
  fi
  if [ ! -e "$dest" ]; then
    cp "$src" "$dest"
  fi
  mount --bind "$src" "$dest"
  BIND_MOUNTS+=("$dest")
}

mkdir -p "$STEAMOS_ROOT_BASE" "$STEAMOS_BOOT_BASE"

echo "Scanning for SteamOS installation..."
STEAMOS_ROOT=$(find_steamos_root_path "$STEAMOS_ROOT_BASE" TEMP_MOUNTS 2>/dev/null || true)
if [ -z "$STEAMOS_ROOT" ]; then
  echo "SteamOS root not found. Mount it under $STEAMOS_ROOT_BASE and rerun."
  exit 1
fi

if [ ! -d "$STEAMOS_ROOT" ]; then
  echo "SteamOS root path $STEAMOS_ROOT is not accessible."
  exit 1
fi

echo "Found SteamOS root at $STEAMOS_ROOT"

bind_mount /dev "$STEAMOS_ROOT/dev"
bind_mount /proc "$STEAMOS_ROOT/proc"
bind_mount /sys "$STEAMOS_ROOT/sys"
bind_mount /run "$STEAMOS_ROOT/run"
[ -f /etc/resolv.conf ] && bind_file /etc/resolv.conf "$STEAMOS_ROOT/etc/resolv.conf"

echo "Entering SteamOS chroot. Type 'exit' to return."
chroot "$STEAMOS_ROOT" /bin/bash -l
