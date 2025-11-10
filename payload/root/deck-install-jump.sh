#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091

. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"

TARGET_FILENAME="jump.efi"
EFI_LABEL='SteamOS (custom jump)'
DECK_SB_FILES_DIR="/root/deck-sb-files"
JUMP_SOURCE="$DECK_SB_FILES_DIR/steamos-jump.signed.efi"
WATCHDOG_SCRIPT_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb-bootfix.sh"
WATCHDOG_SERVICE_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb-bootfix.service"
CLOVER_ENTRY_TEMPLATE="$DECK_SB_FILES_DIR/clover-jump-entry.plist"
DECK_SB_CFG_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb.cfg.tmpl"

FIND_TIMEOUT=${FIND_TIMEOUT:-15}
TIMEOUT_BIN=$(command -v timeout || true)

ISO_MOUNT="/run/archiso/bootmnt"
TMP_EFI_MOUNT_BASE="/run/deck-efi"
TMP_LINUX_MOUNT_BASE="/run/deck-root"
STEAMOS_ROOT_BASE="/run/deck-os"

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

mkdir -p "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE" "$STEAMOS_ROOT_BASE"

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
    while IFS= read -r -d '' f; do
      add_base_candidate "$f"
    done < <(run_find_steamcl "$dir" || true)
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

  if [ "${#GRUB_CANDIDATES[@]}" -eq 0 ]; then
    SELECTED_GRUB=""
    return
  fi

  for g in "${GRUB_CANDIDATES[@]}"; do
    local gm
    gm=$(findmnt -rno TARGET -T "$g" 2>/dev/null || true)
    if [ -n "$gm" ] && [ -n "$steamcl_mount" ] && [ "$gm" = "$steamcl_mount" ]; then
      chosen="$g"
      break
    fi
  done

  if [ -z "$chosen" ]; then
    chosen="${GRUB_CANDIDATES[0]}"
  fi

  SELECTED_GRUB="$chosen"
}

is_steamos_tree() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  [ -f "$dir/etc/os-release" ] || return 1
  if grep -qi "SteamOS" "$dir/etc/os-release" 2>/dev/null; then
    return 0
  fi
  return 1
}

locate_steamos_root_within() {
  local base="$1"
  local fstype="$2"
  local candidate

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

prepare_steamos_root_for_write() {
  local rootmp="$1"
  local fstype
  STEAMOS_PREP_RW_MODE=""

  if ensure_rw_mount "$rootmp"; then
    STEAMOS_PREP_RW_MODE="already-rw"
    return 0
  fi

  fstype=$(findmnt -nr -T "$rootmp" -o FSTYPE 2>/dev/null || true)

  if [ "$fstype" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
    if btrfs property get -ts "$rootmp" ro >/dev/null 2>&1; then
      btrfs property set -ts "$rootmp" ro false >/dev/null 2>&1 || true
      if ensure_rw_mount "$rootmp"; then
        STEAMOS_PREP_RW_MODE="btrfs-property"
        return 0
      fi
    fi
  fi

  if [ -x "$rootmp/usr/bin/steamos-readonly" ]; then
    chroot "$rootmp" /usr/bin/steamos-readonly disable 2>/dev/null || true
    if ensure_rw_mount "$rootmp"; then
      STEAMOS_PREP_RW_MODE="steamos-readonly"
      return 0
    fi
  fi

  return 1
}

write_cfg_to_custom_dir() {
  local custom_dir="$1"
  local grub_dev="$2"
  local cfg_path="$custom_dir/deck-sb.cfg"
  local kernel_block

  progress_dialog "Writing SteamOS boot config..."

  mkdir -p "$custom_dir" || {
    error_dialog "Failed to create $custom_dir"
    exit 1
  }

  if [ ! -f "$DECK_SB_CFG_TEMPLATE" ]; then
    error_dialog "Missing deck-sb.cfg template at $DECK_SB_CFG_TEMPLATE"
    exit 1
  fi

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

  if [ -n "$root_uuid" ]; then
    kernel_block=$(cat <<EOF
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-linux-neptune-611 \
        console=tty1 \
        rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 \
        rd.systemd.gpt_auto=0 \
        rd.steamos.efi=$grub_dev \
        loglevel=3 \
        plymouth.ignore-serial-consoles \
        fbcon=rotate:1
    initrd /boot/amd-ucode.img /boot/initramfs-linux-neptune-611.img
EOF
)
  else
    kernel_block=$(cat <<EOF
    linux /boot/vmlinuz-linux-neptune-611 rd.steamos.efi=$grub_dev \
        fbcon=rotate:1
    initrd /boot/amd-ucode.img /boot/initramfs-linux-neptune-611.img
EOF
)
  fi

  {
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "__DECK_SB_KERNEL_BLOCK__" ]; then
        printf '%s\n' "$kernel_block"
      else
        printf '%s\n' "$line"
      fi
    done < "$DECK_SB_CFG_TEMPLATE"
  } > "$cfg_path" || {
    error_dialog "Failed to write $cfg_path"
    exit 1
  }

  chmod 0644 "$cfg_path" 2>/dev/null || true
}

maybe_update_clover_config() {
  local decksb_dir="$1"
  local efi_root
  local clover_dir=""
  local config_path

  efi_root=$(dirname "$decksb_dir")

  for candidate in \
      "$efi_root/clover" \
      "$efi_root/Clover"; do
    if [ -d "$candidate" ] && [ -f "$candidate/config.plist" ]; then
      clover_dir="$candidate"
      break
    fi
  done

  if [ -z "$clover_dir" ]; then
    return 0
  fi

  config_path="$clover_dir/config.plist"

  if [ ! -f "$CLOVER_ENTRY_TEMPLATE" ]; then
    info_dialog "Clover directory detected at $(format_display_path "$clover_dir"), but the entry template is missing."
    return 0
  fi

  if grep -q "SteamOS Jump Loader" "$config_path" 2>/dev/null; then
    return 0
  fi

  progress_dialog "Adding SteamOS Jump Loader to Clover config..."
  local tmp_file
  tmp_file=$(mktemp) || {
    info_dialog "Failed to create temporary file while editing $(format_display_path "$config_path")."
    return 1
  }

  if awk -v tpl="$CLOVER_ENTRY_TEMPLATE" '
BEGIN {
  inserted = 0
  seen_entries_key = 0
}
{
  print $0

  if (!inserted && seen_entries_key && index($0, "<array>") > 0) {
    while ((getline line < tpl) > 0) {
      print line
    }
    close(tpl)
    inserted = 1
    seen_entries_key = 0
  }

  if (!inserted && index($0, "<key>Entries</key>") > 0) {
    seen_entries_key = 1
  }
}
END {
  exit inserted ? 0 : 1
}
' "$config_path" > "$tmp_file"; then
    if mv "$tmp_file" "$config_path"; then
      local clover_message="Clover config found at $(format_display_path \"$config_path\").\\nA SteamOS Jump Loader entry was added to the top of its boot menu."

      if grep -q '<key>DefaultLoader</key>' "$config_path" 2>/dev/null; then
        tmp_dloader=$(mktemp)
        if awk '
BEGIN { updated = 0 }
{
  line = $0
  if (!updated && line ~ /<key>[\t ]*DefaultLoader[\t ]*<\/key>/) {
    print line
    if (getline nextline) {
      gsub(/<string>.*<\/string>/, "<string>\\EFI\\deck-sb\\jump.efi</string>", nextline)
      print nextline
      updated = 1
    }
  } else {
    print line
  }
}
END { exit updated ? 0 : 1 }
' "$config_path" > "$tmp_dloader"; then
          if mv "$tmp_dloader" "$config_path"; then
            clover_message+="\\nDefault Clover loader changed to \\EFI\\deck-sb\\jump.efi."
          fi
        else
          rm -f "$tmp_dloader" 2>/dev/null || true
        fi
      fi

      clover_message+="\\n\\nReminder: re-sign Clover's EFI binaries with deck-sign-efi.sh so Secure Boot trusts them."
      dialog --backtitle "$BACKTITLE" --msgbox "$clover_message" 12 80
      return 0
    fi
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  info_dialog "Failed to update Clover config at $(format_display_path "$config_path"). Add the SteamOS Jump Loader entry manually."
  return 1
}

confirm_overwrite() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  dialog --backtitle "$BACKTITLE" --yesno "$(basename "$path") already exists at $(format_display_path "$path").\nOverwrite it?" 10 70
}

purge_existing_boot_entries() {
  local label="$1"
  local line id
  while IFS= read -r line; do
    case "$line" in
      Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*"$label"*)
        id=${line%% *}
        id=${id#Boot}
        id=${id%\*}
        efibootmgr -b "$id" -B >/dev/null 2>&1 || true
        ;;
    esac
  done < <(efibootmgr 2>/dev/null || true)
}

# --- new: find actual SteamOS root and install a watchdog service there
find_steamos_root() {
  local partmp candidate mounted_here
  while read -r dev fstype parttype mnt; do
    [[ -b "$dev" ]] || continue
    local lowerfstype="${fstype,,}"
    # skip obvious ESP/fat
    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
      continue
    fi
    # only try linuxy fs
    if [[ "$lowerfstype" =~ ^(ext4|btrfs|xfs|f2fs)$ ]]; then
      partmp="$mnt"
      mounted_here=0
      if [ -z "$partmp" ] || [ "$partmp" = "-" ]; then
        partmp="$STEAMOS_ROOT_BASE/$(basename "$dev")"
        mkdir -p "$partmp"
        if mount "$dev" "$partmp"; then
          TEMP_MOUNTS+=("$partmp")
          mounted_here=1
        else
          rmdir "$partmp"
          continue
        fi
      fi

      candidate=$(locate_steamos_root_within "$partmp" "$lowerfstype" 2>/dev/null || true)
      if [ -n "$candidate" ] && is_steamos_tree "$candidate"; then
        echo "$candidate"
        return 0
      fi

      if [ "$mounted_here" -eq 1 ]; then
        umount "$partmp" 2>/dev/null || true
        rmdir "$partmp" 2>/dev/null || true
        # remove the last temp mount we just added
        local last_index=$(( ${#TEMP_MOUNTS[@]} - 1 ))
        unset "TEMP_MOUNTS[$last_index]"
      fi
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
  return 1
}

install_watchdog_into_root() {
  local rootmp="$1"
  local service_dir="$rootmp/etc/systemd/system"
  local script_path="$service_dir/deck-sb-bootfix.sh"
  local unit_path="$service_dir/deck-sb-bootfix.service"

  local pretty_root
  pretty_root=$(format_display_path "$rootmp")
  progress_dialog "SteamOS root detected at $pretty_root. Checking write access..."

  if ! prepare_steamos_root_for_write "$rootmp"; then
    return 1
  fi

  case "$STEAMOS_PREP_RW_MODE" in
    btrfs-property)
      info_dialog "SteamOS root was read-only. Toggled the Btrfs subvolume property before writing inside $pretty_root."
      ;;
    steamos-readonly)
      info_dialog "SteamOS root was read-only. Chrooted to run steamos-readonly disable so files can be written."
      ;;
    already-rw)
      info_dialog "SteamOS root is already writable; proceeding with watchdog install."
      ;;
  esac

  mkdir -p "$service_dir" 2>/dev/null || return 1

  if [ ! -f "$WATCHDOG_SCRIPT_TEMPLATE" ] || [ ! -f "$WATCHDOG_SERVICE_TEMPLATE" ]; then
    error_dialog "Watchdog templates are missing from the live environment."
    return 1
  fi

  progress_dialog "Writing deck-sb-bootfix watchdog files into $pretty_root..."
  if ! install -m 0755 "$WATCHDOG_SCRIPT_TEMPLATE" "$script_path"; then
    error_dialog "Failed to copy deck-sb-bootfix.sh into $pretty_root."
    return 1
  fi

  if ! install -m 0644 "$WATCHDOG_SERVICE_TEMPLATE" "$unit_path"; then
    error_dialog "Failed to copy deck-sb-bootfix.service into $pretty_root."
    return 1
  fi

  info_dialog "Created deck-sb-bootfix.sh and deck-sb-bootfix.service inside $pretty_root. Enable deck-sb-bootfix.service from SteamOS when you're ready."

  return 0
}

install_jump_loader() {
  local steamcl_path="$1"
  local grub_path="$2"

  local steamcl_mount steamcl_source
  local grub_source=""
  local custom_dir custom_jump
  local partnum disk windows_path output

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

  if [ -n "$grub_path" ]; then
    grub_source=$(findmnt -rno SOURCE -T "$grub_path" 2>/dev/null || true)
    grub_source=$(clean_source_path "$grub_source")
  fi
  if [ -z "$grub_source" ]; then
    grub_source="$steamcl_source"
  fi

  if ! ensure_rw_mount "$steamcl_mount"; then
    error_dialog "Unable to remount $steamcl_mount writable. Remount it manually and retry."
    exit 1
  fi

  custom_dir="$steamcl_mount/EFI/deck-sb"
  mkdir -p "$custom_dir"
  custom_jump="$custom_dir/$TARGET_FILENAME"

  if ! confirm_overwrite "$custom_jump"; then
    info_dialog "Installation cancelled."
    exit 0
  fi

  install -m 0644 "$JUMP_SOURCE" "$custom_jump"
  info_dialog "Copied jump loader to $(format_display_path "$custom_jump")."

  write_cfg_to_custom_dir "$custom_dir" "$grub_source"
  maybe_update_clover_config "$custom_dir"

  partnum=$(derive_partnum "$steamcl_source" 2>/dev/null || true)
  disk=$(find_disk_for_part "$steamcl_source" || true)

  if [ -z "$disk" ] || [ -z "$partnum" ]; then
    error_dialog "Unable to derive disk metadata for $steamcl_source."
    exit 1
  fi

  windows_path="\\EFI\\deck-sb\\$TARGET_FILENAME"

  # remove old entries with the same label before adding a new one
  purge_existing_boot_entries "$EFI_LABEL"

  progress_dialog "Adding UEFI boot entry..."
  if ! output=$(efibootmgr -c -d "$disk" -p "$partnum" -l "$windows_path" -L "$EFI_LABEL" 2>&1); then
    error_dialog "efibootmgr failed:\n$output"
    exit 1
  fi

  info_dialog "Boot entry created:\n$output"

  # --- new: best-effort persistence into real SteamOS root
  local realroot
  realroot=$(find_steamos_root 2>/dev/null || true)
  if [ -n "$realroot" ]; then
    if ! install_watchdog_into_root "$realroot"; then
      info_dialog "EFI drop succeeded, but installing the SteamOS boot-fix service failed.\nYou can run the installer again from inside SteamOS to make it persistent."
    fi
  else
    info_dialog "EFI drop succeeded, but a SteamOS root could not be auto-detected.\nYou can run a small service installer inside SteamOS to keep the entry."
  fi
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
STEAMOS_PREP_RW_MODE=""

trap cleanup EXIT
main
