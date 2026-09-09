#!/bin/bash
#############################################################################
# pause.sh (Game Switcher) - installed over /usr/local/bin/pause.sh only when
# GS_TRIGGER (power|both) called for it at install time -- with the default
# trigger (fn), install.sh never touches pause.sh at all, and a power press
# is plain, unmodified dArkOS suspend.
#
# Kept live-adjustable rather than baked in at install time: editing
# GS_TRIGGER back to "fn" here takes effect on the very next press, with no
# reinstall needed, even though *adding* "power" back does need one (it has
# to restore the hook file this script itself is).
#
# ogage runs this on a power short-press (systemd is told HandlePowerKey=ignore
# in finishing_touches.sh, so ogage owns the key).  When a RetroArch game is up
# we open the switcher; in every other case - in EmulationStation, in a
# standalone emulator, or with the power trigger turned back off - we defer
# to the stock script untouched, so suspend, .SWAPPOWERANDSUSPEND and
# power-off behave exactly as they always did.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

case "${GS_TRIGGER}" in
  power|both) ;;
  *) exec "${GS_BIN}/pause.sh.gs-orig" ;;
esac

if [ -e "${GS_SESSION}" ] && gs_ra_running; then
  exec "${GS_BIN}/gs-suspend.sh"
fi

exec "${GS_BIN}/pause.sh.gs-orig"
