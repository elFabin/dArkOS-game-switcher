#!/bin/bash
#############################################################################
# Game Switcher Setup.sh - the Options > Advanced entry that turns the Game
# Switcher on or off.
#
# It ships inactive, the way Quick Mode does: the payload is on the image but
# nothing hooks pause.sh or the RetroArch wrapper until the player asks.  The
# one entry offers whichever action applies.
#############################################################################

if [ -d "/opt/gameswitcher/payload" ]; then
  PAYLOAD="/opt/gameswitcher/scripts"
else
  # Fall back to gs-install.sh from scripts directory
  PAYLOAD="/roms/tools/GameSwitcher/scripts"
fi


if [ -e /usr/local/bin/gs-common.sh ] && grep -q 'gs-shim' /usr/local/bin/retroarch 2>/dev/null; then
  echo "Game Switcher is already installed.  Uninstalling..."
  exec "${PAYLOAD}/gs-uninstall.sh"
fi

exec "${PAYLOAD}/gs-install.sh"
