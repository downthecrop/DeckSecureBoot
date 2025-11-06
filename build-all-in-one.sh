#!/bin/sh
set -e

APK_REPO_MAIN="https://dl-cdn.alpinelinux.org/alpine/edge/main"
APK_REPO_COMM="https://dl-cdn.alpinelinux.org/alpine/edge/community"
WORKDIR="/work"
PROFILE_SCRIPT="mkimg.steamdeck-sb.sh"
BUILDER_USER="builder"
APKOVL="$WORKDIR/steamdeck-overlay.apkovl.tar.gz"

echo "[+] starting build (with profile-defined apkovl)"

# 1) deps
if ! command -v git >/dev/null 2>&1; then
  echo "[+] installing packages..."
  apk update
  apk add git abuild alpine-conf syslinux xorriso squashfs-tools grub-efi mtools dosfstools mkinitfs ca-certificates
else
  echo "[=] base packages already present"
fi

# 2) abuild key (root)
if [ ! -d /root/.abuild ] || ! ls /root/.abuild/*.rsa >/dev/null 2>&1; then
  echo "[+] generating abuild key..."
  abuild-keygen -a
else
  echo "[=] abuild key already exists"
fi
cp /root/.abuild/*.pub /etc/apk/keys/ 2>/dev/null || true

# 3) clone aports if missing
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d "$WORKDIR/aports" ]; then
  echo "[+] cloning aports..."
  git clone --depth=1 https://git.alpinelinux.org/aports
else
  echo "[=] aports already present"
fi

# 4) ensure builder user exists
if ! id "$BUILDER_USER" >/dev/null 2>&1; then
  echo "[+] creating builder user..."
  adduser -D "$BUILDER_USER"
  addgroup "$BUILDER_USER" abuild
else
  echo "[=] builder user already exists"
fi

# make sure /work is owned by builder
chown -R "$BUILDER_USER":"$BUILDER_USER" "$WORKDIR"

# 5) ALWAYS rebuild overlay
echo "[+] building overlay..."
OVERLAY_DIR="$WORKDIR/overlay"
rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR/etc/profile.d" "$OVERLAY_DIR/etc"

cat > "$OVERLAY_DIR/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty1::respawn:/sbin/getty -a root 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

cat > "$OVERLAY_DIR/etc/profile.d/steamdeck-autoexec.sh" <<'EOF'
#!/bin/sh
echo "hello world from steamdeck alpine ISO"
EOF
chmod +x "$OVERLAY_DIR/etc/profile.d/steamdeck-autoexec.sh"

(
  cd "$OVERLAY_DIR"
  tar -czf "$APKOVL" .
)

# 6) write profile that points at the overlay
PROFILE_PATH="$WORKDIR/aports/scripts/$PROFILE_SCRIPT"
echo "[+] writing profile to $PROFILE_PATH"
cat > "$PROFILE_PATH" <<EOF
profile_steamdeck_sb() {
    profile_standard
    apks="\$apks sbctl efitools mokutil e2fsprogs-extra git"
    apkovl="$APKOVL"
}
profile_steamdeck_sb
EOF

# 7) copy the signing key to builder *as root* so builder can use it
echo "[+] copying abuild keys to builder..."
mkdir -p /home/$BUILDER_USER/.abuild
cp /root/.abuild/*.rsa /home/$BUILDER_USER/.abuild/
cp /root/.abuild/*.pub /home/$BUILDER_USER/.abuild/
chown -R $BUILDER_USER:$BUILDER_USER /home/$BUILDER_USER/.abuild

# 8) run mkimage as builder
echo "[+] building ISO as $BUILDER_USER..."
su - "$BUILDER_USER" <<EOF
set -e
cd $WORKDIR/aports/scripts

export PACKAGER_PRIVKEY=\$(ls /home/$BUILDER_USER/.abuild/*.rsa | head -n1)
export PACKAGER="$BUILDER_USER <builder@localhost>"

./mkimage.sh \
  --tag edge \
  --arch x86_64 \
  --repository $APK_REPO_MAIN \
  --repository $APK_REPO_COMM \
  --profile steamdeck_sb \
  --outdir $WORKDIR/out
EOF

echo "[+] done. ISO in $WORKDIR/out"
