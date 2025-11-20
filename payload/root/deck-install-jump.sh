#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091

. /root/deck-env.sh

TARGET_FILENAME="$DECK_SB_TARGET_FILENAME"
OLD_EFI_LABEL="$DECK_SB_OLD_EFI_LABEL"  # legacy label to clean up
NEW_EFI_LABEL="$DECK_SB_NEW_EFI_LABEL"
DECK_SB_FILES_DIR="/root/deck-sb-files"
JUMP_SOURCE="$DECK_SB_FILES_DIR/steamos-jump.signed.efi"
WATCHDOG_SCRIPT_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb-bootfix.sh"
WATCHDOG_SERVICE_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb-bootfix.service"
CLOVER_ENTRY_TEMPLATE="$DECK_SB_FILES_DIR/clover-jump-entry.plist"
DECK_SB_CFG_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb.cfg.tmpl"
DEFAULT_KERNEL_IMAGE="/boot/vmlinuz-linux-neptune-611"
DEFAULT_INITRD_IMAGES="/boot/amd-ucode.img /boot/initramfs-linux-neptune-611.img"
STEAMOS_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
STEAMOS_INITRD_IMAGES="$DEFAULT_INITRD_IMAGES"
BOOT_LABELS=("$NEW_EFI_LABEL" "$OLD_EFI_LABEL")

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

mkdir -p "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE" "$STEAMOS_ROOT_BASE"

cleanup() {
  cleanup_mounts TEMP_MOUNTS
}
display_path() {
  format_display_path "$1" "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"
}

clean_source_path() {
  local src="$1"
  case "$src" in
    *'['*) src="${src%%[*}" ;;
  esac
  echo "$src"
}

trim_config_value() {
  local val="$1"
  printf '%s\n' "$val" | awk '{sub(/[ \t]*\\$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print}'
}

parse_kernel_initrd_from_cfg() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1

  local kernel_image initrd_images updated=0

  kernel_image=$(awk '
    {
      cmd = tolower($1)
      if (cmd == "linux" || cmd == "linuxefi") {
        print $2
        exit
      }
    }
  ' "$cfg" 2>/dev/null || true)
  kernel_image=$(trim_config_value "$kernel_image")
  if [ -n "$kernel_image" ]; then
    STEAMOS_KERNEL_IMAGE="$kernel_image"
    updated=1
  fi

  initrd_images=$(awk '
    {
      cmd = tolower($1)
      if (cmd == "initrd" || cmd == "initrdefi") {
        $1 = ""
        sub(/^[\t ]+/, "")
        print
        exit
      }
    }
  ' "$cfg" 2>/dev/null || true)
  initrd_images=$(trim_config_value "$initrd_images")
  if [ -n "$initrd_images" ]; then
    STEAMOS_INITRD_IMAGES="$initrd_images"
    updated=1
  fi

  [ "$updated" -eq 1 ] || return 1
  return 0
}

update_kernel_initrd_from_grub() {
  local grub_path="$1"
  local steamcl_path="$2"
  local cfg

  cfg=$(find_grub_cfg_for_paths "$grub_path" "$steamcl_path" 2>/dev/null || true)
  if [ -z "$cfg" ]; then
    STEAMOS_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
    STEAMOS_INITRD_IMAGES="$DEFAULT_INITRD_IMAGES"
    deck_dialog --msgbox "SteamOS grub.cfg was not found near the selected loader (e.g. steamos/grubx64.efi).\nUsing default kernel/initrd paths instead." 12 80
    return 1
  fi

  deck_dialog --infobox "Parsing kernel/initrd settings from $(display_path "$cfg")..." 6 70
  if parse_kernel_initrd_from_cfg "$cfg"; then
    deck_dialog --msgbox "Kernel/initrd paths captured from $(display_path "$cfg")." 8 80
    return 0
  fi

  STEAMOS_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
  STEAMOS_INITRD_IMAGES="$DEFAULT_INITRD_IMAGES"
  deck_dialog --msgbox "Could not parse kernel/initrd data from $(display_path "$cfg").\nUsing default kernel/initrd paths instead." 12 80
  return 1
}

scan_devices() {
  seed_default_search_dirs "SEARCH_DIRS" "ADDED_DIRS" "$ISO_MOUNT"
  deck_dialog --infobox "Scanning disks for SteamOS loaders..." 5 70
  collect_device_search_dirs "SEARCH_DIRS" "ADDED_DIRS" "TEMP_MOUNTS" "$ISO_MOUNT" "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"
}

collect_base_candidates() {
  BASE_CANDIDATES=()
  GRUB_CANDIDATES=()
  for dir in "${SEARCH_DIRS[@]}"; do
    while IFS= read -r -d '' f; do
      add_fat_candidate "BASE_CANDIDATES" "SEEN_BASE" "$ISO_MOUNT" "$f"
    done < <(run_find_timeout "$dir" 4 -type f -iname 'steamcl*.efi' || true)
    while IFS= read -r -d '' g; do
      add_unique_file "GRUB_CANDIDATES" "SEEN_GRUB" "$ISO_MOUNT" "$g"
    done < <(run_find_timeout "$dir" 6 -type f -path '*/EFI/steamos/grubx64.efi' || true)
  done
}

select_base_candidate() {
  local count=${#BASE_CANDIDATES[@]}
  if [ "$count" -eq 0 ]; then
    deck_dialog --msgbox "Could not find any SteamOS steamcl EFI files. Mount your SteamOS installation and try again." 10 80
    exit 1
  fi
  if [ "$count" -eq 1 ]; then
    SELECTED_BASE="${BASE_CANDIDATES[0]}"
    return
  fi

  local menu=()
  local idx=1
  for cand in "${BASE_CANDIDATES[@]}"; do
    menu+=("$idx" "SteamOS base :: $(display_path "$cand")")
    idx=$((idx + 1))
  done

  local choice
  choice=$(deck_dialog --stdout --cancel-label "Back" \
    --menu "Select SteamOS base loader" 0 0 0 "${menu[@]}") || exit 0

  SELECTED_BASE="${BASE_CANDIDATES[$((choice - 1))]}"
}

select_grub_for_base() {
  local steamcl_mount="$1"
  [ "${#GRUB_CANDIDATES[@]}" -eq 0 ] && { SELECTED_GRUB=""; return; }

  local g
  for g in "${GRUB_CANDIDATES[@]}"; do
    if [ -n "$steamcl_mount" ] && [ "$(findmnt -rno TARGET -T "$g" 2>/dev/null || true)" = "$steamcl_mount" ]; then
      SELECTED_GRUB="$g"
      return
    fi
  done

  SELECTED_GRUB="${GRUB_CANDIDATES[0]}"
}

write_cfg_to_custom_dir() {
  local custom_dir="$1"
  local grub_dev="$2"
  local cfg_path="$custom_dir/deck-sb.cfg"
  local kernel_block

  deck_dialog --infobox "Writing SteamOS boot config..." 5 70

  mkdir -p "$custom_dir" || {
    deck_dialog --msgbox "Failed to create $custom_dir" 10 80
    exit 1
  }

  if [ ! -f "$DECK_SB_CFG_TEMPLATE" ]; then
    deck_dialog --msgbox "Missing deck-sb.cfg template at $DECK_SB_CFG_TEMPLATE" 10 80
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
    linux ${STEAMOS_KERNEL_IMAGE} \
        console=tty1 \
        rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 \
        rd.systemd.gpt_auto=0 \
        rd.steamos.efi=$grub_dev \
        loglevel=3 \
        plymouth.ignore-serial-consoles \
        fbcon=rotate:1
    initrd ${STEAMOS_INITRD_IMAGES}
EOF
)
  else
    kernel_block=$(cat <<EOF
    linux ${STEAMOS_KERNEL_IMAGE} rd.steamos.efi=$grub_dev \
        fbcon=rotate:1
    initrd ${STEAMOS_INITRD_IMAGES}
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
    deck_dialog --msgbox "Failed to write $cfg_path" 10 80
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
    deck_dialog --msgbox "Clover directory detected at $(display_path "$clover_dir"), but the entry template is missing." 10 80
    return 0
  fi

  if grep -q "SteamOS Jump Loader" "$config_path" 2>/dev/null; then
    return 0
  fi

  deck_dialog --infobox "Adding SteamOS Jump Loader to Clover config..." 5 70
  local tmp_file
  tmp_file=$(mktemp) || {
    deck_dialog --msgbox "Failed to create temporary file while editing $(display_path "$config_path")." 10 80
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
      local clover_message="Clover config found at $(display_path "$config_path").\\nA SteamOS Jump Loader entry was added to the top of its boot menu."

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
      deck_dialog --infobox "$clover_message" 12 80
      return 0
    fi
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  deck_dialog --msgbox "Failed to update Clover config at $(display_path "$config_path"). Add the SteamOS Jump Loader entry manually." 10 80
  return 1
}

confirm_overwrite() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  deck_dialog --yesno "$(basename "$path") already exists at $(display_path "$path").\nOverwrite it?" 10 70
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
install_watchdog_into_root() {
  local rootmp="$1"
  local service_dir="$rootmp/etc/systemd/system"
  local script_path="$service_dir/deck-sb-bootfix.sh"
  local unit_path="$service_dir/deck-sb-bootfix.service"

  local pretty_root
  pretty_root=$(display_path "$rootmp")
  deck_dialog --infobox "SteamOS root detected at $pretty_root. Checking write access..." 6 70

  if ! prepare_steamos_root_for_write "$rootmp"; then
    deck_dialog --msgbox "Unable to obtain write access to $pretty_root.\nRun this installer as root (sudo) and make sure SteamOS read-only mode is disabled." 10 80
    WATCHDOG_ERROR_SHOWN=1
    return 1
  fi

  mkdir -p "$service_dir" 2>/dev/null || return 1

  if [ ! -f "$WATCHDOG_SCRIPT_TEMPLATE" ] || [ ! -f "$WATCHDOG_SERVICE_TEMPLATE" ]; then
    deck_dialog --msgbox "Watchdog templates are missing from the live environment." 10 80
    WATCHDOG_ERROR_SHOWN=1
    return 1
  fi

  deck_dialog --infobox "Writing deck-sb-bootfix watchdog files into $pretty_root..." 6 70
  if ! install -m 0755 "$WATCHDOG_SCRIPT_TEMPLATE" "$script_path"; then
    deck_dialog --msgbox "Failed to copy deck-sb-bootfix.sh into $pretty_root." 10 80
    WATCHDOG_ERROR_SHOWN=1
    return 1
  fi

  if ! install -m 0644 "$WATCHDOG_SERVICE_TEMPLATE" "$unit_path"; then
    deck_dialog --msgbox "Failed to copy deck-sb-bootfix.service into $pretty_root." 10 80
    WATCHDOG_ERROR_SHOWN=1
    return 1
  fi

  deck_dialog --msgbox "Created deck-sb-bootfix.sh and deck-sb-bootfix.service inside $pretty_root." 8 80

  return 0
}

install_jump_loader() {
  local steamcl_path="$1"
  local grub_path="$2"

  local steamcl_mount steamcl_source
  local grub_source=""
  local custom_dir custom_jump
  local partnum disk output

  steamcl_mount=$(findmnt -rno TARGET -T "$steamcl_path" 2>/dev/null || true)
  steamcl_source=$(findmnt -rno SOURCE -T "$steamcl_path" 2>/dev/null || true)
  steamcl_source=$(clean_source_path "$steamcl_source")

  if [ -z "$steamcl_mount" ] || [ -z "$steamcl_source" ]; then
    deck_dialog --msgbox "Unable to determine mountpoint for $steamcl_path." 10 80
    exit 1
  fi

  if [ ! -b "$steamcl_source" ]; then
    deck_dialog --msgbox "Backing device $steamcl_source not found." 10 80
    exit 1
  fi

  if [ -n "$grub_path" ]; then
    grub_source=$(findmnt -rno SOURCE -T "$grub_path" 2>/dev/null || true)
    grub_source=$(clean_source_path "$grub_source")
  fi
  if [ -z "$grub_source" ]; then
    grub_source="$steamcl_source"
  fi

  update_kernel_initrd_from_grub "$grub_path" "$steamcl_path"

  if ! ensure_rw_mount "$steamcl_mount"; then
    deck_dialog --msgbox "Unable to remount $steamcl_mount writable. Remount it manually and retry." 10 80
    exit 1
  fi

  custom_dir="$steamcl_mount/EFI/deck-sb"
  mkdir -p "$custom_dir"
  custom_jump="$custom_dir/$TARGET_FILENAME"

  if ! confirm_overwrite "$custom_jump"; then
    deck_dialog --infobox "Installation cancelled." 6 60
    return 0
  fi

  install -m 0644 "$JUMP_SOURCE" "$custom_jump"
  deck_dialog --msgbox "Copied jump loader to $(display_path "$custom_jump")." 8 80

  write_cfg_to_custom_dir "$custom_dir" "$grub_source"
  maybe_update_clover_config "$custom_dir"

  partnum=$(derive_partnum "$steamcl_source" 2>/dev/null || true)
  disk=$(find_disk_for_part "$steamcl_source" || true)

  if [ -z "$disk" ] || [ -z "$partnum" ]; then
    deck_dialog --msgbox "Unable to derive disk metadata for $steamcl_source." 10 80
    exit 1
  fi

  local efi_rel_path="\\EFI\\deck-sb\\$TARGET_FILENAME"

  # remove old entries with the same labels before adding a new one
  local label
  for label in "${BOOT_LABELS[@]}"; do
    purge_existing_boot_entries "$label"
  done


  deck_dialog --infobox "Adding UEFI boot entry..." 5 70
  if ! output=$(efibootmgr -c -d "$disk" -p "$partnum" -l "$efi_rel_path" -L "$NEW_EFI_LABEL" 2>&1); then
    deck_dialog --msgbox "efibootmgr failed:\n$output" 10 80
    exit 1
  fi

  deck_dialog --msgbox "Boot entry created:\n$output" 8 80

  # --- best-effort persistence into real SteamOS root
  local realroot
  realroot=$(find_steamos_root_path "$STEAMOS_ROOT_BASE" "TEMP_MOUNTS" 2>/dev/null || true)
  if [ -n "$realroot" ]; then
    if ! install_watchdog_into_root "$realroot"; then
      if [ "${WATCHDOG_ERROR_SHOWN:-0}" -ne 1 ]; then
        deck_dialog --msgbox "EFI drop succeeded, but installing the SteamOS boot-fix service failed.\nYou can run the installer again from inside SteamOS to make it persistent." 12 80
      fi
    fi
  else
    deck_dialog --msgbox "EFI drop succeeded, but a SteamOS root could not be auto-detected.\nYou can run a small service installer inside SteamOS to keep the entry." 12 80
  fi
}

find_installed_jump() {
  local keep_mounts="${1:-0}"
  local attempt max_attempts=3

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    # Use dedicated, temporary lists so detection doesn't disturb global mounts.
    local -a _mounts=() _dirs=()
    local -A _added=()

    seed_default_search_dirs "_dirs" "_added" "$ISO_MOUNT"
    collect_device_search_dirs "_dirs" "_added" "_mounts" "$ISO_MOUNT" "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"

    local dir found
    for dir in "${_dirs[@]}"; do
      while IFS= read -r -d '' found; do
        printf '%s\n' "$found"
        if [ "$keep_mounts" -eq 1 ]; then
          TEMP_MOUNTS+=("${_mounts[@]}")
        else
          cleanup_mounts _mounts
        fi
        return 0
      done < <(run_find_timeout "$dir" 6 -type f -ipath "*/efi/deck-sb/$TARGET_FILENAME" || true)
    done

    cleanup_mounts _mounts
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep 1
    fi
  done

  return 1
}

remove_jump_loader() {
  local jump_path="${1:-}"
  [ -n "$jump_path" ] || jump_path=$(find_installed_jump 1 2>/dev/null || true)

  if [ -z "$jump_path" ]; then
    deck_dialog --msgbox "No Deck SB jump loader was found to remove." 8 70
    return 0
  fi

  local mp; mp=$(findmnt -rno TARGET -T "$jump_path" 2>/dev/null || true)
  if [ -n "$mp" ] && ! ensure_rw_mount "$mp"; then
    deck_dialog --msgbox "Cannot obtain write access to $(display_path "$mp")." 9 70
    return 1
  fi

  rm -f "$jump_path" 2>/dev/null || true
  rmdir "$(dirname "$jump_path")" 2>/dev/null || true

  local label
  for label in "${BOOT_LABELS[@]}"; do
    purge_existing_boot_entries "$label"
  done

  deck_dialog --msgbox "Removed Deck SB jump loader and cleared matching UEFI boot entries." 9 80
  return 0
}

main() {
  require_bins dialog lsblk mount findmnt efibootmgr install find blkid awk

  if [ "$(id -u)" -ne 0 ]; then
    deck_dialog --msgbox "This installer must be run as root." 10 80
    exit 1
  fi

  if [ ! -f "$JUMP_SOURCE" ]; then
    deck_dialog --msgbox "Jump loader $JUMP_SOURCE is missing from the live environment." 10 80
    exit 1
  fi

  scan_devices
  collect_base_candidates
  select_base_candidate

  steamcl_mount_for_pick=$(findmnt -rno TARGET -T "$SELECTED_BASE" 2>/dev/null || true)
  select_grub_for_base "$steamcl_mount_for_pick"

  install_jump_loader "$SELECTED_BASE" "$SELECTED_GRUB"
}

declare -a TEMP_MOUNTS=() SEARCH_DIRS=() BASE_CANDIDATES=() GRUB_CANDIDATES=()
declare -A ADDED_DIRS=() SEEN_BASE=() SEEN_GRUB=()
SELECTED_BASE=""
SELECTED_GRUB=""
WATCHDOG_ERROR_SHOWN=0

trap cleanup EXIT
if [ "${1:-}" = "--detect-installed" ]; then
  if find_installed_jump 0 >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
elif [ "${1:-}" = "--remove" ]; then
  require_bins dialog lsblk mount findmnt efibootmgr install find blkid awk
  remove_jump_loader
else
  main
fi
