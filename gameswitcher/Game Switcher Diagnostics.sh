#!/bin/bash
#############################################################################
# Game Switcher Diagnostics.sh - the Options > Advanced summary view.
#
# gs-doctor.sh's full report is meant for SSH (it's long, and easiest to
# paste from a real terminal); this shows the short version people actually
# need standing in front of the device, via the same msgbox every other
# dArkOS info screen uses.
#############################################################################

OUT="$(/usr/local/bin/gs-doctor.sh 2>&1)"

summary="$(printf '%s\n' "${OUT}" | grep -E \
  '^(retroarch|GS_TRIGGER|pause\.sh|ffmpeg|nc|python3|carousel|watcher):')"

msgbox "$(printf '%s\n\nFor the full report, SSH in and run:\n  gs-doctor.sh' "${summary}")" \
  "Game Switcher"
