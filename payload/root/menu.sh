#!/bin/bash
export DIALOGRC=/etc/dialogrc

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"

pending_flag() {
  [ -f "$PENDING_FLAG" ] && echo " (pending reboot)" || echo ""
}

check_boot_status() {
  MSG=""

  if [[ -d /sys/firmware/efi ]]; then
    MSG+="UEFI boot: YES\n"
  else
    MSG+="UEFI boot: NO\n"
  fi

  if mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
    MSG+="efivars mounted: YES\n"
  else
    MSG+="efivars mounted: NO\n"
  fi

  SBCTL_OK=0
  if command -v sbctl >/dev/null 2>&1; then
    SBCTL_OK=1
    SB_LINE=$(sbctl status 2>/dev/null | grep -i 'Secure Boot' || true)
    if echo "$SB_LINE" | grep -qi 'enabled'; then
      MSG+="Secure Boot: YES\n"
      [ -f "$PENDING_FLAG" ] && rm -f "$PENDING_FLAG"
    elif echo "$SB_LINE" | grep -qi 'disabled'; then
      MSG+="Secure Boot: NO\n"
    else
      MSG+="Secure Boot: UNKNOWN (sbctl)\n"
    fi
  else
    MSG+="Secure Boot: sbctl not found\n"
  fi

  if [ -f "$PENDING_FLAG" ]; then
    if [ "$SBCTL_OK" -eq 1 ] && sbctl status 2>/dev/null | grep -qi 'enabled'; then
      MSG+="\nSecure Boot change appears active now.\n"
      rm -f "$PENDING_FLAG"
    else
      MSG+="\nA Secure Boot change was requested earlier. Reboot to apply.\n"
    fi
  fi

  dialog --backtitle "$BACKTITLE" --msgbox "$MSG" 22 90
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
      3 "Signing Utility" \
      4 "Open root shell (requires USB keyboard)" \
      5 "--------------------------------" \
      6 "Reboot" \
      7 "Poweroff" \
      8 "Disable Secure Boot"); then
    continue
  fi

  case "$CHOICE" in
    1) check_boot_status ;;
    2) OUT=$(/root/deck-enroll.sh 2>&1 || true); dialog --backtitle "$BACKTITLE" --msgbox "$OUT" 22 90 ;;
    3) /root/deck-sign-efi.sh ;;
    4) open_shell ;;
    5) : ;;
    6) reboot ;;
    7) poweroff ;;
    8) OUT=$(/root/deck-unenroll.sh 2>&1 || true); dialog --backtitle "$BACKTITLE" --msgbox "$OUT" 22 90 ;;
  esac
done
