#!/bin/bash
#############################################################################
# gs-doctor.sh - Game Switcher diagnostics.
#
# Prints the six RetroArch keys the installer patches (across all four
# config files -- retroarch and retroarch32, each live and its .bak twin,
# since dArkOS restores settings from the .bak on reset), whether the
# network-command port will accept a command while a game is running,
# whether ffmpeg/nc/python3 are present, the configured Fn/hotkey code and
# whether its watcher is currently running, and the tail of the debug log
# (GS_DEBUG=1 in gameswitcher.conf).
#
# Meant to be run over SSH ("gs-doctor.sh" or "sudo /usr/local/bin/gs-doctor.sh")
# so the output can be pasted somewhere for troubleshooting.  The Options
# entry, "Game Switcher Diagnostics.sh", shows a short summary of the same
# checks via msgbox -- for the full report, SSH in and run this directly.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

echo "=== dArkOS Game Switcher diagnostics ==="
echo

echo "-- Install --"
if grep -q 'gs-shim' "${GS_BIN}/retroarch" 2>/dev/null; then
  echo "retroarch:      installed (shim active)"
else
  echo "retroarch:      NOT installed"
fi
echo "GS_TRIGGER:     ${GS_TRIGGER}"
echo "GS_SHOW_SPLASH: ${GS_SHOW_SPLASH}"
if grep -q 'gs-suspend' "${GS_BIN}/pause.sh" 2>/dev/null; then
  echo "pause.sh:       hooked (power trigger active)"
else
  echo "pause.sh:       stock (power trigger not installed)"
fi
echo

echo "-- RetroArch config --"
for emulator in retroarch retroarch32; do
  for cfg in "${GS_HOME}/.config/${emulator}/retroarch.cfg" \
             "${GS_HOME}/.config/${emulator}/retroarch.cfg.bak"; do
    if [ ! -f "${cfg}" ]; then
      echo "${cfg}: missing"
      continue
    fi
    echo "${cfg}:"
    for key in savestate_auto_save savestate_auto_load network_cmd_enable \
               screenshot_directory screenshots_in_content_dir video_gpu_screenshot; do
      printf '  %-28s %s\n' "${key}" \
        "$(grep -m1 "^${key} = " "${cfg}" 2>/dev/null | cut -d'"' -f2)"
    done
  done
done
echo

echo "-- Tools --"
if [ -x /usr/bin/ffmpeg ]; then
  ffbin=/usr/bin/ffmpeg
else
  ffbin="$(command -v ffmpeg 2>/dev/null)"
fi
if [ -z "${ffbin}" ]; then
  echo "ffmpeg:   MISSING"
else
  ff_out="$("${ffbin}" -version 2>&1)"
  if [ $? -eq 0 ]; then
    echo "ffmpeg:   present at ${ffbin}, runs OK"
  else
    echo "ffmpeg:   present at ${ffbin}, but running it failed:"
    echo "${ff_out}" | sed 's/^/          /'
    case "${ff_out}" in
      *"error while loading shared libraries: libvulkan.so"*)
        echo "          fix: ssh in and do 'sudo apt install -y libvulkan1'"
        echo "          (or 'sudo apt install --reinstall libvulkan1' if it's already installed but broken somehow)"
        echo "          (a known dArkOS build gap on rk3326 -- cleanup_filesystem.sh's"
        echo "          apt autoremove reaps libvulkan1 after removing the libvulkan-dev"
        echo "          build dependency; rk3566 has its own repair step, rk3326 doesn't)"
        ;;
      *"error while loading shared libraries:"*)
        missing_lib="$(printf '%s\n' "${ff_out}" | sed -n 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p' | head -1)"
        echo "          fix: find and install the package that provides ${missing_lib:-the missing library}"
        ;;
    esac
  fi
fi
command -v nc       >/dev/null 2>&1 && echo "nc:       present" || echo "nc:       MISSING"
command -v python3  >/dev/null 2>&1 && echo "python3:  present" || echo "python3:  MISSING"
if [ -x "${GS_OPT}/gameswitcher" ]; then
  "${GS_OPT}/gameswitcher" --this-flag-does-not-exist >/dev/null 2>&1
  if [ "$?" -eq 2 ]; then
    echo "carousel: built, and runs far enough to parse its own arguments"
  else
    echo "carousel: present but did not respond as expected -- see below"
  fi
else
  echo "carousel: not built (falling back to the text menu)"
fi
echo

echo "-- RetroArch network command (127.0.0.1:${GS_RA_PORT}) --"
if gs_ra_running; then
  if command -v nc >/dev/null 2>&1; then
    gs_ra_cmd VERSION
    echo "sent a VERSION command while RetroArch is running (no reply is expected"
    echo "here -- this only confirms nothing refused the connection outright)"
  fi
else
  echo "no RetroArch is currently running -- launch a game first to test this"
fi
echo

echo "-- Fn / hotkey --"
echo "configured code:   ${GS_HOTKEY_CODE:-708}"
echo "configured device: ${GS_HOTKEY_DEVICE:-(match by capability, not name)}"
if pgrep -f gs-hotkeyd.py >/dev/null 2>&1; then
  echo "watcher:           running"
else
  echo "watcher:           not running (only active while a game is up, and"
  echo "                   only when GS_TRIGGER is fn or both)"
fi
echo

if [ -n "${GS_DEBUG}" ]; then
  echo "-- Debug log --"
  echo "GS_DEBUG=1 is set in gameswitcher.conf, so debug logging is enabled."
  echo "-- Recent log (${GS_STATE}/gameswitcher.log) --"
  if [ -r "${GS_STATE}/gameswitcher.log" ]; then
    tail -n 20 "${GS_STATE}/gameswitcher.log"
  else
    echo "(no log yet -- set GS_DEBUG=1 in gameswitcher.conf to start one)"
  fi
else
  echo "-- Debug log --"
  echo "GS_DEBUG=1 is NOT set in gameswitcher.conf, so debug logging is disabled."
fi
