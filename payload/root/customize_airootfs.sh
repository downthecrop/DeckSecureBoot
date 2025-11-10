#!/bin/bash
set -e
chmod +x /root/menu.sh \
  /root/deck-enroll.sh \
  /root/deck-unenroll.sh \
  /root/deck-sign-efi.sh \
  /root/deck-install-jump.sh \
  /root/deck-status.sh

systemctl enable deck-startup.service

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<'EOC'
[Service]
ExecStart=
ExecStart=-/usr/bin/env bash -c 'exec /root/menu.sh'
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
