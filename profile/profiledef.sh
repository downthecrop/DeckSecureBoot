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
  ["/root/menu.sh"]="0:0:755"
  ["/root/deck-enroll.sh"]="0:0:755"
  ["/root/deck-unenroll.sh"]="0:0:755"
  ["/root/deck-sign-efi.sh"]="0:0:755"
  ["/root/deck-status.sh"]="0:0:755"
  ["/root/customize_airootfs.sh"]="0:0:755"
)
