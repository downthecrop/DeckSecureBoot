#!/bin/bash
LABEL='SteamOS (custom jump)'
TARGET="\\EFI\\deck-sb\\jump.efi"

# Steam Deck specific defaults
DISK="/dev/nvme0n1"
PART="1"

# clean dump vars if present; keeps firmware updates happy
if ls /sys/firmware/efi/efivars/dump-type* >/dev/null 2>&1; then
  rm -f /sys/firmware/efi/efivars/dump-type* || true
fi

# if our entry is missing, recreate it
if ! efibootmgr | grep -qi "$LABEL"; then
  efibootmgr -c -d "$DISK" -p "$PART" -L "$LABEL" -l "$TARGET" >/dev/null 2>&1 || true
fi
