#!/bin/bash
set -e

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"

if [ "$(id -u)" -ne 0 ]; then
  echo "This needs to run as root (sbctl writes under /var/lib/sbctl)."
  exit 1
fi

for bin in sbctl lsblk mount find findmnt; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not found"; exit 1; }
done

FIND_TIMEOUT=${FIND_TIMEOUT:-15}
TIMEOUT_BIN=$(command -v timeout || true)

ISO_MOUNT="/run/archiso/bootmnt"
TMP_EFI_MOUNT_BASE="/run/deck-efi"
TMP_LINUX_MOUNT_BASE="/run/deck-root"
mkdir -p "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"
CLOVER_BUNDLE_KEY="__CLOVER_BUNDLE__"

LINUX_FSTYPES='ext2|ext3|ext4|btrfs|xfs|f2fs'
LINUX_GPT_GUIDS=(
  0FC63DAF-8483-4772-8E79-3D69D8477DE4  # Linux filesystem data
  44479540-F297-41B2-9AF7-D131D5F0458A  # Linux root (x86)
  4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709  # Linux root (x86-64)
)

SEARCH_DIRS=()
TEMP_MOUNTS=()
declare -A ADDED_DIRS=()
declare -A SEEN_FILES=()

cleanup() {
  for m in "${TEMP_MOUNTS[@]}"; do
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
}
trap cleanup EXIT

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

add_candidate() {
  local path="$1"
  [ -f "$path" ] || return 0
  if [[ -n "$ISO_MOUNT" && "$path" == "$ISO_MOUNT"* ]]; then
    return 0
  fi
  if [[ -n "${SEEN_FILES[$path]:-}" ]]; then
    return 0
  fi
  ALL+=("$path")
  SEEN_FILES["$path"]=1
}

ROOTS=(
  /boot
  /boot/efi
  /efi
  /mnt
  /run/media/*/*
)

for r in "${ROOTS[@]}"; do
  for p in $r; do
    add_search_dir "$p"
  done
done

progress_msg() {
  local msg="$1"
  dialog --infobox "$msg" 5 70
}

progress_msg "Scanning disks for EFI files and kernels..."

while read -r dev fstype parttype mnt; do
  [[ -b "$dev" ]] || continue
  fstype=${fstype,,}
  parttype=${parttype^^}

  mount_base=""
  add_boot_dir=0

  if [[ "$fstype" =~ ^(vfat|fat|fat16|fat32)$ || "$parttype" == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]]; then
    mount_base="$TMP_EFI_MOUNT_BASE"
  elif [[ "$fstype" =~ ^($LINUX_FSTYPES)$ ]]; then
    mount_base="$TMP_LINUX_MOUNT_BASE"
    add_boot_dir=1
  else
    for guid in "${LINUX_GPT_GUIDS[@]}"; do
      if [[ "$parttype" == "$guid" ]]; then
        mount_base="$TMP_LINUX_MOUNT_BASE"
        add_boot_dir=1
        break
      fi
    done
  fi

  [ -n "$mount_base" ] || continue

  if [ -z "$mnt" ] || [ "$mnt" = "-" ]; then
    mnt="$mount_base/$(basename "$dev")"
    mkdir -p "$mnt"
    if mount -o ro "$dev" "$mnt"; then
      TEMP_MOUNTS+=("$mnt")
    else
      rmdir "$mnt"
      continue
    fi
  fi

  if [ "$mount_base" = "$TMP_EFI_MOUNT_BASE" ]; then
    add_search_dir "$mnt/EFI"
    progress_msg "Mounted EFI $(basename "$dev")"
  else
    add_search_dir "$mnt/boot"
    add_search_dir "$mnt/boot/EFI"
    progress_msg "Mounted Linux $(basename "$dev")"
  fi
done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)

ALL=()

run_find() {
  local dir="$1"
  [ -d "$dir" ] || return
  local opts
  if [[ "$dir" == *EFI* ]]; then
    opts=(-iname '*.efi')
  else
    opts=( -iname 'vmlinuz*' )
  fi
  local cmd=(find "$dir" -maxdepth 4 -type f "${opts[@]}" -print0)
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$FIND_TIMEOUT" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

ensure_rw() {
  local path="$1"
  local mp opts
  mp=$(findmnt -rno TARGET -T "$path" 2>/dev/null || true)
  opts=$(findmnt -rno OPTIONS -T "$path" 2>/dev/null || true)
  [ -n "$mp" ] || return 0
  if [[ "$opts" == *ro* ]]; then
    if mount -o remount,rw "$mp" 2>/dev/null; then
      return 0
    fi
    printf 'Filesystem %s is mounted read-only. Remount it writable and try again.\n' "$mp"
    return 1
  fi
  return 0
}

for dir in "${SEARCH_DIRS[@]}"; do
  while IFS= read -r -d '' f; do
    add_candidate "$f"
  done < <(run_find "$dir" || true)
done
dialog --clear

ALL=("${ALL[@]}")

loader_variant_label() {
  local lower="$1"
  if [[ "$lower" == *mmx64*.efi* ]]; then
    echo "MokManager"
  elif [[ "$lower" == *shimx64*.efi* ]]; then
    echo "Shim"
  elif [[ "$lower" == *grubx64*.efi* ]]; then
    echo "GRUB"
  else
    echo ""
  fi
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

sanitize_dialog_text() {
  # Strip non-printable bytes so dialog doesn't show garbled characters
  LC_ALL=C tr -cd '\11\12\15\40-\176'
}

show_dialog_msg() {
  local heading="$1"
  local body="$2"
  local height="${3:-15}"
  local width="${4:-90}"

  if [ -z "$body" ]; then
    body="(no sbctl output)"
  fi

  local msg
  printf -v msg '%s\n\n%s' "$heading" "$body"
  dialog --msgbox "$msg" "$height" "$width"
}

sign_clover_bundle() {
  local files=("$@")
  if [ "${#files[@]}" -eq 0 ]; then
    dialog --msgbox "No Clover EFI files were detected." 8 60
    return 0
  fi

  local file display
  for file in "${files[@]}"; do
    display=$(format_display_path "$file")
    if ! ERR=$(ensure_rw "$file"); then
      dialog --msgbox "${ERR:-Unable to access $display.}" 9 70
      return 1
    fi
  done

  local summary=""
  local success=0 already=0 failed=0
  for file in "${files[@]}"; do
    display=$(format_display_path "$file")
    dialog --infobox "Signing Clover EFI:\n$display" 6 70
    RAW_OUTPUT=$(sbctl sign -s "$file" 2>&1)
    STATUS=$?
    OUTPUT=$(printf '%s' "$RAW_OUTPUT" | sanitize_dialog_text)
    if [ $STATUS -eq 0 ]; then
      summary+="$display: signed\n"
      success=$((success + 1))
    elif printf '%s' "$OUTPUT" | grep -qi 'already been signed'; then
      summary+="$display: already signed\n"
      already=$((already + 1))
    else
      summary+="$display: FAILED (exit $STATUS)\n$OUTPUT\n\n"
      failed=$((failed + 1))
    fi
  done

  summary=$(printf '%s' "$summary" | sanitize_dialog_text)
  local heading
  if [ $failed -eq 0 ]; then
    heading="Clover EFIs signing summary (signed: $success, already: $already)"
  else
    heading="Clover EFIs signing summary (signed: $success, already: $already, failed: $failed)"
  fi
  show_dialog_msg "$heading" "$summary" 20 90
  return 0
}

guess_kind() {
  local path="$1"
  local lower="${path,,}"
  local variant
  variant=$(loader_variant_label "$lower")

  if [[ "$lower" == *steamcl*.efi ]]; then
    echo "SteamOS (Default)"
  elif [[ "$lower" == *efi/steamos/* && "$lower" == *grub*.efi* ]]; then
    echo "SteamOS (GRUB)"
  elif [[ "$lower" == *efi/steamos/* ]]; then
    echo "SteamOS loader"
  elif [[ "$lower" == *vmlinuz* ]]; then
    echo "Linux kernel"
  elif [[ "$lower" == *ubuntu* ]]; then
    if [ -n "$variant" ]; then
      echo "Ubuntu $variant"
    else
      echo "Ubuntu loader"
    fi
  elif [[ "$lower" == *fedora* ]]; then
    if [ -n "$variant" ]; then
      echo "Fedora $variant"
    else
      echo "Fedora loader"
    fi
  elif [[ "$lower" == *microsoft* || "$lower" == *bootmgfw.efi* ]]; then
    echo "Windows bootmgfw"
  elif [[ "$lower" == *efi/boot/bootx64.efi* ]]; then
    echo "Generic UEFI bootloader"
  elif [ -n "$variant" ]; then
    echo "$variant"
  else
    echo "Unknown EFI"
  fi
}

if [ "${#ALL[@]}" -eq 0 ]; then
  if [ "${#SEARCH_DIRS[@]}" -gt 0 ]; then
    checked_dirs=$(printf "%s " "${SEARCH_DIRS[@]}")
  else
    checked_dirs="(no candidate directories)"
  fi

  dialog --msgbox "No EFI files were found.\nChecked: ${checked_dirs}.\nMount your target ESP and try again." 11 74
  exit 1
fi

while true; do
  MENU=()
  PICK_TARGETS=()
  i=1
  STEAM_CAND=()
  OTHER_CAND=()
  for c in "${ALL[@]}"; do
    if [[ "$c" == *EFI/steamos/* || "$c" == *EFI/STEAMOS/* || "$c" == *steamcl*.efi ]]; then
      STEAM_CAND+=("$c")
    elif [[ "$c" == *vmlinuz* ]]; then
      STEAM_CAND+=("$c")
    else
      OTHER_CAND+=("$c")
    fi
  done

  ORDERED=("${STEAM_CAND[@]}" "${OTHER_CAND[@]}")

  CLOVER_FILES=()
  NON_CLOVER_ORDERED=()
  for c in "${ORDERED[@]}"; do
    lower_val=${c,,}
    if [[ "$lower_val" == *clover* ]]; then
      CLOVER_FILES+=("$c")
    else
      NON_CLOVER_ORDERED+=("$c")
    fi
  done

  if [ "${#CLOVER_FILES[@]}" -gt 0 ]; then
    MENU+=("$i" "Clover EFIs :: ${#CLOVER_FILES[@]} file(s)")
    PICK_TARGETS+=("$CLOVER_BUNDLE_KEY")
    i=$((i+1))
  fi

  for c in "${NON_CLOVER_ORDERED[@]}"; do
    KIND=$(guess_kind "$c")
    DISPLAY_PATH=$(format_display_path "$c")
    MENU+=("$i" "$KIND :: $DISPLAY_PATH")
    PICK_TARGETS+=("$c")
    i=$((i+1))
  done

  if [ "${#PICK_TARGETS[@]}" -eq 0 ]; then
    dialog --msgbox "No signable files were found." 8 60
    break
  fi

  CHOICE=$(dialog --clear --stdout --cancel-label "Back" --menu "Select EFI / kernel to sign" 0 0 0 "${MENU[@]}") || break
  TARGET_KEY="${PICK_TARGETS[$((CHOICE-1))]}"

  if [ "$TARGET_KEY" = "$CLOVER_BUNDLE_KEY" ]; then
    sign_clover_bundle "${CLOVER_FILES[@]}"
    continue
  fi

  TARGET="$TARGET_KEY"

  if ! ERR=$(ensure_rw "$TARGET"); then
    dialog --msgbox "${ERR:-Unable to access target.}" 8 70
    continue
  fi

  lower_target=${TARGET,,}
  if [[ "$lower_target" == *microsoft* || "$lower_target" == *bootmgfw.efi* ]]; then
    dialog --yesno "This looks like a Windows EFI loader.\nResigning this EFI is not recommended.\nContinue anyway?" 12 60 || continue
  fi

  dialog --infobox "Signing:\n$TARGET" 6 70
  RAW_OUTPUT=$(sbctl sign -s "$TARGET" 2>&1)
  STATUS=$?
  OUTPUT=$(printf '%s' "$RAW_OUTPUT" | sanitize_dialog_text)

  if [ $STATUS -eq 0 ]; then
    show_dialog_msg "Signing succeeded" "$OUTPUT"
    continue
  fi

  if printf '%s' "$OUTPUT" | grep -qi 'already been signed'; then
    show_dialog_msg "Already signed" "$OUTPUT"
    continue
  fi

  show_dialog_msg "Signing failed (exit $STATUS)" "$OUTPUT"
done

exit 0
