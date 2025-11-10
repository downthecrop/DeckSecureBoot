#!/bin/bash
set -e

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"

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

SBCTL_PRESENT=0
SBCTL_ENABLED=0
if command -v sbctl >/dev/null 2>&1; then
  SBCTL_PRESENT=1
  if secure_boot_enabled; then
    SBCTL_ENABLED=1
    MSG+="Secure Boot: YES\n"
  else
    SB_LINE=$(sbctl status 2>/dev/null | grep -i 'Secure Boot' || true)
    if echo "$SB_LINE" | grep -qi 'disabled'; then
      MSG+="Secure Boot: NO\n"
    else
      MSG+="Secure Boot: UNKNOWN (sbctl)\n"
    fi
  fi
else
  MSG+="Secure Boot: sbctl not found\n"
fi

if [ -f "$PENDING_FLAG" ]; then
  if [ "$SBCTL_PRESENT" -eq 1 ] && [ "$SBCTL_ENABLED" -eq 1 ]; then
    MSG+="\nSecure Boot change appears active now.\n"
    rm -f "$PENDING_FLAG"
  else
    MSG+="\nYou have changed SecureBoot State, a reboot is required to apply your changes.\n"
  fi
fi

dialog --backtitle "$BACKTITLE" --msgbox "$MSG" 22 90
