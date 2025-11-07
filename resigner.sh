#!/usr/bin/env bash
set -euo pipefail

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
command -v sbsign  >/dev/null 2>&1 || { echo "sbsign missing (efitools)"; exit 1; }

TMPDIR=$(mktemp -d)
EFI_IMG="$TMPDIR/efi.img"
EFI_MNT="$TMPDIR/mnt"
PK_KEY="$TMPDIR/PK.key"
PK_PEM="$TMPDIR/PK.pem"

echo "[+] temp dir: $TMPDIR"
echo "[+] embedding keys..."

cat > "$PK_KEY" <<'EOF'
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDAiQ+44gfMGScB
XrKOF8smb+IbcvMzZaZJNYfngTr12ZfLcuGBXKA7JF5sssFMaRA7oQ/lYW4hT99q
acyRpSN3VFWbzZlrU3hq/SH+X1EEkoLfjmRaTjT5Zecuf7RGmf+VqCYvv6L73l/c
VwXnuX70kNkE82XmHGnX9wsmrMKH762lmS80NQS91Sl1jGKt3ylUZHHD7A68pSSR
JcLu2rFtqgaE9xt+V996QZvExD/nJQ/LvoVapB2z29dmdX4JidaK3hmUFseH2wYk
pbEuQB9JxhZZGHxwOiz50uctFiyUGXFJBkkS2yykuVtvDYYSzvPdpfFzqLw9+DGX
bWzrRwqJAgMBAAECggEADCB6e79dcFyIEEPh9u6iJ3pWAV+82E95u11LpfFhZS3w
9PMcueRyXOdFGGq/DToGAUt7UB5SLMBkJsa0CEj8DZnsrC5HtRdLQDwrY9DvriVU
1lsGWa3GgdUu3llT8/J1MNgVwMtPGNuSqdd7Eipb2kvrk/eJQxkBn/LVWR1DHSfQ
12xdq5jO/wxkeifPwwNSZ8QRIhorOV4jUZkBPJSYaaZDSNu3cDyeo7fVVXc5QVgm
ep5Iu8ntLiFcQkKkqsUuPGTre+Z1bjBhjFAqAK0+zJJ7xDF5Pfflwuj7W+AL0FZY
GxGTrZkIX/4Rg0Fe3H4pCAMZ311PlcemvMuH10BatQKBgQDfL/qqGLWh/gEW2Vb2
POMFe+YSttKuWNp8Kwj9h+ZFcSp+IW0T8vzklciUwJ8dqZNhqQ7KdNqpaJYZviHD
73oZoMuOqj1N0TGbsh/C2G76kgYlGhm8f1dBjZatHiMGrREpBO9m9+0A7o6TBP3T
RzMxmnMVLpML15KyYpBSrBPV5wKBgQDc13GRrnw0Kkwmi79LQUwJgB2jjW4re2gh
lsIqK88ok18ubdxRPe+gVak9DOq/hr4RuT6bE/nJIXKnJqLyGswjaV4GkfKN6u2C
gKnPjsl1jATHV5nq4gdpX/Z8C5EeEIDlmMxxOyl6ocVw95D2aXNsePf38fX5ftWg
z2LcmyIuDwKBgQC3sLJ7GrkrKXZWCu1C3tvuYIn8rxH5QtIXzgepOxev4bMaeoJf
H+c6b3jVzS9oZ3AQueadhM2PDrAzYcRCkjAJNckzkzO/f0R4I4N2h1HX0yVRlgjG
lnwHTPRNaXdkgD6WZyRut/ENiko4AKy0Hm6pDbhYH6wQ3A012l90W4I70wKBgQCC
mbJjCgIPw3fXT8uoEIyMDcT5ZPljI474VjSrRc8z2rtuNLAXJ36fnikAnrPw4hlj
V96rTUvp4yrvqMyySqCwzG47inIb9XPSOo6x3WpMZqqozKiMnHDvoz2cLCb81Zu0
rAEzcV5dVG/0F6QV5VTKMFvMuL3Td2uUtzBq8B9thwKBgQCwA6kAcdmfvtT87WM7
0xHkDUlPfJMt1ZiL9QdDPIR/AvDuQtiNBHUoaqDDJcwYwFe42URkBbitksXPTAtG
I6fHURi0C4xrR5XAFHdFz5pm3w3+1gTf8rj/NdPNOjlx+oheZaGGL6Gni8oF8S0L
gAleN/5iX9x9Htpi80o4N/kY3w==
-----END PRIVATE KEY-----
EOF

cat > "$PK_PEM" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIDETCCAfmgAwIBAgIUQBx1w+uTUKr7H2jtDG2rHfL4ZuowDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNU3RlYW0gRGVjayBQSzAeFw0yNTExMDcwMDE4MTJaFw0z
NTExMDUwMDE4MTJaMBgxFjAUBgNVBAMMDVN0ZWFtIERlY2sgUEswggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDAiQ+44gfMGScBXrKOF8smb+IbcvMzZaZJ
NYfngTr12ZfLcuGBXKA7JF5sssFMaRA7oQ/lYW4hT99qacyRpSN3VFWbzZlrU3hq
/SH+X1EEkoLfjmRaTjT5Zecuf7RGmf+VqCYvv6L73l/cVwXnuX70kNkE82XmHGnX
9wsmrMKH762lmS80NQS91Sl1jGKt3ylUZHHD7A68pSSRJcLu2rFtqgaE9xt+V996
QZvExD/nJQ/LvoVapB2z29dmdX4JidaK3hmUFseH2wYkpbEuQB9JxhZZGHxwOiz5
0uctFiyUGXFJBkkS2yykuVtvDYYSzvPdpfFzqLw9+DGXbWzrRwqJAgMBAAGjUzBR
MB0GA1UdDgQWBBSb3Ivqxe6awsRvL4HUvn7I45RgrTAfBgNVHSMEGDAWgBSb3Ivq
xe6awsRvL4HUvn7I45RgrTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUA
A4IBAQARr6ABa4JHjW8/jbTjo7RZpobkaR523BhXvPc3U4j19jKvOLygRT68QYF3
XWAMVeMcFROs06tcSubxqdAKa4INMyVVklGslIT/z3CkLR5q9QVdSgI4Z3sRzAmL
PUKOoWc4x6op2heyxujlLwwiZouXWHqaklSaUymae9mCPUtwPg135WNc+E2BC4Ep
eU5IzhUe8nLj4wlWQoxdBsKWhuvsVJVEWs/HkzPrwulIAHQSb/divYe3eTrYKfib
gXnR8BtFo0R8QGTtodx6d7nu1QO3275yvHAZTr3bfygs5AkSHF9oqpaUPAOyPM4c
OyHXIWSLcl2GuAJnBoSR3rKgFvvr
-----END CERTIFICATE-----
EOF

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
