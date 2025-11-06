#!/bin/sh
set -e

APK_REPO_MAIN="https://dl-cdn.alpinelinux.org/alpine/edge/main"
APK_REPO_COMM="https://dl-cdn.alpinelinux.org/alpine/edge/community"
WORKDIR="/work"
PROFILE_SCRIPT="mkimg.steamdeck-sb.sh"
BUILDER_USER="builder"

echo "[+] starting build (profile-defined apkovl in builder's .mkimage)"

# 1) deps
if ! command -v git >/dev/null 2>&1; then
  echo "[+] installing packages..."
  apk update
  apk add git abuild alpine-conf syslinux xorriso squashfs-tools grub-efi mtools dosfstools mkinitfs ca-certificates
else
  echo "[=] base packages already present"
fi

# 2) abuild key
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

# 5) build overlay (always)
echo "[+] building overlay..."
OVERLAY_BUILD_DIR="$WORKDIR/overlay"
rm -rf "$OVERLAY_BUILD_DIR"
mkdir -p "$OVERLAY_BUILD_DIR/etc/profile.d" "$OVERLAY_BUILD_DIR/etc"

cat > "$OVERLAY_BUILD_DIR/etc/inittab" <<'EOF'
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

cat > "$OVERLAY_BUILD_DIR/etc/profile.d/steamdeck-autoexec.sh" <<'EOF'
#!/bin/sh
echo "hello world from steamdeck alpine ISO"
EOF
chmod +x "$OVERLAY_BUILD_DIR/etc/profile.d/steamdeck-autoexec.sh"

# create the actual tar.gz
APKOVL_NAME="steamdeck-overlay.apkovl.tar.gz"
APKOVL_PATH="$OVERLAY_BUILD_DIR/$APKOVL_NAME"
(
  cd "$OVERLAY_BUILD_DIR"
  tar -czf "$APKOVL_NAME" .
)

# 6) put the apkovl where mkimage expects it (builder's ~/.mkimage)
echo "[+] staging apkovl into /home/$BUILDER_USER/.mkimage/"
mkdir -p /home/$BUILDER_USER/.mkimage
cp "$APKOVL_PATH" /home/$BUILDER_USER/.mkimage/
chown -R $BUILDER_USER:$BUILDER_USER /home/$BUILDER_USER/.mkimage

# 7) write profile that just names the apkovl (no path)
PROFILE_PATH="$WORKDIR/aports/scripts/$PROFILE_SCRIPT"
echo "[+] writing profile to $PROFILE_PATH"
cat > "$PROFILE_PATH" <<EOF
profile_steamdeck_sb() {
    profile_standard
    apks="\$apks sbctl efitools mokutil e2fsprogs-extra git"
    apkovl="$APKOVL_NAME"
}
profile_steamdeck_sb
EOF

# 8) copy abuild keys to builder (so modloop can be signed)
echo "[+] copying abuild keys to builder..."
mkdir -p /home/$BUILDER_USER/.abuild
cp /root/.abuild/*.rsa /home/$BUILDER_USER/.abuild/
cp /root/.abuild/*.pub /home/$BUILDER_USER/.abuild/
chown -R $BUILDER_USER:$BUILDER_USER /home/$BUILDER_USER/.abuild

# 9) run mkimage as builder
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
