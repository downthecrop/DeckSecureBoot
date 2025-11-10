#!/bin/bash
# Common environment values shared across Deck Secure Boot scripts.
: "${DECK_SB_BACKTITLE:=Steam Deck Secure Boot Manager - D-Pad to navigate, A to select, B to cancel.}"
: "${DECK_SB_KEYDIR:=/usr/share/deck-sb/keys}"
: "${DECK_SB_PENDING_FLAG:=/run/sb_pending_reboot}"

export DECK_SB_BACKTITLE
export DECK_SB_KEYDIR
export DECK_SB_PENDING_FLAG

sanitize_printable() {
  LC_ALL=C tr -cd '\11\12\15\40-\176'
}

secure_boot_enabled() {
  command -v sbctl >/dev/null 2>&1 || return 1
  local sb_line
  sb_line=$(sbctl status 2>/dev/null | grep -i 'Secure Boot' || true)
  if echo "$sb_line" | grep -qi 'enabled'; then
    return 0
  fi
  return 1
}
