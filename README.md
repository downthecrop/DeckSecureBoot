# Warning (11/14/2025): Deck LCD has Audio Driver issues in Windows under secure boot. Looking into a fix - 

[![](https://github.com/downthecrop/misc/blob/main/branding.png?raw=true)](https://github.com/downthecrop/DeckSecureBoot/releases/latest)
# Steam Deck Secure Boot (Deck SB)
**Status:** Beta 1.6

Arch-based live ISO for Enabling Secure Boot the Steam Deck (LCD and OLED)

[![Download](https://img.shields.io/badge/Download-latest-brightgreen?style=for-the-badge&logo=github)](https://github.com/downthecrop/DeckSecureBoot/releases/latest)


## Features

- Easy to use menu on the Deck (D-Pad navigation)
- Enables Secure Boot without the UEFI exposing the toggle
- Optional disk install to always have access to change SecureBoot status
- Keeps SteamOS fully launchable while Secure Boot stays enabled
- Supports every Steam Deck hardware revision (LCD and OLED)
- Compatible with Clover Bootloader and Dual Boot setups (Windows/SteamOS)
- Key safety baked in: you cannot lock yourself out of disabling Secure Boot
- No tricks. This is valid Secure Boot, Windows anti-cheat software treats the deck as compliant
- Fully reversible

This is heavily inspired by / a practical follow-up to:
👉 **https://github.com/ryanrudolfoba/SecureBootForSteamDeck**
His work showed the steps. This repo automates them into an ISO.

## How to use it

1. **Get the ISO** – Grab the latest release artifact or build it yourself with `build.sh` (see “Building it yourself”).
2. **Flash to USB** – Use Balena Etcher (recommended) or any dd-like tool to write the image to a USB drive.
3. **Boot From USB** – Plug in the USB, hold `Vol-` + `Power`, and pick the USB device from the boot selector.
4. **Run the menu** – the ISO boots into a menu where you can enroll keys, sign loaders, rerun the EFI installer, or disable Secure Boot later.

![](https://github.com/downthecrop/misc/blob/main/CleanShot%202025-11-13%20at%2013.05.19%20(1).png?raw=true)

## How this works

The Deck never shows a “turn on Secure Boot” toggle inside its UEFI UI, but Valve ships it in **setup mode**. Setup mode means the firmware happily accepts new Platform Keys (PK), Key Exchange Keys (KEK), and db signatures without user prompts. When you pick the enrollment/enable option in the menu, we drop our baked keys (plus Microsoft’s) into the firmware variables. As soon as the PK lands, the firmware automatically flips Secure Boot to **enabled**. Later, if you use the unenroll/disable option, we clear those vars; once the PK is gone the Deck re-enters setup mode and Secure Boot is **automatically disabled**. No hidden switches involved—just key presence or absence.

## Helpful information & FAQ

- **Clover note:** Clover removes the Deck SB Jump loader entry from the Deck’s Boot Manager (`Vol-` + `Power`). Use `Vol+` + `Power`, pick **Boot From File**, then load `/efi/deck-sb/jump.efi` to load it manually if you get stuck.
- **Signing other OSes:** Any EFI loader or kernel you want to boot with Secure Boot enabled must be signed. Use the Signing Utility to add signatures for every distro you keep on the internal drive.
- **GRUB Secure Boot policy warnings:** Some distros ship GRUB with `grubshim` (SteamOS GRUB has this too), which complains under Secure Boot. That’s why we rely on our custom jump loader instead.

**Does this modify SteamOS?**  We drop a tiny systemd service whose only job is to ensure the Deck SB bootloader entry gets re-added if SteamOS updates wipe it. The OS rootfs, kernel, and userspace remain untouched. If you choose to **install** the ISO to disk from the menu, we also drop a copy of the live ISO environment on SteamOS (~400MB) so you can easily toggle SecureBoot in the future without the USB.

**Will updates still work under Secure Boot?**  Yes. SteamOS keeps its original GRUB entry and kernel images in the EFI partition. We install an additional boot option without overwriting any existing bootloaders.

**SteamOS stopped booting under Secure Boot!**  A recent SteamOS update probably bumped the kernel or initrd filenames. Re-run the EFI installer option from the menu; it re-parses the official SteamOS GRUB config and refreshes the arguments so the Deck SB loader tracks the new assets automatically.

---

## Repo layout

- `build.sh` – Entry point that prepares an Archiso workdir, copies our profile, injects payload + keys, and calls the resigner on output ISO.
- `profile/` – Trimmed Archiso baseline overrides (mainly `profiledef.sh`, EFI bits, pacman.conf).
- `payload/` – Everything that lands inside the live image. `payload/root/menu.sh` drives the ncurses UI, the `deck-*.sh` helpers enroll/unenroll/sign, and `payload/etc/systemd/system/deck-startup.service` re-adds the Deck SB boot entry if updates wipe it.
- `keys/` – the baked Secure Boot keys (`PK.pem`/`PK.key`). `build.sh` mirrors them to `/usr/share/deck-sb/keys` and `/var/lib/sbctl/` during the image build.
- `resigner.sh` – Post-build helper that re-signs the hidden ISO EFI image so the ISO still boots after the Deck trusts these keys.

---

## What you get

- A live ISO that understands the Deck’s UEFI
- A ncurses menu with:
  1. **Check Boot Status** (UEFI? efivars? secureboot?)
  2. **Enroll / Enable Secure Boot** (runs `sbctl enroll-keys -m` with our baked keys)
  3. **Signing Utility, EFI Dropper and ISO Installer** (sign SteamOS or any other EFI loader in one place)
  5. **Root shell**
  7. **Reboot / Poweroff**
  9. **Unenroll / Disable Secure Boot**
- Keys baked into the image, we all use the same keys so it's impossibel to lock yourself out of toggling SecureBoot (you can never lose the signing keys).
- A fixed sbctl GUID so the layout is stable:
  - `decdecde-dec0-4dec-adec-decdecdecdec`

---

## Why you need need to sign EFI's (or other OSes)

Secure Boot is simple but strict: **the firmware will only run binaries signed by keys it trusts.**

What this ISO does when you pick “Enroll / Enable Secure Boot”:

1. Installs **our** key set (the ones below)
2. Installs **Microsoft** production UEFI keys (so Windows and lots of vendor stuff still works)
3. Tells firmware “we’re done, leave setup mode”

After that, when booting the UEFI checks the signature on EFI files:
- anything signed by Microsoft → OK
- anything signed by **our** keys → OK
- anything not signed → **blocked**

SteamOS and other Linux installs often ship **unsigned** or **signed with somebody else’s key**, so the firmware doesn’t trust it. The Signing Utility entry takes the EFI binary you point at (SteamOS or anything else) and **adds our signature** so it passes Secure Boot with our key.

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

These are embedded inside the ISO to KEK/db so we can also *clear* secure boot later.
</details>

---

## The resigner (important)

**Utility:** `resigner.sh` patches the hidden EFI image inside the ISO:

1. Find the El Torito UEFI image
2. Extract it
3. Sign `EFI/BOOT/BOOTx64.EFI` (and IA32 if present) with the baked keys
4. Write it back at the same offset
5. Outputs `*-signed.iso`

Usage:

```bash
./resigner.sh archlinux-steamdeck-sb-latest-x86_64.iso
# -> archlinux-steamdeck-sb-latest-x86_64-signed.iso
```

The main builder will auto-run `resigner.sh` on the generated ISO.

You can also point the resigner at other ISOs to make them bootable under these keys (Ubuntu etc.).

> **Heads-up:** `resigner.sh` rewrites the hidden EFI boot image inside the ISO at its original byte offset. On rare ISOs that pack data immediately after that blob, the rewrite can corrupt the image. If it happens, try adding a little extra data to the ISO to shift around the structure and try again.

---

## Building it yourself

1. Boot an Arch x86_64 container
2. `sudo su`
3. Clone the repo and navigate to it
4. `./build.sh` will install all required dependencies and generate a new ISO. Finished ISOs are placed in `./out/` (or `/out` if that directory exists).

The builder writes ISOs to `/out` when that directory exists (handy inside containers) or `./out/`.

## Building from source (quickstart)

```bash
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

# Inside container
git clone https://github.com/downthecrop/DeckSecureBoot.git
cd DeckSecureBoot
./build.sh
```

---

## Booting it on the Deck

1. Power off Deck
2. Hold **Volume -** and press **Power**
3. Pick the USB you flashed the ISO to

> If you choose to install the ISO to disk in the menu (optional) it will appear in the DeckSB Jumploader (jump.efi)
---

## Credits

- Original method / research: **@ryanrudolfoba**  
  https://github.com/ryanrudolfoba/SecureBootForSteamDeck
