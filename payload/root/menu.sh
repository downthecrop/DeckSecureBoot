#!/bin/bash
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
  if ! CHOICE=$(dialog --clear --stdout \
      --backtitle "$BACKTITLE" \
      --title "Main Menu" \
      --menu "Select an action" 0 0 0 \
      1 "Check Boot Status${PEND}" \
      2 "Enable Secure Boot" \
      3 "Install SteamOS Jump Loader" \
      4 "Signing Utility" \
      5 "Open root shell (requires USB keyboard)" \
      6 "--------------------------------" \
      7 "Reboot" \
      8 "Poweroff" \
      9 "Disable Secure Boot"); then
    continue
  fi

  case "$CHOICE" in
    1) /root/deck-status.sh ;;
    2) OUT=$(/root/deck-enroll.sh 2>&1 || true); dialog --backtitle "$BACKTITLE" --msgbox "$OUT" 22 90 ;;
    3) /root/deck-install-jump.sh ;;
    4) /root/deck-sign-efi.sh ;;
    5) open_shell ;;
    6) : ;;
    7) reboot ;;
    8) poweroff ;;
    9) OUT=$(/root/deck-unenroll.sh 2>&1 || true); dialog --backtitle "$BACKTITLE" --msgbox "$OUT" 22 90 ;;
  esac
done
