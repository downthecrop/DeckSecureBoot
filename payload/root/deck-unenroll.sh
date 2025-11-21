#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

KEYDIR="${DECK_SB_KEYDIR}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"
[ -d /sys/firmware/efi/efivars ] || { echo "UEFI/efivars not present"; exit 1; }

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

CHANGED=0
if efi-updatevar -d 0 -k "$KEYDIR/PK.key" PK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/KEK.key" KEK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/db.key" db 2>/dev/null; then CHANGED=1; fi

if [ "$CHANGED" -eq 1 ]; then
  mkdir -p "$(dirname "$PENDING_FLAG")"
  echo disable > "$PENDING_FLAG"
  echo "Secure Boot vars cleared. Reboot to confirm."
  echo "To fully remove Deck SB, delete the Jump Loader entry from your EFI."
else
  echo "No Secure Boot vars were cleared (nothing changed)."
fi
