#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================
WORKDIR=${WORKDIR:-/root/archlive}
PROFILENAME=${PROFILENAME:-steamdeck-sb}
PROFILE_SRC=/usr/share/archiso/configs/baseline

# packages we explicitly want inside the ISO
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

# packages we don't want
ISO_UNWANTED_PKGS=(
  # networking / wifi / vpn
  dhcpcd iproute2 iputils iwd wpa_supplicant openvpn openconnect vpnc pptpclient ppp xl2tpd
  nbd nfs-utils usb_modeswitch modemmanager wireless-regdb wireless_tools wvdial
  # cloud / misc net helpers
  cloud-init reflector sshfs lftp
  # no git / text browser
  git lynx
  # VM / guest additions
  qemu-guest-agent open-vm-tools hyperv virtualbox-guest-utils-nox
  # boot extras we don't need
  memtest86+ memtest86+-efi edk2-shell
  # shell / live fluff
  zsh grml-zsh-config livecd-sounds terminus-font
)

echo "[+] Steam Deck Secure Boot ISO builder (hardcoded keys + MS db + deck theme)"
echo "[+] workdir: $WORKDIR"

# ============================================================================
# 1) install archiso + grub on host
# ============================================================================
if ! pacman -Qi archiso >/dev/null 2>&1; then
  echo "[+] installing archiso..."
  pacman -Sy --noconfirm archiso
fi
if ! pacman -Qi grub >/dev/null 2>&1; then
  echo "[+] installing grub..."
  pacman -Sy --noconfirm grub
fi

# ============================================================================
# 2) prepare fresh profile from baseline
# ============================================================================
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ -d "$PROFILENAME" ]; then
  echo "[+] removing old profile $PROFILENAME"
  rm -rf "$PROFILENAME"
fi

echo "[+] copying baseline -> $PROFILENAME"
cp -r "$PROFILE_SRC" "$PROFILENAME"
cd "$PROFILENAME"

# ============================================================================
# 3) profiledef.sh: UEFI-only, xz, perms
# ============================================================================
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

# ============================================================================
# 4) trim packages.x86_64
# ============================================================================
echo "[+] trimming packages.x86_64"

tmpfile=$(mktemp)
cp packages.x86_64 "$tmpfile"

# drop monolithic firmware
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

# ============================================================================
# 5) rotate console for Deck
# ============================================================================
mkdir -p efiboot/loader/entries
cat > efiboot/loader/entries/archiso-x86_64.conf <<'EOF'
title   Arch Linux (Steam Deck SB)
linux   /%INSTALL_DIR%/boot/x86_64/vmlinuz-linux
initrd  /%INSTALL_DIR%/boot/intel-ucode.img
initrd  /%INSTALL_DIR%/boot/amd-ucode.img
initrd  /%INSTALL_DIR%/boot/x86_64/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archiso_locale=en_US.UTF-8 archiso_keyboard=us fbcon=rotate:1
EOF

# ============================================================================
# 6) write airootfs base files
# ============================================================================
echo "[+] writing airootfs/root/runme.sh"
mkdir -p airootfs/root
cat > airootfs/root/runme.sh <<'EOF'
#!/bin/bash
set -e
echo "=== Steam Deck Secure Boot live startup ==="
date
echo "deck-sb" > /etc/hostname
echo "ran on $(date)" > /root/ran.log
exit 0
EOF

# ============================================================================
# 7) theme for dialog (/root/.dialogrc)
# ============================================================================
echo "[+] writing airootfs/root/.dialogrc (deck colors)"
cat > airootfs/root/.dialogrc <<'EOF'
use_shadow = no
use_colors = yes

screen_color = black/black
dialog_color = white/black
title_color = white/black
border_color = white/black

item_color = white/black
item_selected_color = black/cyan
tag_color = white/black
tag_selected_color = black/cyan

button_active_color = black/cyan
button_inactive_color = white/black
button_key_color = white/black
button_label_color = white/black

textbox_color = white/black
inputbox_color = white/black
searchbox_color = white/black
searchbox_title_color = white/black
searchbox_border_color = white/black
EOF

# ============================================================================
# 8) hardcoded keys (same for PK/KEK/db)
# ============================================================================
echo "[+] writing hardcoded keys into airootfs"
mkdir -p airootfs/usr/share/deck-sb/keys

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

# reuse for KEK and db
cp airootfs/usr/share/deck-sb/keys/PK.key  airootfs/usr/share/deck-sb/keys/KEK.key
cp airootfs/usr/share/deck-sb/keys/PK.pem  airootfs/usr/share/deck-sb/keys/KEK.pem
cp airootfs/usr/share/deck-sb/keys/PK.key  airootfs/usr/share/deck-sb/keys/db.key
cp airootfs/usr/share/deck-sb/keys/PK.pem  airootfs/usr/share/deck-sb/keys/db.pem

# ============================================================================
# 9) helper: enroll (ours + Microsoft) and mark pending reboot
# ============================================================================
echo "[+] writing airootfs/usr/local/sbin/deck-enroll.sh"
mkdir -p airootfs/usr/local/sbin
cat > airootfs/usr/local/sbin/deck-enroll.sh <<'EOF'
#!/bin/bash
set -e

KEYDIR="/usr/share/deck-sb/keys"
NEEDED=(PK.key PK.pem KEK.key KEK.pem db.key db.pem)

for f in "${NEEDED[@]}"; do
  if [ ! -f "$KEYDIR/$f" ]; then
    echo "Missing $KEYDIR/$f"
    exit 1
  fi
done

if [ ! -d /sys/firmware/efi/efivars ]; then
  echo "Not booted via UEFI or efivars not mounted."
  exit 1
fi

mkdir -p /var/lib/sbctl/keys/PK /var/lib/sbctl/keys/KEK /var/lib/sbctl/keys/db
cp "$KEYDIR/PK.key"  /var/lib/sbctl/keys/PK/PK.key
cp "$KEYDIR/PK.pem"  /var/lib/sbctl/keys/PK/PK.pem
cp "$KEYDIR/KEK.key" /var/lib/sbctl/keys/KEK/KEK.key
cp "$KEYDIR/KEK.pem" /var/lib/sbctl/keys/KEK/KEK.pem
cp "$KEYDIR/db.key"  /var/lib/sbctl/keys/db/db.key
cp "$KEYDIR/db.pem"  /var/lib/sbctl/keys/db/db.pem

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

# add MS db too
sbctl enroll-keys -m

# mark "pending reboot" so UI can show it
mkdir -p /run
echo "pending" > /run/sb_pending_reboot

echo "Keys enrolled (our PK/KEK/db + Microsoft). Reboot to enable Secure Boot."
EOF

# ============================================================================
# 10) helper: unenroll (mark pending) 
# ============================================================================
echo "[+] writing airootfs/usr/local/sbin/deck-unenroll.sh"
cat > airootfs/usr/local/sbin/deck-unenroll.sh <<'EOF'
#!/bin/bash
set -e

KEYDIR="/usr/share/deck-sb/keys"
if [ ! -d /sys/firmware/efi/efivars ]; then
  echo "Not booted via UEFI or efivars not mounted."
  exit 1
fi

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

efi-updatevar -d 0 -k "$KEYDIR/PK.key" PK || true
efi-updatevar -d 0 -k "$KEYDIR/KEK.key" KEK || true
efi-updatevar -d 0 -k "$KEYDIR/db.key" db || true
efi-updatevar -d 0 -k "$KEYDIR/db.key" db || true

mkdir -p /run
echo "pending" > /run/sb_pending_reboot

echo "Secure Boot vars cleared (or attempted). Reboot to confirm."
EOF

# ============================================================================
# 11) helper: sign SteamOS / Deck-ish
# ============================================================================
echo "[+] writing airootfs/usr/local/sbin/deck-sign-steamos.sh"
cat > airootfs/usr/local/sbin/deck-sign-steamos.sh <<'EOF'
#!/bin/bash
set -e

CANDIDATES=()

add_candidates_from() {
  local base="$1"
  [ -d "$base" ] || return 0
  while IFS= read -r -d '' f; do
    CANDIDATES+=("$f")
  done < <(find "$base" -maxdepth 5 -type f \( -iname "steamcl.efi" -o -iname "*.efi" \) -print0 2>/dev/null)
}

add_candidates_from /boot
add_candidates_from /boot/efi
add_candidates_from /efi
add_candidates_from /mnt

# push typical SteamOS paths to front
for p in \
  /boot/efi/EFI/steamos/steamcl.efi \
  /boot/efi/EFI/STEAMOS/steamcl.efi \
  /boot/efi/EFI/BOOT/BOOTX64.EFI; do
  [ -f "$p" ] && CANDIDATES=("$p" "${CANDIDATES[@]}")
done

mapfile -t CANDIDATES < <(printf "%s\n" "${CANDIDATES[@]}" | awk '!seen[$0]++')

if ! command -v sbctl >/dev/null 2>&1; then
  echo "sbctl not found"
  exit 1
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "No SteamOS/EFI loaders found. Mount ESP and try again."
  exit 1
fi

if command -v dialog >/dev/null 2>&1; then
  MENU_ITEMS=()
  i=1
  for c in "${CANDIDATES[@]}"; do
    MENU_ITEMS+=("$i" "$c")
    i=$((i+1))
  done
  CHOICE=$(dialog --stdout --menu "Select SteamOS/EFI loader to sign" 0 0 0 "${MENU_ITEMS[@]}")
  [ -z "$CHOICE" ] && exit 0
  TARGET="${CANDIDATES[$((CHOICE-1))]}"
else
  TARGET="${CANDIDATES[0]}"
fi

echo "Signing: $TARGET"
sbctl sign -s "$TARGET"
echo "Done. If this is your first time with SB, this was required."
EOF

# ============================================================================
# 12) helper: generic EFI signer (warn on Windows but allow)
# ============================================================================
echo "[+] writing airootfs/usr/local/sbin/deck-sign-efi.sh"
cat > airootfs/usr/local/sbin/deck-sign-efi.sh <<'EOF'
#!/bin/bash
set -e

SEARCH_ROOTS=(/boot /boot/efi /efi /mnt)

CANDS=()
for r in "${SEARCH_ROOTS[@]}"; do
  [ -d "$r" ] || continue
  while IFS= read -r -d '' f; do
    CANDS+=("$f")
  done < <(find "$r" -maxdepth 6 -type f -iname "*.efi" -print0 2>/dev/null)
done

mapfile -t CANDS < <(printf "%s\n" "${CANDS[@]}" | awk '!seen[$0]++')

if ! command -v sbctl >/dev/null 2>&1; then
  echo "sbctl not found"
  exit 1
fi

if [ "${#CANDS[@]}" -eq 0 ]; then
  echo "No EFI binaries found. Mount the partition where the other OS lives and try again."
  exit 1
fi

if command -v dialog >/dev/null 2>&1; then
  MENU_ITEMS=()
  idx=1
  for c in "${CANDS[@]}"; do
    MENU_ITEMS+=("$idx" "$c")
    idx=$((idx+1))
  done
  CHOICE=$(dialog --stdout --menu "Select EFI to sign (other Linuxes etc)" 0 0 0 "${MENU_ITEMS[@]}")
  [ -z "$CHOICE" ] && exit 0
  TARGET="${CANDS[$((CHOICE-1))]}"
else
  TARGET="${CANDS[0]}"
fi

IS_WIN=0
case "$TARGET" in
  */EFI/Microsoft/Boot/*|*/efi/microsoft/boot/*|*/bootmgfw.efi|*/BOOTMGFW.EFI)
    IS_WIN=1
    ;;
esac

if [ "$IS_WIN" -eq 1 ]; then
  if command -v dialog >/dev/null 2>&1; then
    dialog --yesno "This looks like a Windows EFI loader.\nWindows already trusts Microsoft keys, so signing this is not usually recommended.\nContinue anyway?" 12 70 || exit 0
  else
    echo "WARNING: This looks like Windows EFI. Normally you don't sign this. Continue? [y/N]"
    read -r ans
    case "$ans" in
      y|Y) ;;
      *) exit 0 ;;
    esac
  fi
fi

echo "Signing: $TARGET"
sbctl sign -s "$TARGET"
echo "Done."
EOF

# ============================================================================
# 13) dialog menu (updated order + pending status)
# ============================================================================
echo "[+] writing airootfs/root/menu.sh"
cat > airootfs/root/menu.sh <<'EOF'
#!/bin/bash
set -e
export DIALOGRC=/root/.dialogrc

pending_flag() {
  if [ -f /run/sb_pending_reboot ]; then
    echo " (pending reboot)"
  else
    echo ""
  fi
}

check_boot_status() {
  local MSG=""
  if [[ -d /sys/firmware/efi ]]; then
    MSG+="UEFI: YES\n"
  else
    MSG+="UEFI: NO\n"
  fi

  if mountpoint -q /sys/firmware/efi/efivars; then
    MSG+="efivars: mounted\n"
  else
    MSG+="efivars: NOT mounted\n"
  fi

  if command -v sbctl >/dev/null 2>&1; then
    MSG+="\n--- sbctl status ---\n"
    MSG+=$(sbctl status 2>&1 || true)
  else
    MSG+="sbctl not found\n"
  fi

  if [ -f /run/sb_pending_reboot ]; then
    MSG+="\nA change was made to Secure Boot variables. Reboot to apply.\n"
  fi

  MSG+="\nIf this Deck has never run SteamOS under Secure Boot before, you will need to sign the SteamOS loader after enabling SB.\n"

  dialog --msgbox "$MSG" 22 90
}

enroll_keys() {
  OUT="$(/usr/local/sbin/deck-enroll.sh 2>&1 || true)"
  dialog --msgbox "$OUT" 20 80
}

unenroll_keys() {
  OUT="$(/usr/local/sbin/deck-unenroll.sh 2>&1 || true)"
  dialog --msgbox "$OUT" 20 80
}

sign_steamos() {
  OUT="$(/usr/local/sbin/deck-sign-steamos.sh 2>&1 || true)"
  dialog --msgbox "$OUT" 20 90
}

sign_other_efi() {
  OUT="$(/usr/local/sbin/deck-sign-efi.sh 2>&1 || true)"
  dialog --msgbox "$OUT" 20 90
}

open_shell() {
  clear
  echo "======================================================="
  echo " Steam Deck Secure Boot ISO - Root Shell"
  echo " ------------------------------------------------------"
  echo " To go back to the menu, type:  /root/menu.sh"
  echo " (A USB keyboard is usually required here.)"
  echo "======================================================="
  exec /bin/bash
}

main_menu() {
  while true; do
    PENDING="$(pending_flag)"
    CHOICE=$(dialog --clear --stdout \
      --backtitle "Steam Deck Secure Boot" \
      --title "Main Menu" \
      --menu "Select an action" 0 0 0 \
      1 "Check Boot Status${PENDING}" \
      2 "Enroll / Enable Secure Boot" \
      3 "Sign SteamOS / Deck loader" \
      4 "Sign another EFI (Ubuntu/Mint/etc)" \
      5 "Open root shell (requires USB keyboard)" \
      6 "--------------------------------" \
      7 "Reboot" \
      8 "Poweroff" \
      9 "Unenroll / Disable Secure Boot") || exit 0

    case "$CHOICE" in
      1) check_boot_status ;;
      2) enroll_keys ;;
      3) sign_steamos ;;
      4) sign_other_efi ;;
      5) open_shell ;;
      6) : ;;  # spacer
      7) reboot ;;
      8) poweroff ;;
      9) unenroll_keys ;;
    esac
  done
}

main_menu
EOF

# ============================================================================
# 14) systemd hook
# ============================================================================
echo "[+] writing airootfs/etc/systemd/system/deck-startup.service"
mkdir -p airootfs/etc/systemd/system
cat > airootfs/etc/systemd/system/deck-startup.service <<'EOF'
[Unit]
Description=Steam Deck SB background init
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/root/runme.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ============================================================================
# 15) customize_airootfs.sh
# ============================================================================
echo "[+] writing airootfs/root/customize_airootfs.sh"
cat > airootfs/root/customize_airootfs.sh <<'EOF'
#!/bin/bash
set -e

chmod +x /root/runme.sh /root/menu.sh \
  /usr/local/sbin/deck-enroll.sh \
  /usr/local/sbin/deck-unenroll.sh \
  /usr/local/sbin/deck-sign-steamos.sh \
  /usr/local/sbin/deck-sign-efi.sh \
  /root/.dialogrc

systemctl enable deck-startup.service

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<'EOC'
[Service]
ExecStart=
ExecStart=-/usr/bin/env bash -c 'export DIALOGRC=/root/.dialogrc; exec /root/menu.sh'
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

# ============================================================================
# 16) build ISO
# ============================================================================
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
echo "[+] keys are hardcoded in this script and in the ISO at /usr/share/deck-sb/keys/"
