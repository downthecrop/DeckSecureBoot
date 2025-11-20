#!/bin/bash
set -euo pipefail
export DIALOGRC=/etc/dialogrc

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"

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

while true; do
  PEND=$(pending_flag)
  JUMP_LABEL="Install Deck SB Jump Loader"
  if /root/deck-install-jump.sh --detect-installed >/dev/null 2>&1; then
    JUMP_LABEL="Reinstall/Remove Deck SB Jump Loader"
  fi

  if ! CHOICE=$(dialog --clear --stdout \
      --backtitle "$BACKTITLE" \
      --title "Main Menu" \
      --menu "Select an action" 0 0 0 \
      1 "Check Boot Status${PEND}" \
      2 "Enable Secure Boot" \
      3 "$JUMP_LABEL" \
      4 "Install Deck SB ISO to disk *Optional* (~400MB)" \
      5 "Signing Utility" \
      6 "--------------------------------" \
      7 "Reboot" \
      8 "Poweroff" \
      9 "Open root shell (requires USB keyboard)" \
      10 "Disable Secure Boot"); then
    continue
  fi

  case "$CHOICE" in
    1) /root/deck-status.sh ;;
    2) OUT=$(/root/deck-enroll.sh 2>&1 || true); deck_dialog --msgbox "$OUT" 22 90 ;;
    3)
      if /root/deck-install-jump.sh --detect-installed >/dev/null 2>&1; then
        SUB=$(dialog --clear --stdout --backtitle "$BACKTITLE" --default-item 1 \
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
    6) : ;;
    7) reboot ;;
    8) poweroff ;;
    9) open_shell ;;
    10) OUT=$(/root/deck-unenroll.sh 2>&1 || true); deck_dialog --msgbox "$OUT" 22 90 ;;
  esac
done
