#!/bin/bash
set -e

# shellcheck disable=SC1091
. /root/deck-env.sh

KEYDIR="${DECK_SB_KEYDIR}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"
FIXED_GUID="decdecde-dec0-4dec-adec-decdecdecdec"

for f in PK.key PK.pem KEK.key KEK.pem db.key db.pem; do
  [ -f "$KEYDIR/$f" ] || { echo "missing $KEYDIR/$f"; exit 1; }
done

[ -d /sys/firmware/efi/efivars ] || { echo "UEFI/efivars not present"; exit 1; }

mkdir -p /var/lib/sbctl
echo -n "$FIXED_GUID" > /var/lib/sbctl/GUID

mkdir -p /var/lib/sbctl/keys/PK /var/lib/sbctl/keys/KEK /var/lib/sbctl/keys/db
cp "$KEYDIR/PK.key"  /var/lib/sbctl/keys/PK/PK.key
cp "$KEYDIR/PK.pem"  /var/lib/sbctl/keys/PK/PK.pem
cp "$KEYDIR/KEK.key" /var/lib/sbctl/keys/KEK/KEK.key
cp "$KEYDIR/KEK.pem" /var/lib/sbctl/keys/KEK/KEK.pem
cp "$KEYDIR/db.key"  /var/lib/sbctl/keys/db/db.key
cp "$KEYDIR/db.pem"  /var/lib/sbctl/keys/db/db.pem

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

sbctl enroll-keys -m

mkdir -p "$(dirname "$PENDING_FLAG")"
echo pending > "$PENDING_FLAG"

echo "Keys enrolled: Deck SB + Microsoft"
echo "Next Step: Select 'Install Deck Jump Loader' form the menu to drop the signed deck-sb EFI and boot menus."
echo "Reminder: Unsigned EFIs (including the offical SteamOS Bootloader and Clover) will NOT boot under Secure Boot until you sign them. Use the 'Signing Utility' from the menu to sign additional EFIs."
