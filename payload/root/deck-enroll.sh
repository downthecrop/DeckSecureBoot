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

echo "Keys enrolled (ours + Microsoft). Reboot to apply."
echo "Note: Sign your SteamOS EFI/kernel if you plan to switch between SteamOS and Windows with Secure Boot enabled."
