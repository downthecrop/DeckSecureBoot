#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Steam Deck Secure Boot ISO builder (plain ncurses)
# Version: Beta 1.6
#
# - Archiso baseline -> custom profile
# - UEFI + systemd-boot only
# - Baked sbctl keys in TWO places:
#     /usr/share/deck-sb/keys
#     /var/lib/sbctl/keys/... (new sbctl layout)
# - Fixed sbctl GUID: decdecde-dec0-4dec-adec-decdecdecdec
# - Boots straight into /root/menu.sh
# - systemd-boot hidden (timeout 0) to avoid portrait menu
# - If ./resigner.sh is present beside this script, we post-process the ISO
#   to sign the hidden EFI image (the method we proved works)
# - EFI signers now:
#     * skip our own ISO mount (/run/archiso/bootmnt/…)
#     * label likely OS
#     * error out cleanly if not root
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
WORKDIR=${WORKDIR:-/root/archlive}
PROFILENAME=${PROFILENAME:-steamdeck-sb}
PROFILE_SRC=/usr/share/archiso/configs/baseline
PROFILE_DIR=${PROFILE_DIR:-"$SCRIPT_DIR/profile"}
PAYLOAD_DIR=${PAYLOAD_DIR:-"$SCRIPT_DIR/payload"}
KEYS_DIR=${KEYS_DIR:-"$SCRIPT_DIR/keys"}
FIXED_GUID="decdecde-dec0-4dec-adec-decdecdecdec"
RESIGNER="$SCRIPT_DIR/resigner.sh"
RESIGN_WARN='[!] ISO WILL NOT BOOT under your Secure Boot keys unless you run the resigner manually.'

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

echo "[+] Steam Deck SB ISO build (Beta 1.6)"
echo "[+] workdir     : $WORKDIR"
echo "[+] profile dir : $PROFILE_DIR"
echo "[+] payload dir : $PAYLOAD_DIR"
echo "[+] keys dir    : $KEYS_DIR"

for dir in "$PROFILE_DIR" "$PAYLOAD_DIR" "$KEYS_DIR"; do
  if [ ! -d "$dir" ]; then
    echo "[!] required directory missing: $dir"
    exit 1
  fi
done

for key_file in "$KEYS_DIR/PK.key" "$KEYS_DIR/PK.pem"; do
  if [ ! -f "$key_file" ]; then
    echo "[!] missing key file: $key_file"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1) install host deps if missing
# ---------------------------------------------------------------------------
ensure_pkg() {
  local pkg="$1"
  if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
    pacman -Sy --noconfirm "$pkg"
  fi
}

ensure_pkg archiso
ensure_pkg grub
ensure_pkg sbctl
ensure_pkg sbsigntools

# ---------------------------------------------------------------------------
# 2) prepare working profile
# ---------------------------------------------------------------------------
mkdir -p "$WORKDIR"
cd "$WORKDIR"
rm -rf "$PROFILENAME" || true
cp -r "$PROFILE_SRC" "$PROFILENAME"
cd "$PROFILENAME"

# ---------------------------------------------------------------------------
# 3) profiledef.sh
# ---------------------------------------------------------------------------
cp "$PROFILE_DIR/profiledef.sh" profiledef.sh

# ---------------------------------------------------------------------------
# 4) package trimming / adding
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

# add desired
for pkg in "${ISO_EXTRA_PKGS[@]}"; do
  if ! grep -qx "$pkg" "$tmpfile"; then
    echo "$pkg" >> "$tmpfile"
  fi
done

mv "$tmpfile" packages.x86_64

# ---------------------------------------------------------------------------
# 5) UEFI/systemd-boot (with loader.conf timeout 0)
# ---------------------------------------------------------------------------
mkdir -p efiboot
cp -r "$PROFILE_DIR/efiboot/." efiboot/

mkdir -p efiboot/EFI/systemd efiboot/EFI/BOOT
if [ -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi ]; then
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi efiboot/EFI/systemd/systemd-bootx64.efi
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi efiboot/EFI/BOOT/BOOTX64.EFI
else
  echo "[!] /usr/lib/systemd/boot/efi/systemd-bootx64.efi not found on host; ISO will still build."
fi

# ---------------------------------------------------------------------------
# 6) ship payload (menus, helper scripts, units)
# ---------------------------------------------------------------------------
mkdir -p airootfs
cp -a "$PAYLOAD_DIR"/. airootfs/

chmod +x \
  airootfs/root/menu.sh \
  airootfs/root/customize_airootfs.sh \
  airootfs/root/deck-enroll.sh \
  airootfs/root/deck-unenroll.sh \
  airootfs/root/deck-sign-efi.sh \
  airootfs/root/deck-install-jump.sh

# ---------------------------------------------------------------------------
# 7) baked keys (two places)
# ---------------------------------------------------------------------------
share_keys_dir=airootfs/usr/share/deck-sb/keys
sbctl_keys_dir=airootfs/var/lib/sbctl/keys

for slot in PK KEK db; do
  install -Dm600 "$KEYS_DIR/PK.key" "$share_keys_dir/${slot}.key"
  install -Dm644 "$KEYS_DIR/PK.pem" "$share_keys_dir/${slot}.pem"
done

install -Dm600 "$KEYS_DIR/PK.key" "$sbctl_keys_dir/PK/PK.key"
install -Dm644 "$KEYS_DIR/PK.pem" "$sbctl_keys_dir/PK/PK.pem"
install -Dm600 "$KEYS_DIR/PK.key" "$sbctl_keys_dir/KEK/KEK.key"
install -Dm644 "$KEYS_DIR/PK.pem" "$sbctl_keys_dir/KEK/KEK.pem"
install -Dm600 "$KEYS_DIR/PK.key" "$sbctl_keys_dir/db/db.key"
install -Dm644 "$KEYS_DIR/PK.pem" "$sbctl_keys_dir/db/db.pem"

mkdir -p airootfs/var/lib/sbctl
echo -n "$FIXED_GUID" > airootfs/var/lib/sbctl/GUID

# ---------------------------------------------------------------------------
# 8) build ISO
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

# ---------------------------------------------------------------------------
# 9) optional post-build resign
# ---------------------------------------------------------------------------
if [ -n "${ISO_PATH:-}" ] && [ -f "$RESIGNER" ]; then
  echo "[+] found resigner at $RESIGNER - signing ISO EFI image..."
  if "$RESIGNER" "$ISO_PATH"; then
    SIGNED_PATH="${ISO_PATH%.iso}-signed.iso"
    if [ -f "$SIGNED_PATH" ]; then
      echo "[+] resign successful -> $SIGNED_PATH"
    else
      echo "[!] resigner ran but no signed ISO found at expected path: $SIGNED_PATH"
      echo "$RESIGN_WARN"
    fi
  else
    echo "[!] resigner failed to run."
    echo "$RESIGN_WARN"
  fi
else
  echo "[!] resigner.sh not found next to this builder (expected: $RESIGNER)"
  echo "$RESIGN_WARN"
fi
