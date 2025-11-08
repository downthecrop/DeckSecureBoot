#!/bin/bash
# Common environment values shared across Deck Secure Boot scripts.
: "${DECK_SB_BACKTITLE:=Steam Deck Secure Boot Manager - D-Pad to navigate, A to select, B to cancel.}"
: "${DECK_SB_KEYDIR:=/usr/share/deck-sb/keys}"
: "${DECK_SB_PENDING_FLAG:=/run/sb_pending_reboot}"

export DECK_SB_BACKTITLE
export DECK_SB_KEYDIR
export DECK_SB_PENDING_FLAG
