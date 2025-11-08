#!/usr/bin/env bash
set -euo pipefail

# set FORCE_REBUILD=1 ./makeefi.sh to force a clean rebuild
FORCE_REBUILD="${FORCE_REBUILD:-0}"

KEY_DIR="keys"
PK_KEY="${KEY_DIR}/PK.key"
PK_CRT="${KEY_DIR}/PK.pem"

OUT_DIR="dist"
OUT_EFI="${OUT_DIR}/steamos-jump.signed.efi"

# pin to the working grub
GRUB_COMMIT="2bc0929a2fffbb60995605db6ce46aa3f979a7d2"

BUILD_ROOT="$(pwd)/build-grub"
GRUB_SRC="${BUILD_ROOT}/grub"
GRUB_PREFIX="${BUILD_ROOT}/out"
GRUB_MK="${GRUB_PREFIX}/bin/grub-mkstandalone"

install_build_deps() {
  pacman -S --needed --noconfirm \
    git python \
    autoconf automake pkgconf \
    gettext texinfo help2man \
    flex bison libtool \
    make gcc \
    sbsigntools
}

# --- preflight ---
[[ -f "$PK_KEY" ]] || { echo "ERROR: $PK_KEY missing"; exit 1; }
[[ -f "$PK_CRT" ]] || { echo "ERROR: $PK_CRT missing"; exit 1; }

install_build_deps
mkdir -p "$OUT_DIR"

if [[ "$FORCE_REBUILD" == "1" ]]; then
  echo "[*] FORCE_REBUILD=1 -> removing $BUILD_ROOT"
  rm -rf "$BUILD_ROOT"
fi
mkdir -p "$BUILD_ROOT"

# --- fetch grub ---
if [[ ! -d "$GRUB_SRC" ]]; then
  echo "[*] cloning GRUB ..."
  git clone https://git.savannah.gnu.org/git/grub.git "$GRUB_SRC"
fi

cd "$GRUB_SRC"
echo "[*] checking out GRUB commit $GRUB_COMMIT ..."
git fetch origin
git checkout --force "$GRUB_COMMIT"

# --- build grub if needed ---
if [[ ! -x "$GRUB_MK" ]]; then
  echo "[*] patching shim fallback ..."
  # turn "shim protocols not found" into success
  sed -i 's/return grub_error (GRUB_ERR_ACCESS_DENIED, N_("shim protocols not found"));/return GRUB_ERR_NONE;/' \
    grub-core/kern/efi/sb.c

  echo "[*] bootstrap ..."
  ./bootstrap

  echo "[*] configure ..."
  ./configure \
    --with-platform=efi \
    --target=x86_64 \
    --prefix="$GRUB_PREFIX"

  echo "[*] make ..."
  make -j"$(nproc)"

  echo "[*] make install ..."
  make install
else
  echo "[*] grub already built, skipping (use FORCE_REBUILD=1 to rebuild)"
fi

cd - >/dev/null

# --- build the tiny builtin config ---
CFG_FILE="$(mktemp)"
EFI_RAW="$(mktemp)"

cat > "$CFG_FILE" <<'EOF'
set default=0
set timeout=3

# helper: try to source from a given device+path, return if ok
function try_source {
    if [ -f $1 ]; then
        source $1
        return
    fi
}

# 1) best case: firmware gave us the real path it loaded from
#    e.g. (hd0,gpt1)/efi/steamos or (hd0)/EFI/steamos
if [ -n "$cmdpath" ]; then
    set mydir="$cmdpath"
    # try exactly beside us first
    if [ -f $mydir/deck-sb.cfg ]; then
        source $mydir/deck-sb.cfg
        return
    fi

    # sometimes cmdpath is just (hd0)/EFI/steamos (no partition)
    # extract the disk part with regexp
    insmod regexp
    regexp --set=1:disk '^\(([^,)]+)\)/' "$cmdpath"
    if [ -n "$disk" ]; then
        # probe a few likely partitions
        for p in 1 2 3 4 5 6 7 8; do
            # GPT style
            if [ -f ($disk,gpt$p)/efi/steamos/deck-sb.cfg ]; then
                source ($disk,gpt$p)/efi/steamos/deck-sb.cfg
                return
            fi
            if [ -f ($disk,gpt$p)/EFI/steamos/deck-sb.cfg ]; then
                source ($disk,gpt$p)/EFI/steamos/deck-sb.cfg
                return
            fi
            # MBR style
            if [ -f ($disk,msdos$p)/efi/steamos/deck-sb.cfg ]; then
                source ($disk,msdos$p)/efi/steamos/deck-sb.cfg
                return
            fi
            if [ -f ($disk,msdos$p)/EFI/steamos/deck-sb.cfg ]; then
                source ($disk,msdos$p)/EFI/steamos/deck-sb.cfg
                return
            fi
        done
    fi
fi

# 2) fallback: search (lowercase)
search --file /efi/steamos/deck-sb.cfg --set=esp
if [ -n "$esp" ]; then
    source ($esp)/efi/steamos/deck-sb.cfg
    return
fi

# 3) fallback: search (uppercase)
search --file /EFI/steamos/deck-sb.cfg --set=esp
if [ -n "$esp" ]; then
    source ($esp)/EFI/steamos/deck-sb.cfg
    return
fi

menuentry 'Deck SB loader (no config found)' {
    echo 'No deck-sb.cfg found beside this loader or on the ESP.'
    echo 'Run the SB ISO to generate it.'
    sleep 5
}
EOF

echo "[*] building standalone GRUB EFI ..."
"$GRUB_MK" \
  -O x86_64-efi \
  -o "$EFI_RAW" \
  --modules="part_gpt part_msdos fat ext2 search search_fs_file normal efi_gop efi_uga regexp" \
  "boot/grub/grub.cfg=${CFG_FILE}"

echo "[*] signing EFI ..."
sbsign \
  --key "$PK_KEY" \
  --cert "$PK_CRT" \
  --output "$OUT_EFI" \
  "$EFI_RAW"

rm -f "$CFG_FILE" "$EFI_RAW"

echo
echo "[+] built and signed: $OUT_EFI"
echo "Deploy on Deck:"
echo "  sudo mount /dev/nvme0n1p1 /mnt/esp"
echo "  sudo mkdir -p /mnt/esp/efi/steamos"
echo "  sudo cp $OUT_EFI /mnt/esp/efi/steamos/deck-sb-loader.efi"
echo "  sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -l '\\EFI\\steamos\\deck-sb-loader.efi' -L 'Deck SB Loader'"
echo
echo "Then have your ISO write /efi/steamos/deck-sb.cfg (or /EFI/steamos/deck-sb.cfg) on that same ESP."
