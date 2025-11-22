#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
ISO_RELATIVE_PATH="/usr/local/share/deck-sb"
ISO_VOLUME_LABEL="${DECK_SB_ISO_LABEL:-DECK_SB}"
ISO_INSTALL_DIR="${DECK_SB_INSTALL_DIR:-arch}"
TEMP_ISO_MOUNT=""
declare -a ISO_TEMP_MOUNTS=()
REQUIRED_MB=400
ISO_DEBUG_LOG="${DECK_SB_ISO_DEBUG_LOG:-/run/deck-sb/install-iso-debug.log}"

log_debug() {
  local msg="$1"
  [ "${DECK_SB_DEBUG:-0}" -eq 1 ] || return 0
  mkdir -p "$(dirname "$ISO_DEBUG_LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%F %T')" "$msg" | tee -a "$ISO_DEBUG_LOG" >&2
}

format_display_path() {
  local path="$1"
  [ -n "$path" ] || return 0
  printf '%s\n' "$path" | sed -e 's://*:/:g'
}

error_dialog() {
  deck_dialog --backtitle "$BACKTITLE" --msgbox "$1" 10 80
}

info_dialog() {
  deck_dialog --backtitle "$BACKTITLE" --msgbox "$1" 8 80
}

progress_dialog() {
  deck_dialog --backtitle "$BACKTITLE" --infobox "$1" 6 70
}

cleanup_temp_iso_mount() {
  local m preserve="${DECK_SB_ISO_ROOT:-}"
  local labels=("$ISO_VOLUME_LABEL" "DECK_SB" "DECK SB")
  for m in "${ISO_TEMP_MOUNTS[@]-}"; do
    if [ -n "$preserve" ] && [ "$m" = "$preserve" ]; then
      log_debug "cleanup_temp_iso_mount: preserving ISO mount at $m"
      continue
    fi
    local src fstype label keep_live=0
    src=$(findmnt -rno SOURCE --target "$m" 2>/dev/null || true)
    src=${src%%[*}
    if [ -n "$src" ]; then
      fstype=$(lsblk -nrpo FSTYPE "$src" 2>/dev/null | head -n1 || true)
      label=$(lsblk -nrpo LABEL "$src" 2>/dev/null | head -n1 || true)
      [[ "${fstype,,}" = "iso9660" ]] && keep_live=1
      local iso_label
      for iso_label in "${labels[@]}"; do
        [ -n "$iso_label" ] && [ "$label" = "$iso_label" ] && keep_live=1
      done
    fi
    if [ "$keep_live" -eq 1 ]; then
      log_debug "cleanup_temp_iso_mount: keeping live media mount at $m (src=${src:-unknown})"
      continue
    fi
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
  ISO_TEMP_MOUNTS=()
  TEMP_ISO_MOUNT=""
}

block_inventory() {
  # Emit NAME/FSTYPE/LABEL/MOUNTPOINT lines in lsblk -P style, preferring blkid.
  local out=""
  if command -v blkid >/dev/null 2>&1; then
    out=$(blkid -o list -w /dev/null 2>/dev/null | awk '
      NR==1 {next} # header
      {
        dev=$1; fstype=$2; label=$3
        $1=""; $2=""; $3=""
        sub(/^[ \t]+/, "", $0)
        mount=$0
        if (mount == "(not mounted)" || mount == "-" ) { mount="" }
        printf "NAME=\"%s\" FSTYPE=\"%s\" LABEL=\"%s\" MOUNTPOINT=\"%s\"\n", dev, fstype, label, mount
      }
    ' ) || true
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT -P 2>/dev/null || lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || true
}

collect_iso_roots() {
  local roots=()
  local candidate
  local override="${DECK_SB_ISO_ROOT:-}"
  declare -A seen=()
  log_debug "collect_iso_roots: start (override=$override)"
  for candidate in /run/archiso/bootmnt /run/initramfs/archiso/bootmnt; do
    if [ -d "$candidate" ]; then
      if [ -z "${seen[$candidate]:-}" ]; then
        roots+=("$candidate")
        seen["$candidate"]=1
        log_debug "collect_iso_roots: add default candidate $candidate"
      fi
    fi
  done
  if [ -n "$override" ] && [ -d "$override" ] && [ -z "${seen[$override]:-}" ]; then
    roots+=("$override")
    seen["$override"]=1
    log_debug "collect_iso_roots: add override $override"
  fi
  local labels=("$ISO_VOLUME_LABEL" "DECK_SB" "DECK SB")
  local line dev fstype mnt label
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    fstype=${line#*FSTYPE=\"}; fstype=${fstype%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    mnt=${line#*MOUNTPOINT=\"}; mnt=${mnt%%\"*}
    local is_live=0
    [[ "${fstype,,}" = "iso9660" ]] && is_live=1
    local candidate_label
    for candidate_label in "${labels[@]}"; do
      [ -n "$candidate_label" ] && [ "$label" = "$candidate_label" ] && is_live=1
    done
    [ "$is_live" -eq 1 ] || continue

    if [ -n "$mnt" ] && [ "$mnt" != "-" ] && [ -d "$mnt" ]; then
      if [ -z "${seen[$mnt]:-}" ]; then
        roots+=("$mnt")
        seen["$mnt"]=1
        log_debug "collect_iso_roots: add mounted $dev at $mnt"
      fi
      continue
    fi

    local tmp
    tmp=$(mktemp -d /run/deck-sb-iso.XXXXXX)
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
      ISO_TEMP_MOUNTS+=("$tmp")
      TEMP_ISO_MOUNT="$tmp"
      roots+=("$tmp")
      seen["$tmp"]=1
      log_debug "collect_iso_roots: mounted $dev at $tmp"
    else
      log_debug "collect_iso_roots: failed to mount $dev at $tmp"
      rmdir "$tmp" 2>/dev/null || true
    fi
  done < <(block_inventory)

  if [ "${#roots[@]}" -eq 0 ]; then
    local mounted
    mounted=$(mount_live_iso_device 2>/dev/null || true)
    if [ -n "$mounted" ]; then
      if [ -z "${seen[$mounted]:-}" ]; then
        roots+=("$mounted")
        seen["$mounted"]=1
      fi
      log_debug "collect_iso_roots: mount_live_iso_device returned $mounted"
    fi
  fi
  if [ "${#roots[@]}" -eq 0 ]; then
    log_debug "collect_iso_roots: none found"
    return 1
  fi
  printf '%s\n' "${roots[@]}"
  log_debug "collect_iso_roots: final roots=${roots[*]}"
  return 0
}

find_live_usb_device() {
  local labels=("$ISO_VOLUME_LABEL" "DECK_SB" "DECK SB")
  local line dev label candidate
  log_debug "find_live_usb_device: searching labels ${labels[*]}"
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    for candidate in "${labels[@]}"; do
      [ -n "$candidate" ] || continue
      if [ "$label" = "$candidate" ]; then
        log_debug "find_live_usb_device: match $dev label=$label"
        echo "$dev"
        return 0
      fi
    done
  done < <(block_inventory)
  return 1
}

find_iso9660_device() {
  local line dev fstype mnt
  log_debug "find_iso9660_device: scanning for iso9660"
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    fstype=${line#*FSTYPE=\"}; fstype=${fstype%%\"*}
    mnt=${line#*MOUNTPOINT=\"}; mnt=${mnt%%\"*}
    [[ "${fstype,,}" = "iso9660" ]] || continue
    log_debug "find_iso9660_device: found $dev mnt=${mnt:--}"
    if [ -n "$mnt" ] && [ "$mnt" != "-" ]; then
      printf '%s|%s\n' "$dev" "$mnt"
    else
      printf '%s|\n' "$dev"
    fi
    return 0
  done < <(block_inventory)
  return 1
}

mount_live_iso_device() {
  if [ -n "$TEMP_ISO_MOUNT" ] && [ -d "$TEMP_ISO_MOUNT" ]; then
    if findmnt -rno SOURCE --target "$TEMP_ISO_MOUNT" >/dev/null 2>&1; then
      log_debug "mount_live_iso_device: reusing TEMP_ISO_MOUNT=$TEMP_ISO_MOUNT"
      echo "$TEMP_ISO_MOUNT"
      return 0
    fi
    rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
    TEMP_ISO_MOUNT=""
  fi
  local dev
  local pre_mounted=""
  dev=$(find_live_usb_device 2>/dev/null || true)
  if [ -z "$dev" ]; then
    local iso_line
    iso_line=$(find_iso9660_device 2>/dev/null || true)
    if [ -n "$iso_line" ]; then
      dev=${iso_line%%|*}
      pre_mounted=${iso_line#*|}
      [ "$pre_mounted" = "$iso_line" ] && pre_mounted=""
    fi
  fi
  if [ -z "$dev" ]; then
    log_debug "mount_live_iso_device: no device found"
    return 1
  fi
  if [ -n "$pre_mounted" ] && [ -d "$pre_mounted" ]; then
    log_debug "mount_live_iso_device: using pre-mounted $pre_mounted for $dev"
    echo "$pre_mounted"
    return 0
  fi
  local existing
  existing=$(findmnt -rno TARGET -S "$dev" 2>/dev/null || true)
  if [ -n "$existing" ] && [ -d "$existing" ]; then
    log_debug "mount_live_iso_device: using existing mount $existing for $dev"
    echo "$existing"
    return 0
  fi
  TEMP_ISO_MOUNT=$(mktemp -d /run/deck-sb-iso.XXXXXX)
  if mount -o ro "$dev" "$TEMP_ISO_MOUNT" 2>/dev/null; then
    ISO_TEMP_MOUNTS+=("$TEMP_ISO_MOUNT")
    log_debug "mount_live_iso_device: mounted $dev at $TEMP_ISO_MOUNT"
    echo "$TEMP_ISO_MOUNT"
    return 0
  fi
  log_debug "mount_live_iso_device: failed to mount $dev"
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

select_iso_files_from_root() {
  # Try to resolve kernel/initrd/squashfs under a given ISO root.
  local root="$1"
  local -n _k="$2" _i="$3" _s="$4"
  local k i s
  k=""; i=""; s=""
  [ -n "$root" ] && [ -d "$root" ] || return 1

  local k_candidates=(
    "$root/$ISO_INSTALL_DIR/boot/x86_64/vmlinuz-linux"
    "$root/$ISO_INSTALL_DIR/boot/vmlinuz-linux"
    "$root/$ISO_INSTALL_DIR/vmlinuz-linux"
  )
  local i_candidates=(
    "$root/$ISO_INSTALL_DIR/boot/x86_64/initramfs-linux.img"
    "$root/$ISO_INSTALL_DIR/boot/initramfs-linux.img"
  )
  local s_candidates=(
    "$root/$ISO_INSTALL_DIR/x86_64/airootfs.sfs"
    "$root/$ISO_INSTALL_DIR/airootfs.sfs"
    "$root/airootfs.sfs"
  )

  for k in "${k_candidates[@]}"; do
    [ -f "$k" ] && break || k=""
  done
  for i in "${i_candidates[@]}"; do
    [ -f "$i" ] && break || i=""
  done
  for s in "${s_candidates[@]}"; do
    [ -f "$s" ] && break || s=""
  done

  if [ -n "$k" ] && [ -n "$i" ] && [ -n "$s" ]; then
    _k="$k"
    _i="$i"
    _s="$s"
    log_debug "select_iso_files_from_root: success root=$root k=$k i=$i s=$s"
    return 0
  fi
  log_debug "select_iso_files_from_root: missing in $root k=${k:-none} i=${i:-none} s=${s:-none}"
  return 1
}

find_iso_payload_sources() {
  local -n _k="$1" _i="$2" _s="$3"
  _k=""; _i=""; _s=""

  local -a roots=() temp_mounts=()
  local -A seen=()

  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    if [ -z "${seen[$r]:-}" ]; then
      roots+=("$r")
      seen["$r"]=1
      log_debug "find_iso_payload_sources: add root $r (collect_iso_roots)"
    fi
  done < <(collect_iso_roots 2>/dev/null || true)

  while IFS= read -r line; do
    local dev fstype mnt label is_live=0
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    fstype=${line#*FSTYPE=\"}; fstype=${fstype%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    mnt=${line#*MOUNTPOINT=\"}; mnt=${mnt%%\"*}
    [[ "${fstype,,}" = "iso9660" ]] && is_live=1
    local iso_label
    for iso_label in "$ISO_VOLUME_LABEL" "DECK_SB" "DECK SB"; do
      [ -n "$iso_label" ] && [ "$label" = "$iso_label" ] && is_live=1
    done
    [ "$is_live" -eq 1 ] || continue

    local root_path="$mnt"
    if [ -z "$root_path" ] || [ "$root_path" = "-" ]; then
      root_path=$(mktemp -d /run/deck-sb-iso.XXXXXX)
      if mount -o ro "$dev" "$root_path" 2>/dev/null; then
        temp_mounts+=("$root_path")
        ISO_TEMP_MOUNTS+=("$root_path")
        TEMP_ISO_MOUNT="$root_path"
        log_debug "find_iso_payload_sources: mounted iso9660 $dev at $root_path"
      else
        log_debug "find_iso_payload_sources: failed to mount iso9660 $dev at $root_path"
        rmdir "$root_path" 2>/dev/null || true
        continue
      fi
    fi

    if [ -n "${seen[$root_path]:-}" ]; then
      log_debug "find_iso_payload_sources: skip duplicate root $root_path"
      continue
    fi
    roots+=("$root_path")
    seen["$root_path"]=1
    log_debug "find_iso_payload_sources: add root $root_path (iso9660 dev=$dev)"
  done < <(block_inventory)

  local r
  for r in "${roots[@]}"; do
    if select_iso_files_from_root "$r" _k _i _s; then
      DECK_SB_ISO_ROOT="$r"
      log_debug "find_iso_payload_sources: found payload under $r"
      return 0
    fi
  done
  log_debug "find_iso_payload_sources: no payload found across roots=${roots[*]}"

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
  local mounted_iso=""

  mounted_iso=$(mount_live_iso_device 2>/dev/null || true)
  if [ -n "$mounted_iso" ] && [ -d "$mounted_iso" ]; then
    DECK_SB_ISO_ROOT="$mounted_iso"
    log_debug "copy_iso_payload: mounted_iso=$mounted_iso"
  fi
  kernel_src=$(find_kernel_source 2>/dev/null || true)
  initrd_src=$(find_initrd_source 2>/dev/null || true)
  squash_src=$(find_squashfs_source 2>/dev/null || true)

  log_debug "copy_iso_payload: initial sources k=${kernel_src:-none} i=${initrd_src:-none} s=${squash_src:-none}"
  if [ -z "$kernel_src" ] || [ -z "$initrd_src" ] || [ -z "$squash_src" ]; then
    find_iso_payload_sources kernel_src initrd_src squash_src || true
  fi

  if [ -z "$kernel_src" ] || [ -z "$initrd_src" ] || [ -z "$squash_src" ]; then
    log_debug "copy_iso_payload: final sources missing k=${kernel_src:-none} i=${initrd_src:-none} s=${squash_src:-none}"
    local debug_hint="Sources: k=${kernel_src:-none}, i=${initrd_src:-none}, s=${squash_src:-none}\nISO root: ${DECK_SB_ISO_ROOT:-none}\nLog: $ISO_DEBUG_LOG"
    error_dialog "Live ISO files missing. Ensure the Secure Boot USB (${ISO_VOLUME_LABEL}) is connected and readable.\n\n${debug_hint}"
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
  deck_dialog --backtitle "$BACKTITLE" --gauge "Copying Secure Boot ISO files (~${REQUIRED_MB}MB)..." 8 70 0 <"$fifo" &
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
  log_debug "==== deck-install-iso start ===="
  log_debug "lsblk snapshot:"
  LSBLK_SNAPSHOT=$(lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT -P 2>/dev/null || true)
  if [ -n "$LSBLK_SNAPSHOT" ]; then
    printf '%s\n' "$LSBLK_SNAPSHOT" | tee -a "$ISO_DEBUG_LOG" >&2 || true
  else
    log_debug "lsblk snapshot: (no output)"
  fi

  trap cleanup_temp_iso_mount EXIT

  local root_override="${1:-}" realroot
  if [ -n "$root_override" ]; then
    realroot="$root_override"
  else
    realroot=$(find_steamos_root 2>/dev/null || true)
  fi

  if [ -z "$realroot" ]; then
    error_dialog "Could not detect a SteamOS root partition. Mount it manually and retry."
    exit 1
  fi

  local pretty_root
  pretty_root=$(format_display_path "$realroot")
  info_dialog "SteamOS root detected at $pretty_root."

  if [ -d "$realroot$ISO_RELATIVE_PATH" ]; then
    if ! deck_dialog --backtitle "$BACKTITLE" --yesno "Existing files found in $ISO_RELATIVE_PATH. Overwrite them?" 10 70; then
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
