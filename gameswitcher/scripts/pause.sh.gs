#!/bin/bash
#############################################################################
# pause.sh (Game Switcher) - installed over /usr/local/bin/pause.sh.
#
# ogage runs this on a power short-press (systemd is told HandlePowerKey=ignore
# in finishing_touches.sh, so ogage owns the key).  When a RetroArch game is up
# we open the switcher; in every other case - in EmulationStation, in a
# standalone emulator - we defer to the stock script untouched, so suspend,
# .SWAPPOWERANDSUSPEND and power-off behave exactly as they always did.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

if [ -e "${GS_SESSION}" ] && gs_ra_running; then
  exec "${GS_BIN}/gs-suspend.sh"
fi

exec "${GS_BIN}/pause.sh.gs-orig"
