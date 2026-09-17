#!/bin/bash
#############################################################################
# Game Switcher Button.sh - relearn which button opens the switcher.
#
# The shipped default (evdev code 708, BTN_TRIGGER_HAPPY5) is the A10 Mini's
# Fn/system_hk button.  On a different device that may be the wrong code, so
# this runs gs-hotkeyd.py --learn -- it reports the next button pressed --
# and saves the result into gameswitcher.conf.
#
# Takes effect on the next game launch.  No reinstall needed: this only
# changes which button the already-installed Fn watcher listens for, not any
# system hook file.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

gs_init_dirs

printf '\033c' > /dev/tty1
printf 'Press the button you want to use to open the Game Switcher,\n' > /dev/tty1
printf 'then let go of it.  (30 seconds; hold nothing else at the same time.)\n\n' > /dev/tty1

RESULT="$("${GS_BIN}/gs-hotkeyd.py" --learn 2>/dev/tty1)"
CODE="$(printf '%s\n' "${RESULT}" | sed -n 's/^GS_HOTKEY_CODE=//p')"
DEVICE="$(printf '%s\n' "${RESULT}" | sed -n 's/^GS_HOTKEY_DEVICE=//p')"

if [ -z "${CODE}" ]; then
  printf '\nNo button was detected.  Nothing was changed.\n' > /dev/tty1
  sleep 3
  exit 1
fi

CONF="${GS_STATE}/gameswitcher.conf"
touch "${CONF}"
for key in GS_HOTKEY_CODE GS_HOTKEY_DEVICE; do
  sed -i "/^${key}=/d" "${CONF}"
done
{
  printf 'GS_HOTKEY_CODE=%s\n' "${CODE}"
  printf 'GS_HOTKEY_DEVICE=%s\n' "${DEVICE}"
} >> "${CONF}"
gs_fix_perm "${CONF}"

printf '\nSaved.  "%s" (code %s) opens the switcher from now on.\n' "${DEVICE}" "${CODE}" > /dev/tty1
case "${GS_TRIGGER}" in
  fn|both) ;;
  *) printf 'Note: GS_TRIGGER is "%s", so this has no effect until you set it\n' "${GS_TRIGGER}" > /dev/tty1
     printf 'to "fn" or "both" in gameswitcher.conf.\n' > /dev/tty1 ;;
esac
sleep 4
exit 0
