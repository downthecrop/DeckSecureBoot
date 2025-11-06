# Alpine Steam Deck Secure Boot ISO

This repo describes how to build a small Alpine-based ISO (x86_64) that boots on **BIOS and UEFI** and already contains the tools used in the “Enable Secure Boot for Steam Deck” guide.

The idea is simple:

- we don’t change Alpine’s build system
- we just add the packages we need
- we let Alpine’s `mkimage.sh` do all the ISO + hybrid boot magic

That makes the ISO reproducible and easy to audit.

## What this ISO is for

The original Steam Deck secure boot guide expects you to:

1. install a Linux distro on the Deck (Fedora, Ubuntu, etc.)
2. install/build `sbctl`
3. enroll PK/KEK/db
4. optionally revert using `efitools`
5. inspect with `mokutil`

We just put those tools **in the live environment** so you can do the key work right away.

## Custom profile

Save this as `mkimg.steamdeck-sb.sh`:

```sh
profile_steamdeck_sb() {
    profile_standard
    apks="$apks sbctl efitools mokutil e2fsprogs-extra git"
}
profile_steamdeck_sb
```

### Why these packages?

- **sbctl** – main tool in the guide for generating and enrolling Secure Boot keys and signing EFI binaries.
- **efitools** – provides `efi-updatevar` to clear PK/KEK/db when reverting.
- **mokutil** – to query PK, KEK, and DB to confirm enrollment.
- **e2fsprogs-extra** – for `chattr`, used to remove the immutable bit on efivars.
- **git** – convenient if you want to pull the original guide while in the live ISO.

Everything else (kernel, initramfs, bootloader setup, hybrid ISO) is inherited from Alpine’s `profile_standard`.

## Reproducible build steps

Run on your host:

```bash
docker run --rm -it --platform=linux/amd64 -w /work alpine:edge sh
```

Inside the container:

```sh
apk update
apk add git abuild alpine-conf syslinux xorriso squashfs-tools grub-efi mtools dosfstools mkinitfs ca-certificates

abuild-keygen -a
cp /root/.abuild/*.pub /etc/apk/keys/

cd /work
git clone --depth=1 https://git.alpinelinux.org/aports

adduser -D builder
addgroup builder abuild
chown -R builder:builder /work
```

Now as `builder`:

```sh
su - builder
cd /work/aports/scripts
cat > mkimg.steamdeck-sb.sh <<'EOF'
profile_steamdeck_sb() {
    profile_standard
    apks="$apks sbctl efitools mokutil e2fsprogs-extra git"
}
profile_steamdeck_sb
EOF
exit
```

Give the builder user the signing key (back as root):

```sh
mkdir -p /home/builder/.abuild
cp /root/.abuild/*.rsa /home/builder/.abuild/
cp /root/.abuild/*.pub /home/builder/.abuild/
chown -R builder:builder /home/builder/.abuild
```

Build the ISO (as builder again):

```sh
su - builder
cd /work/aports/scripts
export PACKAGER_PRIVKEY=/home/builder/.abuild/<your-key>.rsa
export PACKAGER="builder <builder@localhost>"
./mkimage.sh   --tag edge   --arch x86_64   --repository https://dl-cdn.alpinelinux.org/alpine/edge/main   --repository https://dl-cdn.alpinelinux.org/alpine/edge/community   --profile steamdeck_sb   --outdir /work/out
```

The ISO will be in `/work/out/`.

## Notes

- We used **Alpine edge** so we get a newer `sbctl` that matches the 2025 note about keys being in `/var/lib/sbctl/keys/...`.
- Because this is a thin wrapper around `profile_standard`, anyone can audit it easily: it’s just an Alpine ISO with a few extra packages installed at build time.
- To distribute: publish this README, the `mkimg.steamdeck-sb.sh`, and optionally a small `build.sh` that runs these commands in a container.
