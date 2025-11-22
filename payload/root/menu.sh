#!/bin/bash
set -euo pipefail
export DIALOGRC=/etc/dialogrc

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"
ISO_DEBUG_LOG="${DECK_SB_ISO_DEBUG_LOG:-/run/deck-sb/install-iso-debug.log}"
SHOW_LOG_MENU="${DECK_SB_DEBUG:-0}"

pending_flag() {
  [ -f "$PENDING_FLAG" ] && echo " (pending reboot)" || echo ""
}

open_shell() {
  hostname deck-sb 2>/dev/null || true
  clear
  cat <<'EOM'
=========================================
 Steam Deck SB ISO - Root Shell
 To go back to menu: /root/menu.sh
=========================================
EOM
  exec /bin/bash
}

view_iso_debug_log() {
  if [ ! -s "$ISO_DEBUG_LOG" ]; then
    deck_dialog --msgbox "ISO debug log not found or empty at $ISO_DEBUG_LOG." 10 70
    return
  fi
  deck_dialog --textbox "$ISO_DEBUG_LOG" 22 90
}

while true; do
  PEND=$(pending_flag)
  JUMP_LABEL="Install Deck SB Jump Loader"
  if /root/deck-install-jump.sh --detect-installed >/dev/null 2>&1; then
    JUMP_LABEL="Reinstall/Remove Deck SB Jump Loader"
  fi
  MENU_ITEMS=(
    1 "Check Boot Status${PEND}"
    2 "Enable Secure Boot"
    3 "$JUMP_LABEL"
    4 "Install Deck SB ISO to disk *Optional* (~400MB)"
    5 "Signing Utility"
  )
  if [ "$SHOW_LOG_MENU" -eq 1 ]; then
    MENU_ITEMS+=(6 "View ISO debug log")
  fi
  MENU_ITEMS+=(
    7 "--------------------------------"
    8 "Reboot"
    9 "Poweroff"
    10 "Open root shell (requires USB keyboard)"
    11 "Disable Secure Boot"
  )

  if ! CHOICE=$(deck_dialog --clear --stdout \
      --title "Main Menu" \
      --menu "Select an action" 0 0 0 "${MENU_ITEMS[@]}"); then
    continue
  fi

  case "$CHOICE" in
    1) /root/deck-status.sh ;;
    2) OUT=$(/root/deck-enroll.sh 2>&1 || true); deck_dialog --msgbox "$OUT" 22 90 ;;
    3)
      if /root/deck-install-jump.sh --detect-installed >/dev/null 2>&1; then
        SUB=$(deck_dialog --clear --stdout --default-item 1 \
          --menu "Deck SB Jump Loader" 0 0 0 \
          1 "Reinstall jump loader" \
          2 "Remove jump loader") || continue
        case "$SUB" in
          1) /root/deck-install-jump.sh ;;
          2) /root/deck-install-jump.sh --remove ;;
        esac
      else
        /root/deck-install-jump.sh
      fi
      ;;
    4) /root/deck-install-iso.sh ;;
    5) /root/deck-sign-efi.sh ;;
    6) view_iso_debug_log ;;
    7) : ;;
    8) reboot ;;
    9) poweroff ;;
    10) open_shell ;;
    11) OUT=$(/root/deck-unenroll.sh 2>&1 || true); deck_dialog --msgbox "$OUT" 22 90 ;;
  esac
done
