#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

NOTHING=" "

BACKTITLE="${DECK_SB_BACKTITLE}"
ISO_RELATIVE_PATH="/usr/local/share/deck-sb"
ISO_VOLUME_LABEL="${DECK_SB_ISO_LABEL:-DECK_SB}"
ISO_INSTALL_DIR="${DECK_SB_INSTALL_DIR:-arch}"
TEMP_ISO_MOUNT=""
REQUIRED_MB=400

require_bins() {
  local missing=()
  for bin in dialog lsblk mount findmnt install df find; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  command -v btrfs >/dev/null 2>&1 || true
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'Missing required utilities: %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

format_display_path() {
  local path="$1"
  [ -n "$path" ] || return 0
  printf '%s\n' "$path" | sed -e 's://*:/:g'
}

error_dialog() { deck_message_box "$1" "" 10 80; }
info_dialog() { deck_message_box "$1" "" 8 80; }
progress_dialog() { deck_dialog --infobox "$1" 6 70; }

show_detected_volumes() {
  local lines
  lines=$(lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || true)
  [ -n "$lines" ] || lines="(none found)"
  deck_message_box "Detected volumes (NAME FSTYPE LABEL MOUNTPOINT)" "$lines" 20 90
}

cleanup_temp_iso_mount() {
  if [ -n "$TEMP_ISO_MOUNT" ]; then
    umount "$TEMP_ISO_MOUNT" 2>/dev/null || true
    rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
    TEMP_ISO_MOUNT=""
  fi
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
  local dev fstype label fallback=""
  while read -r dev fstype label; do
    if [ -n "$label" ] && [ "$label" = "$ISO_VOLUME_LABEL" ]; then
      echo "$dev"
      return 0
    fi
    if [ -z "$fallback" ] && [[ "${fstype,,}" =~ ^(iso9660|udf)$ ]]; then
      fallback="$dev"
    fi
  done < <(lsblk -rpno NAME,FSTYPE,LABEL 2>/dev/null || true)
  if [ -n "$fallback" ]; then
    echo "$fallback"
    return 0
  fi
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
  local iso_roots=()
  while IFS= read -r path; do
    [ -n "$path" ] && iso_roots+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
  for path in "${iso_roots[@]}"; do
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
  local iso_roots=()
  while IFS= read -r path; do
    [ -n "$path" ] && iso_roots+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
  for path in "${iso_roots[@]}"; do
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

ensure_rw_mount() {
  local mp="$1"
  local opts
  opts=$(findmnt -nro OPTIONS --target "$mp" 2>/dev/null || true)
  if [ -z "$opts" ]; then
    return 0
  fi
  if [[ "$opts" == *ro* ]]; then
    mount -o remount,rw "$mp" 2>/dev/null || return 1
  fi
  return 0
}

is_steamos_tree() {
  local dir="$1"
  [ -n "$dir" ] && [ -f "$dir/etc/os-release" ] && grep -qi "SteamOS" "$dir/etc/os-release" 2>/dev/null
}

prepare_steamos_root_for_write() {
  local rootmp="$1"
  if ensure_rw_mount "$rootmp"; then
    return 0
  fi
  local fstype
  fstype=$(findmnt -nr -T "$rootmp" -o FSTYPE 2>/dev/null || true)
  if [ "$fstype" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
    if btrfs property get -ts "$rootmp" ro >/dev/null 2>&1; then
      btrfs property set -ts "$rootmp" ro false >/dev/null 2>&1 || true
      ensure_rw_mount "$rootmp" && return 0
    fi
  fi
  if [ -x "$rootmp/usr/bin/steamos-readonly" ]; then
    chroot "$rootmp" /usr/bin/steamos-readonly disable 2>/dev/null || true
    ensure_rw_mount "$rootmp" && return 0
  fi
  return 1
}

find_steamos_root() {
  local partmp mounted_here
  while read -r dev fstype parttype mnt; do
    [[ -b "$dev" ]] || continue
    local lowerfstype="${fstype,,}"
    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
      continue
    fi
    if [[ "$lowerfstype" =~ ^(ext4|btrfs|xfs|f2fs)$ ]]; then
      partmp="$mnt"
      mounted_here=0
      if [ -z "$partmp" ] || [ "$partmp" = "-" ]; then
        partmp="/run/deck-os/$(basename "$dev")"
        mkdir -p "$partmp"
        if mount "$dev" "$partmp"; then
          mounted_here=1
        else
          rmdir "$partmp"
          continue
        fi
      fi
      if is_steamos_tree "$partmp"; then
        echo "$partmp"
        return 0
      fi
      if [ "$mounted_here" -eq 1 ]; then
        umount "$partmp" 2>/dev/null || true
        rmdir "$partmp" 2>/dev/null || true
      fi
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
  return 1
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
  local iso_roots=()
  while IFS= read -r path; do
    [ -n "$path" ] && iso_roots+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
  for path in "${iso_roots[@]}"; do
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
    error_dialog "SteamOS partition has only ${avail}MB free; ${REQUIRED_MB}MB required."
    return 1
  fi

  local kernel_src
  local initrd_src
  local squash_src
  kernel_src=$(find_kernel_source 2>/dev/null || true)
  initrd_src=$(find_initrd_source 2>/dev/null || true)
  squash_src=$(find_squashfs_source 2>/dev/null || true)

  if [ -z "$kernel_src" ] || [ -z "$initrd_src" ] || [ -z "$squash_src" ]; then
    error_dialog "Live ISO files missing. Ensure the Secure Boot USB (${ISO_VOLUME_LABEL}) is connected and readable."
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
      error_dialog "Failed copying ${files[i]} to ${files[i+1]}"
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
  require_bins
  if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must run as root." >&2
    exit 1
  fi

  show_detected_volumes

  trap 'cleanup_temp_iso_mount; cleanup_mounts TEMP_MOUNTS' EXIT

  local root_override="${1:-}" realroot
  if [ -n "$root_override" ]; then
    realroot="$root_override"
  else
    realroot=$(find_steamos_root_path "$STEAMOS_ROOT_BASE" "TEMP_MOUNTS" 2>/dev/null || true)
  fi

  if [ -z "$realroot" ]; then
    error_dialog "Could not detect a SteamOS root partition. Mount it manually and retry."
    exit 1
  fi

  local pretty_root
  pretty_root=$(format_display_path "$realroot")
  info_dialog "SteamOS root detected at $pretty_root."

  if [ -d "$realroot$ISO_RELATIVE_PATH" ]; then
    if ! deck_dialog --yesno "Existing files found in $ISO_RELATIVE_PATH. Overwrite them?" 10 70; then
      exit 0
    fi
  fi

  if ! prepare_steamos_root_for_write "$realroot"; then
    error_dialog "Unable to remount $pretty_root writable."
    exit 1
  fi

  if copy_iso_payload "$realroot"; then
    info_dialog "Secure Boot ISO files are ready under $(format_display_path "$realroot$ISO_RELATIVE_PATH")."
  else
    exit 1
  fi
}

main "$@"
