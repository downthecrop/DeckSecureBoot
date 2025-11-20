#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

ISO_RELATIVE_PATH="/usr/local/share/deck-sb"
ISO_VOLUME_LABEL="${DECK_SB_ISO_LABEL:-DECK_SB}"
ISO_INSTALL_DIR="${DECK_SB_INSTALL_DIR:-arch}"
TEMP_ISO_MOUNT=""
REQUIRED_MB=400
STEAMOS_ROOT_BASE="${STEAMOS_ROOT_BASE:-/run/deck-os}"
declare -a TEMP_MOUNTS=()
ISO_ROOTS=()

cleanup_temp_iso_mount() {
  if [ -n "$TEMP_ISO_MOUNT" ]; then
    umount "$TEMP_ISO_MOUNT" 2>/dev/null || true
    rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
    TEMP_ISO_MOUNT=""
  fi
}

cleanup_temp_roots() {
  cleanup_mounts TEMP_MOUNTS
}

iso_dialog() {
  deck_message_box "$@"
}

collect_iso_roots() {
  local roots=()
  local candidate
  local override="${DECK_SB_ISO_ROOT:-}"
  for candidate in /run/archiso/bootmnt /run/initramfs/archiso/bootmnt; do
    if [ -d "$candidate" ]; then
      roots+=("$candidate")
    fi
  done
  if [ -n "$override" ] && [ -d "$override" ]; then
    roots+=("$override")
  fi
  if [ "${#roots[@]}" -eq 0 ]; then
    local mounted
    mounted=$(mount_live_iso_device 2>/dev/null || true)
    if [ -n "$mounted" ]; then
      roots+=("$mounted")
    fi
  fi
  if [ "${#roots[@]}" -eq 0 ]; then
    return 1
  fi
  printf '%s\n' "${roots[@]}"
  return 0
}

find_live_usb_device() {
  local dev fstype label
  while read -r dev fstype label; do
    if [ -n "$label" ] && [ "$label" = "$ISO_VOLUME_LABEL" ]; then
      echo "$dev"
      return 0
    fi
  done < <(lsblk -rpno NAME,FSTYPE,LABEL 2>/dev/null || true)
  return 1
}

mount_live_iso_device() {
  if [ -n "$TEMP_ISO_MOUNT" ] && [ -d "$TEMP_ISO_MOUNT" ]; then
    if findmnt -rno SOURCE --target "$TEMP_ISO_MOUNT" >/dev/null 2>&1; then
      echo "$TEMP_ISO_MOUNT"
      return 0
    fi
    rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
    TEMP_ISO_MOUNT=""
  fi
  local dev
  dev=$(find_live_usb_device 2>/dev/null || true)
  if [ -z "$dev" ]; then
    return 1
  fi
  TEMP_ISO_MOUNT=$(mktemp -d /run/deck-sb-iso.XXXXXX)
  if mount -o ro "$dev" "$TEMP_ISO_MOUNT" 2>/dev/null; then
    echo "$TEMP_ISO_MOUNT"
    return 0
  fi
  rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
  TEMP_ISO_MOUNT=""
  return 1
}

find_kernel_source() {
  local path
  local candidates=(
    /boot/vmlinuz-linux
    /run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux
    /run/archiso/bootmnt/arch/boot/vmlinuz-linux
    /run/initramfs/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux
  )
  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  load_iso_roots_once
  for path in "${ISO_ROOTS[@]}"; do
    local iso_candidates=(
      "$path/$ISO_INSTALL_DIR/boot/x86_64/vmlinuz-linux"
      "$path/$ISO_INSTALL_DIR/boot/vmlinuz-linux"
      "$path/$ISO_INSTALL_DIR/vmlinuz-linux"
    )
    local iso_path
    for iso_path in "${iso_candidates[@]}"; do
      if [ -f "$iso_path" ]; then
        echo "$iso_path"
        return 0
      fi
    done
    iso_path=$(find "$path" -maxdepth 5 -type f -name 'vmlinuz-linux' -print -quit 2>/dev/null || true)
    if [ -n "$iso_path" ]; then
      echo "$iso_path"
      return 0
    fi
  done
  return 1
}

find_initrd_source() {
  local path
  local candidates=(
    /boot/initramfs-linux.img
    /run/archiso/bootmnt/arch/boot/x86_64/initramfs-linux.img
    /run/initramfs/archiso/bootmnt/arch/boot/x86_64/initramfs-linux.img
  )
  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  load_iso_roots_once
  for path in "${ISO_ROOTS[@]}"; do
    local iso_candidates=(
      "$path/$ISO_INSTALL_DIR/boot/x86_64/initramfs-linux.img"
      "$path/$ISO_INSTALL_DIR/boot/initramfs-linux.img"
    )
    local iso_path
    for iso_path in "${iso_candidates[@]}"; do
      if [ -f "$iso_path" ]; then
        echo "$iso_path"
        return 0
      fi
    done
    iso_path=$(find "$path" -maxdepth 5 -type f -name 'initramfs-linux.img' -print -quit 2>/dev/null || true)
    if [ -n "$iso_path" ]; then
      echo "$iso_path"
      return 0
    fi
  done
  return 1
}

load_iso_roots_once() {
  if [ "${#ISO_ROOTS[@]}" -ne 0 ]; then
    return
  fi
  while IFS= read -r path; do
    [ -n "$path" ] && ISO_ROOTS+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
}

find_squashfs_source() {
  local candidates=(
    /run/archiso/airootfs.sfs
    /run/archiso/bootmnt/arch/x86_64/airootfs.sfs
    /run/archiso/bootmnt/airootfs.sfs
  )
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  local path
  load_iso_roots_once
  for path in "${ISO_ROOTS[@]}"; do
    local iso_candidates=(
      "$path/$ISO_INSTALL_DIR/x86_64/airootfs.sfs"
      "$path/$ISO_INSTALL_DIR/airootfs.sfs"
      "$path/airootfs.sfs"
    )
    local iso_path
    for iso_path in "${iso_candidates[@]}"; do
      if [ -f "$iso_path" ]; then
        echo "$iso_path"
        return 0
      fi
    done
  done
  return 1
}

copy_iso_payload() {
  local rootmp="$1"
  local dest="$rootmp$ISO_RELATIVE_PATH"
  mkdir -p "$dest"

  local avail
  avail=$(df -m --output=avail "$dest" | tail -n1 | tr -d ' ')
  if [ -n "$avail" ] && [ "$avail" -lt "$REQUIRED_MB" ]; then
    deck_dialog --msgbox "SteamOS partition has only ${avail}MB free; ${REQUIRED_MB}MB required." 10 80
    return 1
  fi

  local kernel_src
  local initrd_src
  local squash_src
  kernel_src=$(find_kernel_source 2>/dev/null || true)
  initrd_src=$(find_initrd_source 2>/dev/null || true)
  squash_src=$(find_squashfs_source 2>/dev/null || true)

  if [ -z "$kernel_src" ] || [ -z "$initrd_src" ] || [ -z "$squash_src" ]; then
    deck_dialog --msgbox "Live ISO files missing. Ensure the Secure Boot USB (${ISO_VOLUME_LABEL}) is connected and readable." 10 80
    return 1
  fi

  local arch_dir="$dest/arch"
  local boot_dir="$arch_dir/boot/x86_64"
  local sfs_dir="$arch_dir/x86_64"
  mkdir -p "$boot_dir" "$sfs_dir"

  local files=(
    "$kernel_src" "$boot_dir/vmlinuz-linux"
    "$initrd_src" "$boot_dir/initramfs-linux.img"
    "$squash_src" "$sfs_dir/airootfs.sfs"
  )

  local fifo="$(mktemp -u)"
  mkfifo "$fifo"
  deck_dialog --gauge "Copying Secure Boot ISO files (~${REQUIRED_MB}MB)..." 8 70 0 <"$fifo" &
  local gauge_pid=$!
  exec 3>"$fifo"
  local i progress=0 step=$(( 100 / (${#files[@]} / 2) ))
  for ((i=0; i<${#files[@]}; i+=2)); do
    printf '%s\n' "$progress" >&3
    install -m 0644 "${files[i]}" "${files[i+1]}" || {
      printf '100\n' >&3
      exec 3>&-
      wait "$gauge_pid" 2>/dev/null || true
      rm -f "$fifo"
      deck_dialog --msgbox "Failed copying ${files[i]} to ${files[i+1]}" 10 80
      return 1
    }
    progress=$((progress + step))
  done
  printf '100\n' >&3
  exec 3>&-
  wait "$gauge_pid" 2>/dev/null || true
  rm -f "$fifo"

  cat <<'README' > "$dest/README.txt"
Deck Secure Boot Tools
======================
These files enable booting the Secure Boot ISO directly from disk.
Remove /usr/local/share/deck-sb to reclaim space once no longer needed.
Files mirror the standard Arch ISO layout under /usr/local/share/deck-sb/arch/.
README

  return 0
}

main() {
  require_bins dialog lsblk mount findmnt install df find
  command -v btrfs >/dev/null 2>&1 || true
  if [ "$(id -u)" -ne 0 ]; then
    iso_dialog "This installer must run as root (sudo)." "" 10 80
    exit 1
  fi

  trap 'cleanup_temp_iso_mount; cleanup_temp_roots' EXIT

  local root_override="${1:-}" realroot
  if [ -n "$root_override" ]; then
    realroot="$root_override"
  else
    realroot=$(find_steamos_root_path "$STEAMOS_ROOT_BASE" "TEMP_MOUNTS" 2>/dev/null || true)
  fi

  if [ -z "$realroot" ]; then
    iso_dialog "Could not detect a SteamOS root partition. Mount it manually and retry." "" 10 80
    exit 1
  fi

  local pretty_root
  pretty_root=$(format_display_path "$realroot")
  iso_dialog "SteamOS root detected at $pretty_root." "" 8 80

  if [ -d "$realroot$ISO_RELATIVE_PATH" ]; then
    if ! deck_dialog --yesno "Existing files found in $ISO_RELATIVE_PATH. Overwrite them?" 10 70; then
      exit 0
    fi
  fi

  if ! prepare_steamos_root_for_write "$realroot"; then
    iso_dialog "Unable to obtain write access to $pretty_root.\nRun this installer as root (sudo) and make sure SteamOS read-only mode is disabled." "" 10 80
    exit 1
  fi

  if copy_iso_payload "$realroot"; then
    iso_dialog "Secure Boot ISO files are ready under $(format_display_path "$realroot$ISO_RELATIVE_PATH")." "" 8 80
  else
    exit 1
  fi
}

main "$@"
