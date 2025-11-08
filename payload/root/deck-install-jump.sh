#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091

. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"

JUMP_SOURCE="/root/steamos-jump.signed.efi"
TARGET_FILENAME="jump.efi"
EFI_LABEL='SteamOS (custom jump)'

FIND_TIMEOUT=${FIND_TIMEOUT:-15}
TIMEOUT_BIN=$(command -v timeout || true)

ISO_MOUNT="/run/archiso/bootmnt"
TMP_EFI_MOUNT_BASE="/run/deck-efi"
TMP_LINUX_MOUNT_BASE="/run/deck-root"

LINUX_FSTYPES='ext2|ext3|ext4|btrfs|xfs|f2fs'
LINUX_GPT_GUIDS=(
  0FC63DAF-8483-4772-8E79-3D69D8477DE4
  44479540-F297-41B2-9AF7-D131D5F0458A
  4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
)

ROOTS=(
  /boot
  /boot/efi
  /efi
  /mnt
  /run/media/*/*
)

mkdir -p "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"

require_bins() {
  local missing=()
  for bin in dialog lsblk mount findmnt efibootmgr install find blkid; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing+=("$bin")
    fi
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'Missing required utilities: %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

error_dialog() {
  dialog --backtitle "$BACKTITLE" --msgbox "$1" 10 80
}

info_dialog() {
  dialog --backtitle "$BACKTITLE" --msgbox "$1" 8 80
}

progress_dialog() {
  dialog --backtitle "$BACKTITLE" --infobox "$1" 5 70
}

cleanup() {
  for m in "${TEMP_MOUNTS[@]-}"; do
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
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

find_disk_for_part() {
  local part="$1"
  local disk
  disk=$(lsblk -nrpo PKNAME "$part" 2>/dev/null | head -n1 || true)
  if [ -n "$disk" ]; then
    [[ "$disk" == /dev/* ]] || disk="/dev/$disk"
    printf '%s' "$disk"
    return 0
  fi
  if [[ "$part" =~ ^(/dev/[[:alnum:]]+)(p[0-9]+|[0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# regex-only partition number
derive_partnum() {
  local part="$1"
  if [[ "$part" =~ ^/dev/[[:alnum:]]+p([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$part" =~ ^/dev/[[:alnum:]]*([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

clean_source_path() {
  local src="$1"
  case "$src" in
    *'['*) src="${src%%[*}" ;;
  esac
  echo "$src"
}

add_search_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  if [[ -n "$ISO_MOUNT" && "$dir" == "$ISO_MOUNT"* ]]; then
    return 0
  fi
  if [[ -n "${ADDED_DIRS[$dir]:-}" ]]; then
    return 0
  fi
  SEARCH_DIRS+=("$dir")
  ADDED_DIRS["$dir"]=1
}

collect_initial_dirs() {
  for root in "${ROOTS[@]}"; do
    for path in $root; do
      add_search_dir "$path"
    done
  done
}

run_find_steamcl() {
  local dir="$1"
  [ -d "$dir" ] || return
  local cmd=(find "$dir" -maxdepth 4 -type f -iname 'steamcl*.efi' -print0)
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$FIND_TIMEOUT" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

run_find_grub() {
  local dir="$1"
  [ -d "$dir" ] || return
  # we specifically want .../EFI/steamos/grubx64.efi
  local cmd=(find "$dir" -maxdepth 6 -type f -path '*/EFI/steamos/grubx64.efi' -print0)
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$FIND_TIMEOUT" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

add_base_candidate() {
  local path="$1"
  [ -f "$path" ] || return
  if [[ -n "$ISO_MOUNT" && "$path" == "$ISO_MOUNT"* ]]; then
    return
  fi
  if [[ -n "${SEEN_BASE[$path]:-}" ]]; then
    return
  fi
  local fstype
  fstype=$(findmnt -rno FSTYPE -T "$path" 2>/dev/null || true)
  fstype=${fstype,,}
  if [[ -z "$fstype" || ! "$fstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
    return
  fi
  BASE_CANDIDATES+=("$path")
  SEEN_BASE["$path"]=1
}

add_grub_candidate() {
  local path="$1"
  [ -f "$path" ] || return
  if [[ -n "$ISO_MOUNT" && "$path" == "$ISO_MOUNT"* ]]; then
    return
  fi
  if [[ -n "${SEEN_GRUB[$path]:-}" ]]; then
    return
  fi
  GRUB_CANDIDATES+=("$path")
  SEEN_GRUB["$path"]=1
}

format_display_path() {
  local path="$1"
  local display="$path"
  for prefix in "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"; do
    if [[ -n "$prefix" && "$display" == "$prefix"* ]]; then
      display="${display#"$prefix"}"
      display="${display#/}"
    fi
  done
  echo "$display"
}

scan_devices() {
  collect_initial_dirs
  progress_dialog "Scanning disks for SteamOS loaders..."
  while read -r dev fstype parttype mnt; do
    [[ -b "$dev" ]] || continue
    local lowerfstype="${fstype,,}"
    local upperpart="${parttype^^}"
    local mount_base=""
    local add_boot_dir=0

    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ || "$upperpart" == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]]; then
      mount_base="$TMP_EFI_MOUNT_BASE"
    elif [[ "$lowerfstype" =~ ^($LINUX_FSTYPES)$ ]]; then
      mount_base="$TMP_LINUX_MOUNT_BASE"
      add_boot_dir=1
    else
      for guid in "${LINUX_GPT_GUIDS[@]}"; do
        if [[ "$upperpart" == "$guid" ]]; then
          mount_base="$TMP_LINUX_MOUNT_BASE"
          add_boot_dir=1
          break
        fi
      done
    fi

    [ -n "$mount_base" ] || continue

    local target_mount="$mnt"
    if [ -z "$target_mount" ] || [ "$target_mount" = "-" ]; then
      target_mount="$mount_base/$(basename "$dev")"
      mkdir -p "$target_mount"
      if mount -o ro "$dev" "$target_mount"; then
        TEMP_MOUNTS+=("$target_mount")
      else
        rmdir "$target_mount"
        continue
      fi
    fi

    if [ "$mount_base" = "$TMP_EFI_MOUNT_BASE" ]; then
      add_search_dir "$target_mount/EFI"
    elif [ "$add_boot_dir" -eq 1 ]; then
      add_search_dir "$target_mount/boot"
      add_search_dir "$target_mount/boot/EFI"
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
}

collect_base_candidates() {
  BASE_CANDIDATES=()
  GRUB_CANDIDATES=()
  for dir in "${SEARCH_DIRS[@]}"; do
    # steamcl
    while IFS= read -r -d '' f; do
      add_base_candidate "$f"
    done < <(run_find_steamcl "$dir" || true)
    # grubx64.efi
    while IFS= read -r -d '' g; do
      add_grub_candidate "$g"
    done < <(run_find_grub "$dir" || true)
  done
}

select_base_candidate() {
  local count=${#BASE_CANDIDATES[@]}
  if [ "$count" -eq 0 ]; then
    error_dialog "Could not find any SteamOS steamcl EFI files. Mount your SteamOS installation and try again."
    exit 1
  fi
  if [ "$count" -eq 1 ]; then
    SELECTED_BASE="${BASE_CANDIDATES[0]}"
    return
  fi

  local menu=()
  local idx=1
  for cand in "${BASE_CANDIDATES[@]}"; do
    menu+=("$idx" "SteamOS base :: $(format_display_path "$cand")")
    idx=$((idx + 1))
  done

  local choice
  choice=$(dialog --backtitle "$BACKTITLE" --stdout --cancel-label "Back" \
    --menu "Select SteamOS base loader" 0 0 0 "${menu[@]}") || exit 0

  SELECTED_BASE="${BASE_CANDIDATES[$((choice - 1))]}"
}

select_grub_for_base() {
  local steamcl_mount="$1"
  local chosen=""

  # if we have none, we'll just fall back later
  if [ "${#GRUB_CANDIDATES[@]}" -eq 0 ]; then
    SELECTED_GRUB=""
    return
  fi

  # try to find one on the same mount as the steamcl
  for g in "${GRUB_CANDIDATES[@]}"; do
    local gm
    gm=$(findmnt -rno TARGET -T "$g" 2>/dev/null || true)
    if [ -n "$gm" ] && [ -n "$steamcl_mount" ] && [ "$gm" = "$steamcl_mount" ]; then
      chosen="$g"
      break
    fi
  done

  # else just pick the first
  if [ -z "$chosen" ]; then
    chosen="${GRUB_CANDIDATES[0]}"
  fi

  SELECTED_GRUB="$chosen"
}

relative_loader_path() {
  local mount_point="$1"
  local dir="$2"
  local rel=""
  if [ "$dir" = "$mount_point" ]; then
    rel="$TARGET_FILENAME"
  else
    rel="${dir#$mount_point/}/$TARGET_FILENAME"
  fi
  rel="${rel#/}"
  echo "$rel"
}

write_cfg_beside() {
  local steamcl_dir="$1"  # .../EFI/steamos
  local grub_dev="$2"     # backing device of the grub ESP
  local cfg_path="$steamcl_dir/deck-sb.cfg"

  progress_dialog "Writing SteamOS boot config..."

  mkdir -p "$steamcl_dir" || {
    error_dialog "Failed to create $steamcl_dir"
    exit 1
  }

  # find a root on the same disk as grub_dev
  local disk root_uuid=""
  disk=$(lsblk -nrpo PKNAME "$grub_dev" 2>/dev/null | head -n1)
  [[ "$disk" != /dev/* ]] && disk="/dev/$disk"

  while read -r name fstype pkname; do
    [[ "$pkname" != "$disk" ]] && continue
    [[ "$name" == "$grub_dev" ]] && continue
    fstype=${fstype,,}
    if [[ "$fstype" == "btrfs" || "$fstype" == "ext4" ]]; then
      root_uuid=$(blkid -s UUID -o value "$name" 2>/dev/null || true)
      [ -n "$root_uuid" ] && break
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PKNAME)

  {
    echo "# auto-generated by Deck SB ISO"
    echo "menuentry 'SteamOS (shimless)' {"
    echo "    insmod part_gpt"
    echo "    insmod btrfs"
    echo "    insmod gzio"
    if [ -n "$root_uuid" ]; then
      echo "    search --no-floppy --fs-uuid --set=root $root_uuid"
      echo "    linux /boot/vmlinuz-linux-neptune-611 \\"
      echo "        console=tty1 \\"
      echo "        rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 \\"
      echo "        rd.systemd.gpt_auto=0 \\"
      echo "        rd.steamos.efi=$grub_dev \\"
      echo "        loglevel=3 \\"
      echo "        plymouth.ignore-serial-consoles"
      echo "    initrd /boot/amd-ucode.img /boot/initramfs-linux-neptune-611.img"
    else
      echo "    # could not auto-detect root, please edit"
      echo "    linux /boot/vmlinuz-linux-neptune-611 rd.steamos.efi=$grub_dev"
      echo "    initrd /boot/amd-ucode.img /boot/initramfs-linux-neptune-611.img"
    fi
    echo "}"
    if [ -f "$steamcl_dir/grubx64.efi" ]; then
      echo "menuentry 'SteamOS (official GRUB)' {"
      echo "    chainloader /EFI/steamos/grubx64.efi"
      echo "}"
    fi
  } > "$cfg_path" || {
    error_dialog "Failed to write $cfg_path"
    exit 1
  }

  chmod 0644 "$cfg_path" 2>/dev/null || true
}

confirm_overwrite() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  dialog --backtitle "$BACKTITLE" --yesno "${TARGET_FILENAME} already exists at $(format_display_path "$path").\nOverwrite it?" 10 70
}

install_jump_loader() {
  local steamcl_path="$1"
  local grub_path="$2"

  local steamcl_mount steamcl_source
  local grub_source=""
  local target_dir target_path
  local partnum disk rel_path windows_path output

  steamcl_mount=$(findmnt -rno TARGET -T "$steamcl_path" 2>/dev/null || true)
  steamcl_source=$(findmnt -rno SOURCE -T "$steamcl_path" 2>/dev/null || true)
  steamcl_source=$(clean_source_path "$steamcl_source")

  if [ -z "$steamcl_mount" ] || [ -z "$steamcl_source" ]; then
    error_dialog "Unable to determine mountpoint for $steamcl_path."
    exit 1
  fi

  if [ ! -b "$steamcl_source" ]; then
    error_dialog "Backing device $steamcl_source not found."
    exit 1
  fi

  # determine grub backing device (for rd.steamos.efi)
  if [ -n "$grub_path" ]; then
    grub_source=$(findmnt -rno SOURCE -T "$grub_path" 2>/dev/null || true)
    grub_source=$(clean_source_path "$grub_source")
  fi
  # fallback: use the same as steamcl
  if [ -z "$grub_source" ]; then
    grub_source="$steamcl_source"
  fi

  if ! ensure_rw_mount "$steamcl_mount"; then
    error_dialog "Unable to remount $steamcl_mount writable. Remount it manually and retry."
    exit 1
  fi

  target_dir=$(dirname "$steamcl_path")
  target_path="$target_dir/$TARGET_FILENAME"

  if ! confirm_overwrite "$target_path"; then
    info_dialog "Installation cancelled."
    exit 0
  fi

  install -m 0644 "$JUMP_SOURCE" "$target_path"
  info_dialog "Copied jump loader to $(format_display_path "$target_path")."

  # write cfg right beside jump.efi, but use the grub ESP device for rd.steamos.efi=
  write_cfg_beside "$target_dir" "$grub_source"

  # boot entry must point to the ESP we actually wrote to (steamcl one)
  partnum=$(derive_partnum "$steamcl_source" 2>/dev/null || true)
  disk=$(find_disk_for_part "$steamcl_source" || true)

  if [ -z "$disk" ] || [ -z "$partnum" ]; then
    error_dialog "Unable to derive disk metadata for $steamcl_source."
    exit 1
  fi

  rel_path=$(relative_loader_path "$steamcl_mount" "$target_dir")
  rel_path=${rel_path#/}
  windows_path="\\${rel_path//\//\\}"

  progress_dialog "Adding UEFI boot entry..."
  if ! output=$(efibootmgr -c -d "$disk" -p "$partnum" -l "$windows_path" -L "$EFI_LABEL" 2>&1); then
    error_dialog "efibootmgr failed:\n$output"
    exit 1
  fi

  info_dialog "Boot entry created:\n$output"
}

main() {
  require_bins

  if [ "$(id -u)" -ne 0 ]; then
    error_dialog "This installer must be run as root."
    exit 1
  fi

  if [ ! -f "$JUMP_SOURCE" ]; then
    error_dialog "Jump loader $JUMP_SOURCE is missing from the live environment."
    exit 1
  fi

  scan_devices
  collect_base_candidates
  select_base_candidate

  # we need the steamcl mount to prefer a matching grub
  steamcl_mount_for_pick=$(findmnt -rno TARGET -T "$SELECTED_BASE" 2>/dev/null || true)
  select_grub_for_base "$steamcl_mount_for_pick"

  install_jump_loader "$SELECTED_BASE" "$SELECTED_GRUB"

  info_dialog "SteamOS custom jump loader installed successfully."
}

declare -a TEMP_MOUNTS=()
declare -a SEARCH_DIRS=()
declare -a BASE_CANDIDATES=()
declare -a GRUB_CANDIDATES=()
declare -A ADDED_DIRS=()
declare -A SEEN_BASE=()
declare -A SEEN_GRUB=()
SELECTED_BASE=""
SELECTED_GRUB=""

trap cleanup EXIT
main
