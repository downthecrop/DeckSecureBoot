# Steam Deck Secure Boot ISO (Archiso)
**Status:** Beta 1.6

This project builds an Arch-based live ISO for the Steam Deck (LCD and OLED) that:

- boots straight to a menu on the Deck
- lets you **install** Secure Boot keys (our baked keys + Microsoft)
- lets you **sign** SteamOS or any other EFI loader so it still boots with Secure Boot ON
- can itself be **re-signed** after the build so you can boot it even when the Deck is already secure-booted

## Features

- Enables Secure Boot end to end on the Deck without losing recovery paths
- Keeps SteamOS fully launchable while Secure Boot stays enabled
- Supports every Steam Deck hardware revision (LCD and OLED)
- Compatible with Clover Bootloader workflows
- Key safety baked in: you cannot lock yourself out of disabling Secure Boot if keys go missing
- Presents a true, valid Secure Boot chain so Windows anti-cheat software treats the deck as compliant

This is heavily inspired by / a practical follow-up to:
👉 **https://github.com/ryanrudolfoba/SecureBootForSteamDeck**
His work showed the steps. This repo just automates them into an ISO.

## How to use it

1. **Get the ISO** – grab the latest release artifact or build it yourself with `build.sh` (see “Building it yourself”).
2. **Flash to USB** – use Balena Etcher (recommended) or any dd-like tool to write the image to a USB drive.
3. **Boot the Deck** – plug the USB in, hold `Vol-` + `Power`, and pick the USB device from the boot selector.
4. **Run the menu** – the ISO boots straight into the ncurses menu where you can enroll keys, sign loaders, rerun the EFI installer, or disable Secure Boot later.

## How this works

The Deck never shows a “turn on Secure Boot” toggle inside its UEFI UI, but Valve ships it in **setup mode**. Setup mode means the firmware happily accepts new Platform Keys (PK), Key Exchange Keys (KEK), and db signatures without user prompts. When you pick the enrollment option in our menu, we drop the baked keys (plus Microsoft’s) into the firmware variables. As soon as the PK lands, the firmware automatically flips Secure Boot to **enabled**. Later, if you use the disable/unenroll option, we clear those vars; once the PK is gone the Deck re-enters setup mode and Secure Boot is **automatically disabled** again. No hidden switches involved—just key presence or absence.

## Helpful information & FAQ

- **Clover note:** Clover removes the Deck SB Jump loader entry from the Deck’s Boot Manager (`Vol-` + `Power`). Use `Vol+` + `Power`, pick **Boot From File**, then load `/efi/deck-sb/jump.efi` to chainload it manually.
- **Signing other OSes:** Any EFI loader or kernel you want to boot with Secure Boot enabled must be signed. Use the Signing Utility to add signatures for every distro you keep on the internal drive.
- **GRUB Secure Boot policy warnings:** Some distros ship GRUB with `grubshim`, which complains under Secure Boot because it expects Microsoft’s shim chain. That’s why we rely on our custom jump loader instead.

**Does this modify SteamOS?**  We drop a tiny systemd service whose only job is to ensure the Deck SB bootloader entry gets re-added if SteamOS updates wipe it. The OS rootfs, kernel, and userspace remain untouched.

**Will updates still work under Secure Boot?**  Yes. SteamOS keeps its original GRUB entry and kernel images in the EFI partition. The Deck SB entry simply reuses those signed assets, so system updates keep flowing normally.

**SteamOS stopped booting under Secure Boot!**  A recent SteamOS update probably bumped the kernel or initrd filenames. Re-run the EFI installer option from the menu; it re-parses the official SteamOS GRUB config and refreshes the arguments so the Deck SB loader tracks the new assets automatically.

---

## Repo layout

Each moving part lives in its own directory so builds stay reproducible and easy to audit:

- `build.sh` – single entry point that prepares an Archiso workdir, copies our profile, injects payload + keys, and (optionally) calls the resigner when it sits next to the builder.
- `profile/` – trimmed Archiso baseline overrides (mainly `profiledef.sh`, EFI bits, pacman.conf). This folder mirrors what ends up under `/usr/share/archiso/configs/...`.
- `payload/` – everything that lands inside the live image. `payload/root/menu.sh` drives the ncurses UI, the `deck-*.sh` helpers enroll/unenroll/sign, and `payload/etc/systemd/system/deck-startup.service` re-adds the Deck SB boot entry if updates wipe it.
- `keys/` – the baked Secure Boot keys (`PK.pem`/`PK.key`). `build.sh` mirrors them to `/usr/share/deck-sb/keys` and `/var/lib/sbctl/` during the image build.
- `resigner.sh` – optional post-build helper that re-signs the hidden ISO EFI image so the ISO still boots after the Deck trusts these keys.

Keeping these pieces separate makes it easier to audit changes, swap payload bits, or point the builder at a different Archiso profile via environment variables.

---

## What you get

- A live ISO that understands the Deck’s UEFI
- A ncurses menu with:
  1. **Check Boot Status** (UEFI? efivars? secureboot?)
  2. **Enroll / Enable Secure Boot** (runs `sbctl enroll-keys -m` with our baked keys)
  3. **Signing Utility** (sign SteamOS or any other EFI loader in one place)
  5. **Root shell**
  7. **Reboot / Poweroff**
  9. **Unenroll / Disable Secure Boot**
- Keys baked into the image in **two** places:
  - `/usr/share/deck-sb/keys/...` (nice and obvious)
  - `/var/lib/sbctl/...` (what modern `sbctl` expects)
- A fixed sbctl GUID so the layout is stable:
  - `decdecde-dec0-4dec-adec-decdecdecdec`
- Optional post-build **resigner** to re-sign the ISO’s embedded EFI image, so the ISO boots even after you enable Secure Boot with these keys

---

## Why you sometimes need to sign SteamOS (or other OSes)

Secure Boot is simple but strict: **the firmware will only run binaries signed by keys it trusts.**

What this ISO does when you pick “Enroll / Enable Secure Boot”:

1. installs **our** key set (the ones below)
2. installs **Microsoft** production UEFI keys (so Windows and lots of vendor stuff still works)
3. tells firmware “we’re done, leave setup mode”

After that:
- anything signed by Microsoft → OK
- anything signed by **our** keys → OK
- anything not signed → **blocked**

SteamOS and other Linux installs often ship **unsigned** or **signed with somebody else’s key**, so the firmware doesn’t know to trust it. The Signing Utility entry simply takes the EFI binary you point at (SteamOS or anything else) and **adds our signature** so it passes Secure Boot with our key.

**Important:** if later you **disable** Secure Boot or clear vars, you do **not** have to “unsign” SteamOS or anything else. Signatures are just extra data. If Secure Boot is off, the firmware ignores them.

---

## Keys we use (baked, public on purpose)

We all use the same keys so nobody bricks themselves permanently. These are the same ones we embed into the ISO:

<details>
<summary>Show baked keys</summary>

**PK.key**
```text
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
```

**PK.pem**
```text
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
XWAMVeMcFROs06tcSubxqdAKa4INMyVVklGslIT/z3CkLR5q9QV5SgI4Z3sRzAmL
PUKOoWc4x6op2heyxujlLwwiZouXWHqaklSaUymae9mCPUtwPg135WNc+E2BC4Ep
eU5IzhUe8nLj4wlWQoxdBsKWhuvsVJVEWs/HkzPrwulIAHQSb/divYe3eTrYKfib
gXnR8BtFo0R8QGTtodx6d7nu1QO3275yvHAZTr3bfygs5AkSHF9oqpaUPAOyPM4c
OyHXIWSLcl2GuAJnBoSR3rKgFvvr
-----END CERTIFICATE-----
```

We mirror these inside the ISO to KEK/db so we can also *clear* secure boot later.
</details>

---

## The resigner (important)

**Problem:** after enrolling these keys on the Deck, the freshly built ISO might not boot anymore — because the EFI image inside the ISO isn’t signed with *these* keys.

**Solution:** `resigner.sh` patches the hidden EFI image inside the ISO:

1. find the El Torito UEFI image
2. extract it
3. sign `EFI/BOOT/BOOTx64.EFI` (and IA32 if present) with the baked keys
4. write it back
5. produce `*-signed.iso`

Usage:

```bash
./resigner.sh archlinux-steamdeck-sb-latest-x86_64.iso
# -> archlinux-steamdeck-sb-latest-x86_64-signed.iso
```

The main builder will auto-run this if `resigner.sh` sits next to it. If not, it prints:

```text
[!] ISO WILL NOT BOOT under your Secure Boot keys unless you run the resigner manually.
```

You can also point the resigner at other similar ISOs to make them bootable under these keys.

> **Heads-up:** `resigner.sh` rewrites the hidden EFI boot image inside the ISO at its original byte offset. On rare ISOs that pack data immediately after that blob, the rewrite can corrupt the file. If it happens, pad the ISO with a little dummy data (e.g., `truncate -s +1M your.iso`) and rerun the resigner so the EFI image has breathing room.

---

## Building it yourself

1. Use an Arch install or Arch container (the builder shells out to `pacman`, `mkarchiso`, etc.).
2. Install `archiso`, `grub`, `sbctl`, `sbsigntools` (the script auto-installs them if you run it as root on Arch).
3. Run `sudo ./build.sh` from the repo root. It stages the profile, payload, and keys automatically and drops finished ISOs in `./out/` (or `/out` if that directory exists).

The builder writes ISOs to `/out` when that directory exists (handy inside containers) or `./out/` otherwise. When `resigner.sh` sits next to `build.sh`, the ISO is automatically re-signed and you’ll get both `*.iso` and `*-signed.iso` outputs.

## Building from source (quickstart)

```bash
git clone https://github.com/downthecrop/DeckSecureBoot.git
cd DeckSecureBoot

# optional: prep an output directory the container can write to
mkdir -p ./iso-out

# launch an Arch Linux build shell
docker run --rm -it \
  --platform=linux/amd64 \
  --privileged \
  -v $(pwd):/work \
  -v $(pwd)/iso-out:/out \
  archlinux:latest \
  /bin/bash
```

Inside the container:

```bash
cd /work
pacman -Syu --needed archiso grub sbctl sbsigntools
sudo ./build.sh   # finished artifacts land in /out → ./iso-out on the host
```

Need to regenerate the signed Deck jump loader? Run `./makeefi.sh` (or `./makeefi`) and drop the refreshed `steamos-jump.signed.efi` back into `payload/root/deck-sb-files/` before rebuilding.

---

## Booting it on the Deck

1. Power off Deck
2. Hold **Volume -** and press **Power**
3. Pick the USB you flashed the ISO to
4. Menu shows up and lets you enroll, sign, or disable Secure Boot

You can also copy the ISO contents to a bootable partition and boot it locally if you don’t want to keep a USB around.

---

## Credits

- Original method / research: **@ryanrudolfoba**  
  https://github.com/ryanrudolfoba/SecureBootForSteamDeck
