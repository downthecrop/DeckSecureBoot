#!/bin/sh
set -e

# --- config -------------------------------------------------------
APK_REPO_MAIN="https://dl-cdn.alpinelinux.org/alpine/edge/main"
APK_REPO_COMM="https://dl-cdn.alpinelinux.org/alpine/edge/community"
WORKDIR="/work"

BUILDER_USER="builder"
BUILDER_HOME="$WORKDIR/builder"
BUILDER_MKIMG_DIR="$BUILDER_HOME/.mkimage"

PROFILE_SCRIPT="mkimg.steamdeck-sb.sh"
APKOVL_GEN_SCRIPT="genapkovl-steamdeck-sb.sh"
# ------------------------------------------------------------------

echo "[+] starting build (mkimage-style apkovl)"

# 1) deps
if ! command -v git >/dev/null 2>&1; then
  apk update
  apk add git abuild alpine-conf syslinux xorriso squashfs-tools grub-efi mtools dosfstools mkinitfs ca-certificates
fi

# 2) abuild key
if [ ! -d /root/.abuild ] || ! ls /root/.abuild/*.rsa >/dev/null 2>&1; then
  abuild-keygen -a
fi
cp /root/.abuild/*.pub /etc/apk/keys/ 2>/dev/null || true

# 3) clone aports
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d "$WORKDIR/aports" ]; then
  git clone --depth=1 https://git.alpinelinux.org/aports
fi

# 4) builder user in /work
if ! id "$BUILDER_USER" >/dev/null 2>&1; then
  adduser -D -h "$BUILDER_HOME" "$BUILDER_USER"
  addgroup "$BUILDER_USER" abuild
fi
mkdir -p "$BUILDER_MKIMG_DIR"
chown -R "$BUILDER_USER:$BUILDER_USER" "$WORKDIR"

# 5) apkovl generator script (mkimage will run this under fakeroot)
APKOVL_PATH="$WORKDIR/aports/scripts/$APKOVL_GEN_SCRIPT"
cat > "$APKOVL_PATH" <<'EOF'
#!/bin/sh
set -e

out="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/etc" "$tmp/etc/profile.d"

cat > "$tmp/etc/inittab" <<'EOT'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty1::respawn:/sbin/getty -a root 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOT

cat > "$tmp/etc/profile.d/steamdeck-autoexec.sh" <<'EOT'
#!/bin/sh
echo "hello world from steamdeck alpine ISO"
EOT
chmod +x "$tmp/etc/profile.d/steamdeck-autoexec.sh"

tar -C "$tmp" -czf "$out" .
EOF
chmod +x "$APKOVL_PATH"
chown "$BUILDER_USER:$BUILDER_USER" "$APKOVL_PATH"

# 5b) mkimage wants it under ~/.mkimage/, and it uses just the filename
cp "$APKOVL_PATH" "$BUILDER_MKIMG_DIR/$APKOVL_GEN_SCRIPT"
chmod +x "$BUILDER_MKIMG_DIR/$APKOVL_GEN_SCRIPT"
chown -R "$BUILDER_USER:$BUILDER_USER" "$BUILDER_MKIMG_DIR"

# 6) mkimage profile — point to just the script name
PROFILE_PATH="$WORKDIR/aports/scripts/$PROFILE_SCRIPT"
cat > "$PROFILE_PATH" <<EOF
profile_steamdeck_sb() {
    profile_standard
    apks="\$apks sbctl efitools mokutil e2fsprogs-extra git"
    # IMPORTANT: just the filename, because mkimage copies/looks in ~/.mkimage
    apkovl="$APKOVL_GEN_SCRIPT"
}
profile_steamdeck_sb
EOF
chown "$BUILDER_USER:$BUILDER_USER" "$PROFILE_PATH"

# 7) give builder the signing key
mkdir -p "$BUILDER_HOME/.abuild"
cp /root/.abuild/*.rsa "$BUILDER_HOME/.abuild/" 2>/dev/null || true
cp /root/.abuild/*.pub "$BUILDER_HOME/.abuild/" 2>/dev/null || true
chown -R "$BUILDER_USER:$BUILDER_USER" "$BUILDER_HOME/.abuild"

# 8) relax perms so fakeroot doesn’t choke
chmod -R 777 "$WORKDIR"

# 9) run mkimage as builder
su - "$BUILDER_USER" <<EOF
set -e
cd $WORKDIR/aports/scripts
export PACKAGER_PRIVKEY=\$(ls $BUILDER_HOME/.abuild/*.rsa | head -n1)
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

