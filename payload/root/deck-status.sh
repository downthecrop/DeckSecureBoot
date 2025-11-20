#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

PENDING_FLAG="${DECK_SB_PENDING_FLAG}"

sbctl_state="missing"   # one of: missing, enabled, disabled, unknown

sbctl_status() {
  sb_status="Secure Boot: sbctl not found"
  if ! command -v sbctl >/dev/null 2>&1; then
    return
  fi

  if secure_boot_enabled; then
    sbctl_state="enabled"
    sb_status="Secure Boot: YES"
    return
  fi

  local sb_line
  sb_line=$(sbctl status 2>/dev/null | grep -i 'Secure Boot' || true)
  if echo "$sb_line" | grep -qi 'disabled'; then
    sbctl_state="disabled"
    sb_status="Secure Boot: NO"
  else
    sbctl_state="unknown"
    sb_status="Secure Boot: UNKNOWN (sbctl)"
  fi
}

pending_message() {
  [ -f "$PENDING_FLAG" ] || return
  local state applied=0 msg
  state=$(tr -d '\r\n' < "$PENDING_FLAG" 2>/dev/null)
  case "$state" in
    enable)  msg="Secure Boot enable is pending; reboot to apply your changes." ; [ "$sbctl_state" = "enabled" ] && applied=1 ;;
    disable) msg="Secure Boot disable is pending; reboot to apply your changes." ; [ "$sbctl_state" = "disabled" ] && applied=1 ;;
    *)       msg="Secure Boot state changed; reboot to apply your changes."     ; [[ "$sbctl_state" == "enabled" || "$sbctl_state" == "disabled" ]] && applied=1 ;;
  esac
  if [ "$applied" -eq 1 ]; then
    msg="Secure Boot change appears active now."
    rm -f "$PENDING_FLAG"
  fi
  printf '%s\n' "$msg"
}

sbctl_status
pending_note=$(pending_message || true)

status_lines=(
  "UEFI boot: $( [[ -d /sys/firmware/efi ]] && echo YES || echo NO )"
  "efivars mounted: $( mountpoint -q /sys/firmware/efi/efivars 2>/dev/null && echo YES || echo NO )"
  "$sb_status"
)

[ -n "$pending_note" ] && status_lines+=("" "$pending_note")

deck_dialog --msgbox "$(printf '%s\n' "${status_lines[@]}")" 18 90
