#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Steam Deck Secure Boot ISO builder
#
# - based on Archiso baseline
# - trims packages, adds sbctl + helpers
# - ships our PK/KEK/db
# - prepares sbctl in the *new* layout that recent sbctl expects:
#     /var/lib/sbctl/GUID
#     /var/lib/sbctl/keys/{PK,KEK,db}/...
#   so the archiso chroot hook can sign without "old configuration" warnings.
# - also keeps a copy at /usr/share/deck-sb/keys for our own scripts
# - dialog UI forced to black + cyan
# - fixed Deck GUID: decdecde-dec0-4dec-adec-decdecdecdec
# ---------------------------------------------------------------------------

WORKDIR=${WORKDIR:-/root/archlive}
PROFILENAME=${PROFILENAME:-steamdeck-sb}
PROFILE_SRC=/usr/share/archiso/configs/baseline

ISO_EXTRA_PKGS=(
  sbctl
  efitools
  mokutil
  dialog
  nano
  efibootmgr
  parted
  ntfs-3g
  amd-ucode
  linux-firmware-amdgpu
)

ISO_UNWANTED_PKGS=(
  dhcpcd iproute2 iputils iwd wpa_supplicant openvpn openconnect vpnc pptpclient ppp xl2tpd
  nbd nfs-utils usb_modeswitch modemmanager wireless-regdb wireless_tools wvdial
  cloud-init reflector sshfs lftp
  git lynx
  qemu-guest-agent open-vm-tools hyperv virtualbox-guest-utils-nox
  memtest86+ memtest86+-efi edk2-shell
  zsh grml-zsh-config livecd-sounds terminus-font
)

echo "[+] Steam Deck SB ISO build"
echo "[+] workdir: $WORKDIR"

# ---------------------------------------------------------------------------
# 1) make sure we have archiso + deps on the host
# ---------------------------------------------------------------------------
if ! pacman -Qi archiso >/dev/null 2>&1; then
  pacman -Sy --noconfirm archiso
fi
if ! pacman -Qi grub >/dev/null 2>&1; then
  pacman -Sy --noconfirm grub
fi
if ! pacman -Qi sbctl >/dev/null 2>&1; then
  pacman -Sy --noconfirm sbctl
fi

# ---------------------------------------------------------------------------
# 2) fresh profile from baseline
# ---------------------------------------------------------------------------
mkdir -p "$WORKDIR"
cd "$WORKDIR"
rm -rf "$PROFILENAME" || true
cp -r "$PROFILE_SRC" "$PROFILENAME"
cd "$PROFILENAME"

# ---------------------------------------------------------------------------
# 3) profiledef: uefi.systemd-boot only
# ---------------------------------------------------------------------------
cat > profiledef.sh <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="archlinux-steamdeck-sb"
iso_label="DECK_SB"
iso_publisher="Steam Deck Secure Boot ISO"
iso_application="Steam Deck Secure Boot ISO"
iso_version="latest"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
arch=('x86_64')
pacman_conf="pacman.conf"

airootfs_image_type="squashfs"
airootfs_image_tool_options=(
    -comp xz
    -b 1M
    -Xdict-size 100%
)

file_permissions=(
  ["/root/runme.sh"]="0:0:755"
  ["/root/menu.sh"]="0:0:755"
  ["/usr/local/sbin/deck-enroll.sh"]="0:0:755"
  ["/usr/local/sbin/deck-unenroll.sh"]="0:0:755"
  ["/usr/local/sbin/deck-sign-steamos.sh"]="0:0:755"
  ["/usr/local/sbin/deck-sign-efi.sh"]="0:0:755"
)
EOF

# ---------------------------------------------------------------------------
# 4) trim / add packages
# ---------------------------------------------------------------------------
tmpfile=$(mktemp)
cp packages.x86_64 "$tmpfile"

# drop big firmware
grep -vx 'linux-firmware' "$tmpfile" > "${tmpfile}.1" || true
mv "${tmpfile}.1" "$tmpfile"

# drop unwanted
for pkg in "${ISO_UNWANTED_PKGS[@]}"; do
  grep -vx "$pkg" "$tmpfile" > "${tmpfile}.1" || true
  mv "${tmpfile}.1" "$tmpfile"
done

# add wanted
for pkg in "${ISO_EXTRA_PKGS[@]}"; do
  if ! grep -qx "$pkg" "$tmpfile"; then
    echo "$pkg" >> "$tmpfile"
  fi
done

mv "$tmpfile" packages.x86_64

# ---------------------------------------------------------------------------
# 5) systemd-boot loader
# ---------------------------------------------------------------------------
mkdir -p efiboot/loader/entries
cat > efiboot/loader/entries/archiso-x86_64.conf <<'EOF'
title   Arch Linux (Steam Deck SB)
linux   /%INSTALL_DIR%/boot/x86_64/vmlinuz-linux
initrd  /%INSTALL_DIR%/boot/intel-ucode.img
initrd  /%INSTALL_DIR%/boot/amd-ucode.img
initrd  /%INSTALL_DIR%/boot/x86_64/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archiso_locale=en_US.UTF-8 archiso_keyboard=us fbcon=rotate:1
EOF

mkdir -p efiboot/EFI/systemd efiboot/EFI/BOOT
if [ -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi ]; then
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi efiboot/EFI/systemd/systemd-bootx64.efi
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi efiboot/EFI/BOOT/BOOTX64.EFI
else
  echo "[!] /usr/lib/systemd/boot/efi/systemd-bootx64.efi not found on host"
fi

# ---------------------------------------------------------------------------
# 6) airootfs startup
# ---------------------------------------------------------------------------
mkdir -p airootfs/root
cat > airootfs/root/runme.sh <<'EOF'
#!/bin/bash
set -e
echo "deck-sb" > /etc/hostname
echo "ran on $(date)" > /root/ran.log
exit 0
EOF

# ---------------------------------------------------------------------------
# 7) baked keys (PK = KEK = db)
#    - keep a copy in /usr/share/deck-sb/keys (for our scripts)
#    - install the *new-style* sbctl layout in /var/lib/sbctl/...
# ---------------------------------------------------------------------------
mkdir -p airootfs/usr/share/deck-sb/keys
mkdir -p airootfs/var/lib/sbctl/keys/PK
mkdir -p airootfs/var/lib/sbctl/keys/KEK
mkdir -p airootfs/var/lib/sbctl/keys/db

cat > airootfs/usr/share/deck-sb/keys/PK.key <<'EOF'
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

cat > airootfs/usr/share/deck-sb/keys/PK.pem <<'EOF'
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

# mirror into KEK/db for our tree
cp airootfs/usr/share/deck-sb/keys/PK.key  airootfs/usr/share/deck-sb/keys/KEK.key
cp airootfs/usr/share/deck-sb/keys/PK.pem  airootfs/usr/share/deck-sb/keys/KEK.pem
cp airootfs/usr/share/deck-sb/keys/PK.key  airootfs/usr/share/deck-sb/keys/db.key
cp airootfs/usr/share/deck-sb/keys/PK.pem  airootfs/usr/share/deck-sb/keys/db.pem

# now copy into the *new* sbctl path that the archiso hook uses
cp airootfs/usr/share/deck-sb/keys/PK.key  airootfs/var/lib/sbctl/keys/PK/PK.key
cp airootfs/usr/share/deck-sb/keys/PK.pem  airootfs/var/lib/sbctl/keys/PK/PK.pem
cp airootfs/usr/share/deck-sb/keys/KEK.key airootfs/var/lib/sbctl/keys/KEK/KEK.key
cp airootfs/usr/share/deck-sb/keys/KEK.pem airootfs/var/lib/sbctl/keys/KEK/KEK.pem
cp airootfs/usr/share/deck-sb/keys/db.key  airootfs/var/lib/sbctl/keys/db/db.key
cp airootfs/usr/share/deck-sb/keys/db.pem  airootfs/var/lib/sbctl/keys/db/db.pem

# write GUID in new spot so hook is happy
echo -n "decdecde-dec0-4dec-adec-decdecdecdec" > airootfs/var/lib/sbctl/GUID

# ---------------------------------------------------------------------------
# 8) helper scripts (enroll/unenroll/sign)
# ---------------------------------------------------------------------------
mkdir -p airootfs/usr/local/sbin

cat > airootfs/usr/local/sbin/deck-enroll.sh <<'EOF'
#!/bin/bash
set -e

KEYDIR="/usr/share/deck-sb/keys"
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

mkdir -p /run
echo pending > /run/sb_pending_reboot

echo "Keys enrolled (ours + Microsoft). Reboot to apply."
EOF
chmod +x airootfs/usr/local/sbin/deck-enroll.sh

cat > airootfs/usr/local/sbin/deck-unenroll.sh <<'EOF'
#!/bin/bash
set -e

KEYDIR="/usr/share/deck-sb/keys"
[ -d /sys/firmware/efi/efivars ] || { echo "UEFI/efivars not present"; exit 1; }

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

CHANGED=0
if efi-updatevar -d 0 -k "$KEYDIR/PK.key" PK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/KEK.key" KEK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/db.key" db 2>/dev/null; then CHANGED=1; fi

if [ "$CHANGED" -eq 1 ]; then
  mkdir -p /run
  echo pending > /run/sb_pending_reboot
  echo "Secure Boot vars cleared. Reboot to confirm."
else
  echo "No Secure Boot vars were cleared (nothing changed)."
fi
EOF
chmod +x airootfs/usr/local/sbin/deck-unenroll.sh

cat > airootfs/usr/local/sbin/deck-sign-steamos.sh <<'EOF'
#!/bin/bash
set -e
CAND=()

scan() {
  local base="$1"
  [ -d "$base" ] || return 0
  while IFS= read -r -d '' f; do CAND+=("$f"); done \
    < <(find "$base" -maxdepth 5 -type f \( -iname "steamcl.efi" -o -iname "*.efi" \) -print0 2>/dev/null)
}

scan /boot
scan /boot/efi
scan /efi
scan /mnt

for p in /boot/efi/EFI/steamos/steamcl.efi /boot/efi/EFI/STEAMOS/steamcl.efi /boot/efi/EFI/BOOT/BOOTX64.EFI; do
  [ -f "$p" ] && CAND=("$p" "${CAND[@]}")
done

mapfile -t CAND < <(printf "%s\n" "${CAND[@]}" | awk '!seen[$0]++')

command -v sbctl >/dev/null 2>&1 || { echo "sbctl not found"; exit 1; }

if [ "${#CAND[@]}" -eq 0 ]; then
  echo "No SteamOS/EFI loaders found."
  exit 1
fi

if command -v dialog >/dev/null 2>&1; then
  MENU=()
  i=1
  for c in "${CAND[@]}"; do
    MENU+=("$i" "$c")
    i=$((i+1))
  done
  CHOICE=$(dialog --stdout --menu "Select SteamOS/EFI loader to sign" 0 0 0 "${MENU[@]}") || exit 0
  TARGET="${CAND[$((CHOICE-1))]}"
else
  TARGET="${CAND[0]}"
fi

echo "Signing: $TARGET"
sbctl sign -s "$TARGET"
echo "Done."
EOF
chmod +x airootfs/usr/local/sbin/deck-sign-steamos.sh

cat > airootfs/usr/local/sbin/deck-sign-efi.sh <<'EOF'
#!/bin/bash
set -e
ROOTS=(/boot /boot/efi /efi /mnt)
ALL=()
for r in "${ROOTS[@]}"; do
  [ -d "$r" ] || continue
  while IFS= read -r -d '' f; do ALL+=("$f"); done \
    < <(find "$r" -maxdepth 6 -type f -iname "*.efi" -print0 2>/dev/null)
done
mapfile -t ALL < <(printf "%s\n" "${ALL[@]}" | awk '!seen[$0]++')

command -v sbctl >/dev/null 2>&1 || { echo "sbctl not found"; exit 1; }
[ "${#ALL[@]}" -gt 0 ] || { echo "No EFI files found."; exit 1; }

if command -v dialog >/dev/null 2>&1; then
  MENU=()
  i=1
  for c in "${ALL[@]}"; do
    MENU+=("$i" "$c")
    i=$((i+1))
  done
  CHOICE=$(dialog --stdout --menu "Select EFI to sign (Windows will warn)" 0 0 0 "${MENU[@]}") || exit 0
  TARGET="${ALL[$((CHOICE-1))]}"
else
  TARGET="${ALL[0]}"
fi

IS_WIN=0
case "$TARGET" in
  */EFI/Microsoft/Boot/*|*/efi/microsoft/boot/*|*/bootmgfw.efi|*/BOOTMGFW.EFI)
    IS_WIN=1 ;;
esac

if [ "$IS_WIN" -eq 1 ]; then
  if command -v dialog >/dev/null 2>&1; then
    dialog --yesno "This looks like a Windows EFI loader.\nWindows already trusts Microsoft keys.\nContinue anyway?" 12 60 || exit 0
  else
    read -r -p "This looks like Windows EFI. Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0
  fi
fi

echo "Signing: $TARGET"
sbctl sign -s "$TARGET"
echo "Done."
EOF
chmod +x airootfs/usr/local/sbin/deck-sign-efi.sh

# ---------------------------------------------------------------------------
# 9) dialog menu – black + cyan (no grey)
# ---------------------------------------------------------------------------
cat > airootfs/root/menu.sh <<'EOF'
#!/bin/bash

DIALOGRC=/root/.dialogrc
export DIALOGRC
if [ ! -f "$DIALOGRC" ]; then
  cat >"$DIALOGRC" <<'RC'
use_shadow = OFF
use_colors = ON
screen_color          = (BLACK,BLACK,OFF)
dialog_color          = (BLACK,BLACK,OFF)
menubox_color         = (BLACK,BLACK,OFF)
menubox_border_color  = (CYAN,BLACK,ON)
border_color          = (CYAN,BLACK,ON)
title_color           = (WHITE,BLACK,ON)
item_color            = (WHITE,BLACK,OFF)
item_selected_color   = (BLACK,CYAN,ON)
tag_color             = (CYAN,BLACK,OFF)
tag_selected_color    = (BLACK,CYAN,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_active_color   = (BLACK,CYAN,ON)
RC
fi

pending_flag() {
  [ -f /run/sb_pending_reboot ] && echo " (pending reboot)" || echo ""
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
      [ -f /run/sb_pending_reboot ] && rm -f /run/sb_pending_reboot
    elif echo "$SB_LINE" | grep -qi 'disabled'; then
      MSG+="Secure Boot: NO\n"
    else
      MSG+="Secure Boot: UNKNOWN (sbctl)\n"
    fi
  else
    MSG+="Secure Boot: sbctl not found\n"
  fi

  if [ -f /run/sb_pending_reboot ]; then
    if [ "$SBCTL_OK" -eq 1 ] && sbctl status 2>/dev/null | grep -qi 'enabled'; then
      MSG+="\nSecure Boot change appears active now.\n"
      rm -f /run/sb_pending_reboot
    else
      MSG+="\nA Secure Boot change was requested earlier. Reboot to apply.\n"
    fi
  fi

  dialog --msgbox "$MSG" 22 90
}

open_shell() {
  clear
  cat <<'EOM'
=========================================
 Steam Deck SB ISO - Root Shell
 To go back to menu: /root/menu.sh
 (USB keyboard usually required)
=========================================
EOM
  exec /bin/bash
}

while true; do
  PEND=$(pending_flag)
  if ! CHOICE=$(dialog --clear --stdout \
      --backtitle "Steam Deck Secure Boot" \
      --title "Main Menu" \
      --menu "Select an action" 0 0 0 \
      1 "Check Boot Status${PEND}" \
      2 "Enroll / Enable Secure Boot" \
      3 "Sign SteamOS / Deck loader" \
      4 "Sign another EFI (Ubuntu/Mint/etc)" \
      5 "Open root shell (requires USB keyboard)" \
      6 "--------------------------------" \
      7 "Reboot" \
      8 "Poweroff" \
      9 "Unenroll / Disable Secure Boot"); then
    exec /bin/bash
  fi

  case "$CHOICE" in
    1) check_boot_status ;;
    2) OUT=$(/usr/local/sbin/deck-enroll.sh 2>&1 || true); dialog --msgbox "$OUT" 22 90 ;;
    3) OUT=$(/usr/local/sbin/deck-sign-steamos.sh 2>&1 || true); dialog --msgbox "$OUT" 20 90 ;;
    4) OUT=$(/usr/local/sbin/deck-sign-efi.sh 2>&1 || true); dialog --msgbox "$OUT" 20 90 ;;
    5) open_shell ;;
    6) : ;;
    7) reboot ;;
    8) poweroff ;;
    9) OUT=$(/usr/local/sbin/deck-unenroll.sh 2>&1 || true); dialog --msgbox "$OUT" 22 90 ;;
  esac
done
EOF
chmod +x airootfs/root/menu.sh

# ---------------------------------------------------------------------------
# 10) systemd bits
# ---------------------------------------------------------------------------
mkdir -p airootfs/etc/systemd/system
cat > airootfs/etc/systemd/system/deck-startup.service <<'EOF'
[Unit]
Description=Steam Deck SB init
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/root/runme.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

cat > airootfs/root/customize_airootfs.sh <<'EOF'
#!/bin/bash
set -e
chmod +x /root/runme.sh /root/menu.sh \
  /usr/local/sbin/deck-enroll.sh \
  /usr/local/sbin/deck-unenroll.sh \
  /usr/local/sbin/deck-sign-steamos.sh \
  /usr/local/sbin/deck-sign-efi.sh

systemctl enable deck-startup.service

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<'EOC'
[Service]
ExecStart=
ExecStart=-/usr/bin/env bash -c 'exec /root/menu.sh'
StandardInput=tty
StandardOutput=tty
TTYReset=yes
TTYVHangup=yes
EOC

for svc in \
  systemd-networkd.service \
  systemd-networkd-wait-online.service \
  systemd-resolved.service \
  systemd-timesyncd.service \
  systemd-boot-update.service \
  systemd-firstboot.service \
  systemd-ldconfig.service \
  systemd-ldconfig.timer; do
  if systemctl list-unit-files | grep -q "^$svc"; then
    systemctl mask "$svc"
  fi
done
EOF
chmod +x airootfs/root/customize_airootfs.sh

# ---------------------------------------------------------------------------
# 11) build
# ---------------------------------------------------------------------------
if [ -d /out ]; then
  ISO_OUT_DIR=/out
else
  ISO_OUT_DIR="$(pwd)/out"
  mkdir -p "$ISO_OUT_DIR"
fi

echo "[+] building ISO -> $ISO_OUT_DIR"
mkarchiso -v -r -o "$ISO_OUT_DIR" .

ISO_PATH=$(ls -1t "$ISO_OUT_DIR"/*.iso | head -n1 || true)
echo
echo "[+] build complete"
echo "[+] ISO is at: ${ISO_PATH:-$ISO_OUT_DIR/*.iso}"
