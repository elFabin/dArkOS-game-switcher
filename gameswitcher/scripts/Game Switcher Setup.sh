#!/bin/bash
#############################################################################
# Game Switcher Setup.sh - the Options > Advanced entry that turns the Game
# Switcher on or off.
#
# It ships inactive, the way Quick Mode does: the payload is on the image but
# nothing hooks pause.sh or the RetroArch wrapper until the player asks.  The
# one entry offers whichever action applies.
#############################################################################

PAYLOAD="/opt/gameswitcher/payload"

if [ -e /usr/local/bin/gs-common.sh ] && grep -q 'gs-shim' /usr/local/bin/retroarch 2>/dev/null; then
  exec "${PAYLOAD}/uninstall.sh"
fi

exec "${PAYLOAD}/install.sh"
