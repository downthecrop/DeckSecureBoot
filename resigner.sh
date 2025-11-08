#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KEYS_DIR=${KEYS_DIR:-"$SCRIPT_DIR/keys"}

for key_file in "$KEYS_DIR/PK.key" "$KEYS_DIR/PK.pem"; do
  if [ ! -f "$key_file" ]; then
    echo "missing key file: $key_file"
    exit 1
  fi
done

ISO_IN=${1:-}
if [ -z "$ISO_IN" ]; then
  echo "usage: $0 <iso>"
  exit 1
fi
if [ ! -f "$ISO_IN" ]; then
  echo "iso not found: $ISO_IN"
  exit 1
fi

command -v xorriso >/dev/null 2>&1 || { echo "xorriso missing"; exit 1; }
command -v sbsign  >/dev/null 2>&1 || { echo "sbsign missing (install sbsigntools)"; exit 1; }

TMPDIR=$(mktemp -d)
EFI_IMG="$TMPDIR/efi.img"
EFI_MNT="$TMPDIR/mnt"
PK_KEY="$TMPDIR/PK.key"
PK_PEM="$TMPDIR/PK.pem"

echo "[+] temp dir: $TMPDIR"
echo "[+] embedding keys from $KEYS_DIR..."

cp "$KEYS_DIR/PK.key" "$PK_KEY"
cp "$KEYS_DIR/PK.pem" "$PK_PEM"

echo "[+] querying ISO for EFI image offset/size..."
REPORT=$(xorriso -indev "$ISO_IN" -report_el_torito plain)

EFI_LBA=$(printf '%s\n' "$REPORT" | awk '/El Torito boot img/ {print $NF; exit}')
EFI_BLKS=$(printf '%s\n' "$REPORT" | awk '/El Torito img blks/ {print $NF; exit}')

if [ -z "${EFI_LBA:-}" ] || [ -z "${EFI_BLKS:-}" ]; then
  echo "error: could not parse EFI info"
  echo "$REPORT"
  exit 1
fi

echo "[+] EFI LBA  : $EFI_LBA"
echo "[+] EFI blks : $EFI_BLKS"

ISO_OUT="${ISO_IN%.iso}-signed.iso"
cp -f "$ISO_IN" "$ISO_OUT"

echo "[+] extracting EFI image..."
dd if="$ISO_IN" of="$EFI_IMG" bs=2048 skip="$EFI_LBA" count="$EFI_BLKS" status=none

mkdir -p "$EFI_MNT"
echo "[+] mounting EFI image..."
mount -o loop "$EFI_IMG" "$EFI_MNT"

SIGNED=0
for f in "$EFI_MNT/EFI/BOOT/BOOTx64.EFI" "$EFI_MNT/EFI/BOOT/BOOTX64.EFI" "$EFI_MNT/EFI/BOOT/BOOTIA32.EFI"; do
  if [ -f "$f" ]; then
    echo "[+] signing $f ..."
    sbsign --key "$PK_KEY" --cert "$PK_PEM" --output "$f" "$f"
    SIGNED=1
  fi
done

umount "$EFI_MNT"

if [ "$SIGNED" -eq 0 ]; then
  echo "error: no boot efi found inside EFI image"
  exit 1
fi

echo "[+] writing patched EFI image back into ISO..."
dd if="$EFI_IMG" of="$ISO_OUT" bs=2048 seek="$EFI_LBA" conv=notrunc status=none

echo "[+] done. new ISO: $ISO_OUT"
echo "[+] temp files in: $TMPDIR"
