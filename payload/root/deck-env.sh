#!/bin/bash
# Common environment values shared across Deck Secure Boot scripts.
: "${DECK_SB_BACKTITLE:=Steam Deck Secure Boot Manager - D-Pad to navigate, A to select, B to cancel.}"
: "${DECK_SB_KEYDIR:=/usr/share/deck-sb/keys}"
: "${DECK_SB_PENDING_FLAG:=/run/sb_pending_reboot}"
: "${DECK_SB_TARGET_FILENAME:=jump.efi}"
: "${DECK_SB_OLD_EFI_LABEL:=SteamOS (custom jump)}"
: "${DECK_SB_NEW_EFI_LABEL:=Deck SB (Custom Jump)}"
: "${DECK_SB_STATE_DIR:=/run/deck-sb}"
: "${DECK_SB_JUMP_STATE_FILE:=$DECK_SB_STATE_DIR/jump.state}"
: "${STEAMOS_ROOT_BASE:=/run/deck-os}"
: "${STEAMOS_BOOT_BASE:=/run/deck-boot}"

export DECK_SB_BACKTITLE
export DECK_SB_KEYDIR
export DECK_SB_PENDING_FLAG
export DECK_SB_TARGET_FILENAME
export DECK_SB_OLD_EFI_LABEL
export DECK_SB_NEW_EFI_LABEL
export DECK_SB_STATE_DIR
export DECK_SB_JUMP_STATE_FILE
export STEAMOS_ROOT_BASE
export STEAMOS_BOOT_BASE

require_bins() {
  # Verify required binaries exist; exit with a helpful list if any are missing.
  local missing=()
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'Missing required utilities: %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

sanitize_printable() {
  LC_ALL=C tr -cd '\11\12\15\40-\176'
}

secure_boot_enabled() {
  command -v sbctl >/dev/null 2>&1 || return 1
  local sb_line
  sb_line=$(sbctl status 2>/dev/null | grep -i 'Secure Boot' || true)
  if echo "$sb_line" | grep -qi 'enabled'; then
    return 0
  fi
  return 1
}

format_display_path() {
  local path="$1"
  shift || true
  local display="$path"
  local prefix
  for prefix in "$@"; do
    if [[ -n "$prefix" && "$display" == "$prefix"* ]]; then
      display="${display#"$prefix"}"
      display="${display#/}"
    fi
  done
  printf '%s\n' "$display" | sed -e 's://*:/:g'
}

deck_dialog() {
  local backtitle="${BACKTITLE:-$DECK_SB_BACKTITLE}"
  dialog --backtitle "$backtitle" "$@"
}

deck_message_box() {
  # Message box with optional heading/body separation and sizing.
  local heading="$1" body="$2" height="${3:-15}" width="${4:-90}"
  [ -n "$body" ] || body="(no output)"
  deck_dialog --msgbox "$(printf '%s\n\n%s' "$heading" "$body")" "$height" "$width"
}

deck_info_box() {
  local body="$1" height="${2:-6}" width="${3:-70}"
  deck_dialog --infobox "$body" "$height" "$width"
}

detect_fstype_for_path() {
  local path="$1"
  findmnt -rno FSTYPE -T "$path" 2>/dev/null | tr 'A-Z' 'a-z'
}

is_fat_fstype() {
  local fstype="$1"
  [[ "${fstype,,}" =~ ^(vfat|fat|fat16|fat32)$ ]]
}

run_find_timeout() {
  # find wrapper with optional timeout support (uses FIND_TIMEOUT/TIMEOUT_BIN if set)
  local dir="$1" maxdepth="$2"
  shift 2
  [ -d "$dir" ] || return
  local cmd=(find "$dir" -maxdepth "$maxdepth" "$@" -print0)
  local tbin="${TIMEOUT_BIN:-}"
  [ -n "$tbin" ] || tbin=$(command -v timeout || true)
  if [ -n "$tbin" ]; then
    "$tbin" "${FIND_TIMEOUT:-15}" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

add_unique_file() {
  # Append a file path to an array if it exists, is unique, and not under an ISO mount.
  local list_ref="$1" seen_ref="$2" iso_mount="$3" path="$4"
  declare -n _list="$list_ref" _seen="$seen_ref"
  [ -f "$path" ] || return 0
  if [[ -n "$iso_mount" && "$path" == "$iso_mount"* ]]; then
    return 0
  fi
  if [[ -n "${_seen[$path]:-}" ]]; then
    return 0
  fi
  _list+=("$path")
  _seen["$path"]=1
}

add_fat_candidate() {
  # Add a file only if it sits on a FAT filesystem (e.g., ESP).
  local list_ref="$1" seen_ref="$2" iso_mount="$3" path="$4"
  local fstype
  fstype=$(detect_fstype_for_path "$path" 2>/dev/null || true)
  is_fat_fstype "$fstype" && add_unique_file "$list_ref" "$seen_ref" "$iso_mount" "$path"
}

cleanup_mounts() {
  # Given a nameref to an array of mounts, try to unmount and remove them.
  local mounts_ref="$1"
  declare -n _mounts="$mounts_ref"
  local m
  for m in "${_mounts[@]-}"; do
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
}

add_search_dir() {
  local list_ref="$1" seen_ref="$2" dir="$3" iso_mount="${4:-}"
  declare -n _list="$list_ref" _seen="$seen_ref"
  [ -d "$dir" ] || return 0
  if [[ -n "$iso_mount" && "$dir" == "$iso_mount"* ]]; then
    return 0
  fi
  if [[ -n "${_seen[$dir]:-}" ]]; then
    return 0
  fi
  _list+=("$dir")
  _seen["$dir"]=1
}

seed_default_search_dirs() {
  local list_ref="$1" seen_ref="$2" iso_mount="${3:-}"
  local roots=(
    /boot
    /boot/efi
    /efi
    /mnt
    /run/media/*/*
  )
  local root path
  for root in "${roots[@]}"; do
    for path in $root; do
      add_search_dir "$list_ref" "$seen_ref" "$path" "$iso_mount"
    done
  done
}

collect_device_search_dirs() {
  local list_ref="$1" seen_ref="$2" temps_ref="$3" iso_mount="$4"
  local efi_base="$5" linux_base="$6" progress_hook="${7:-}"
  declare -n _list="$list_ref" _seen="$seen_ref" _temps="$temps_ref"

  local linux_fstypes="${LINUX_FSTYPES:-ext2|ext3|ext4|btrfs|xfs|f2fs}"
  local parttype guid lowerfstype mount_base add_boot_dir target_mount
  local -a guid_list=()
  if [ -n "${LINUX_GPT_GUIDS[*]:-}" ]; then
    guid_list=("${LINUX_GPT_GUIDS[@]}")
  fi

  while read -r dev fstype parttype target_mount; do
    [[ -b "$dev" ]] || continue
    lowerfstype="${fstype,,}"
    parttype="${parttype^^}"
    mount_base=""
    add_boot_dir=0

    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ || "$parttype" == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]]; then
      mount_base="$efi_base"
    elif [[ "$lowerfstype" =~ ^($linux_fstypes)$ ]]; then
      mount_base="$linux_base"
      add_boot_dir=1
    else
      for guid in "${guid_list[@]}"; do
        if [[ "$parttype" == "$guid" ]]; then
          mount_base="$linux_base"
          add_boot_dir=1
          break
        fi
      done
    fi

    [ -n "$mount_base" ] || continue

    if [ -z "$target_mount" ] || [ "$target_mount" = "-" ]; then
      target_mount="$mount_base/$(basename "$dev")"
      mkdir -p "$target_mount"
      if mount -o ro "$dev" "$target_mount"; then
        _temps+=("$target_mount")
      else
        rmdir "$target_mount"
        continue
      fi
    fi

    if [ "$mount_base" = "$efi_base" ]; then
      add_search_dir "$list_ref" "$seen_ref" "$target_mount/EFI" "$iso_mount"
      if [ -n "$progress_hook" ] && [ "$(type -t "$progress_hook" 2>/dev/null)" = "function" ]; then
        "$progress_hook" "Mounted EFI $(basename "$dev")"
      fi
    elif [ "$add_boot_dir" -eq 1 ]; then
      add_search_dir "$list_ref" "$seen_ref" "$target_mount/boot" "$iso_mount"
      add_search_dir "$list_ref" "$seen_ref" "$target_mount/boot/EFI" "$iso_mount"
      if [ -n "$progress_hook" ] && [ "$(type -t "$progress_hook" 2>/dev/null)" = "function" ]; then
        "$progress_hook" "Mounted Linux $(basename "$dev")"
      fi
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
}

locate_steamos_root_within() {
  local base="$1" fstype="$2" candidate

  if is_steamos_tree "$base"; then
    printf '%s\n' "$base"
    return 0
  fi

  local guesses=(
    '@rootfs'
    '@rootfs.ro'
    'rootfs'
    'rootfs.ro'
    'steamroot'
    'steamrootfs'
  )

  local rel
  for rel in "${guesses[@]}"; do
    candidate="$base/$rel"
    if is_steamos_tree "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ "$fstype" = "btrfs" ] && command -v find >/dev/null 2>&1; then
    local match etc_dir root_dir
    match=$(find "$base" -maxdepth 5 -path '*/etc/os-release' -print -quit 2>/dev/null || true)
    if [ -n "$match" ] && grep -qi "SteamOS" "$match" 2>/dev/null; then
      etc_dir=$(dirname "$match")
      root_dir=$(dirname "$etc_dir")
      printf '%s\n' "$root_dir"
      return 0
    fi
  fi

  return 1
}

find_grub_cfg_for_paths() {
  local attempt path dir candidate
  for attempt in "$1" "$2"; do
    path="$attempt"
    [ -n "$path" ] || continue
    dir=$(dirname "$path" 2>/dev/null || true)
    [ -n "$dir" ] || continue
    candidate="$dir/grub.cfg"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$(find "$dir" -maxdepth 2 -path '*/steamos/grub.cfg' -print -quit 2>/dev/null || true)
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_steamos_root_path() {
  local mount_base="${1:-/run/deck-os}" temps_ref="${2:-TEMP_MOUNTS}" locator_fn="${3:-locate_steamos_root_within}"
  declare -n _temps="$temps_ref"

  local linux_fstypes="${LINUX_FSTYPES:-ext2|ext3|ext4|btrfs|xfs|f2fs}"
  local -a guid_list=()
  if [ -n "${LINUX_GPT_GUIDS[*]:-}" ]; then
    guid_list=("${LINUX_GPT_GUIDS[@]}")
  fi

  local partmp mounted_here lowerfstype parttype candidate guid
  while read -r dev fstype parttype partmnt; do
    [[ -b "$dev" ]] || continue
    lowerfstype="${fstype,,}"
    parttype="${parttype^^}"

    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
      continue
    fi

    if [[ ! "$lowerfstype" =~ ^($linux_fstypes)$ ]]; then
      guid=""
      for guid in "${guid_list[@]}"; do
        if [[ "$parttype" == "$guid" ]]; then
          break
        fi
        guid=""
      done
      [ -n "$guid" ] || continue
    fi

    partmp="$partmnt"
    mounted_here=0
    if [ -z "$partmp" ] || [ "$partmp" = "-" ]; then
      partmp="$mount_base/$(basename "$dev")"
      mkdir -p "$partmp"
      if mount "$dev" "$partmp"; then
        _temps+=("$partmp")
        mounted_here=1
      else
        rmdir "$partmp"
        continue
      fi
    fi

    candidate=""
    if [ -n "$locator_fn" ] && [ "$(type -t "$locator_fn" 2>/dev/null)" = "function" ]; then
      candidate="$($locator_fn "$partmp" "$lowerfstype" 2>/dev/null || true)"
    fi
    if [ -z "$candidate" ] && is_steamos_tree "$partmp"; then
      candidate="$partmp"
    fi

    if [ -n "$candidate" ] && is_steamos_tree "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi

    if [ "$mounted_here" -eq 1 ]; then
      umount "$partmp" 2>/dev/null || true
      rmdir "$partmp" 2>/dev/null || true
      local last_index=$(( ${#_temps[@]} - 1 ))
      unset "_temps[$last_index]"
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
  return 1
}

is_steamos_tree() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  [ -f "$dir/etc/os-release" ] || return 1
  grep -qi "SteamOS" "$dir/etc/os-release" 2>/dev/null
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

ensure_rw_for_path() {
  # Best-effort remount of the filesystem containing a given file/dir.
  local target="$1"
  local mp opts
  mp=$(findmnt -rno TARGET -T "$target" 2>/dev/null || true)
  opts=$(findmnt -rno OPTIONS -T "$target" 2>/dev/null || true)
  [ -n "$mp" ] || return 0

  if [[ "$opts" == *ro* ]]; then
    if ensure_rw_mount "$mp"; then
      return 0
    fi
    printf 'Filesystem %s is mounted read-only. Remount it writable and try again.\n' "$mp"
    return 1
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

derive_partnum() {
  # regex-only partition number extractor
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

prepare_steamos_root_for_write() {
  local rootmp="$1"
  local fstype

  if ensure_rw_mount "$rootmp"; then
    return 0
  fi

  fstype=$(findmnt -nr -T "$rootmp" -o FSTYPE 2>/dev/null || true)

  if [ "$fstype" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
    if btrfs property get -ts "$rootmp" ro >/dev/null 2>&1; then
      btrfs property set -ts "$rootmp" ro false >/dev/null 2>&1 || true
      if ensure_rw_mount "$rootmp"; then
        return 0
      fi
    fi
  fi

  if [ -x "$rootmp/usr/bin/steamos-readonly" ]; then
    chroot "$rootmp" /usr/bin/steamos-readonly disable 2>/dev/null || true
    if ensure_rw_mount "$rootmp"; then
      return 0
    fi
  fi

  return 1
}
