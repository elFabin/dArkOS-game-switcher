#!/bin/bash
#############################################################################
# gs-suspend.sh - snapshot the running RetroArch game and hand control to the
# switcher.  Reached from pause.sh on a power short-press.
#
# The savestate itself is written by RetroArch, not by us: install.sh turns on
# savestate_auto_save, so a clean QUIT leaves <rom>.state.auto next to the ROM
# and savestate_auto_load picks it back up on the next launch.  That is the
# same mechanism dArkOS's own Quick Mode uses.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

# Mashing the power button must not queue up two snapshots.
[ -e "${GS_SWITCH}" ] && exit 0

gs_session_read || exit 1
# Check the tracked PID directly rather than gs_ra_running: gs-shim.sh
# itself is a script installed as /usr/local/bin/retroarch and launched
# directly by path, and the kernel sets a directly-exec'd script's comm to
# its own basename -- so gs-shim.sh's own process is indistinguishable from
# the real RetroArch binary by name.  gs_ra_running's name-based pgrep
# would therefore always see gs-shim.sh itself as "RetroArch running",
# whether or not the actual game process is still alive.
kill -0 "${GS_S_PID}" 2>/dev/null || exit 1

gs_init_dirs

# ---------------------------------------------------------------------------
# Where does this RetroArch drop screenshots?
# ---------------------------------------------------------------------------
gs_shot_dir() {
  local cfg="${GS_HOME}/.config/${GS_S_EMULATOR}/retroarch.cfg" dir=""
  if [ -r "${cfg}" ]; then
    dir="$(grep -m1 '^screenshot_directory' "${cfg}" | cut -d'"' -f2)"
  fi
  case "${dir}" in
    ""|default) dir="${GS_SHOTS}" ;;
    "~"/*)      dir="${GS_HOME}/${dir#\~/}" ;;
  esac
  printf '%s' "${dir}"
}

# ---------------------------------------------------------------------------
# Grab the frame the player is looking at, before anything quits.
# ---------------------------------------------------------------------------
gs_capture_thumb() {
  local dir marker shot ffmpeg_bin
  dir="$(gs_shot_dir)"
  gs_log "screenshot dir for ${GS_S_EMULATOR}: ${dir}"
  if [ ! -d "${dir}" ]; then
    gs_log "screenshot dir does not exist, skipping capture"
    return 1
  fi

  # Prefer the confirmed on-device location over a bare PATH lookup: ffmpeg
  # lands at /usr/bin/ffmpeg on every dArkOS build variant (a plain apt
  # package on rk3326, a custom rockchip-mpp build installed to the same
  # --prefix=/usr on rk3566).  `command -v ffmpeg` has been observed to
  # succeed while a later bare `ffmpeg` call in the very same script run
  # still failed with "not found" (exit 127) -- nothing in the OS build
  # (systemd unit, sudoers, profile scripts) explains that discrepancy, so
  # this at least removes PATH resolution as a variable for the common case.
  if [ -x /usr/bin/ffmpeg ]; then
    ffmpeg_bin=/usr/bin/ffmpeg
  else
    ffmpeg_bin="$(command -v ffmpeg 2>/dev/null)"
  fi
  if [ -z "${ffmpeg_bin}" ]; then
    gs_log "ffmpeg not found (checked /usr/bin/ffmpeg and PATH=${PATH})"
    return 1
  fi

  local waited
  marker="${dir}/.gs-marker"
  : > "${marker}" 2>/dev/null || return 1

  gs_log "sending SCREENSHOT to 127.0.0.1:${GS_RA_PORT}"
  gs_ra_cmd SCREENSHOT

  waited=0
  shot=""
  while [ "${waited}" -lt "$(( GS_SHOT_TIMEOUT * 10 ))" ]; do
    shot="$(find "${dir}" -maxdepth 1 -type f -name '*.png' -newer "${marker}" 2>/dev/null | head -1)"
    [ -n "${shot}" ] && break
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  rm -f "${marker}" 2>/dev/null
  if [ -z "${shot}" ]; then
    gs_log "no new screenshot appeared in ${dir} within ${GS_SHOT_TIMEOUT}s"
    return 1
  fi
  gs_log "captured ${shot}, converting to BMP with ${ffmpeg_bin}"

  # The carousel reads BMP: SDL2_image's headers are stripped from the device
  # by cleanup_filesystem.sh, so the UI links against core SDL2 only.
  # -loglevel error (not quiet) plus capturing output means an actual failure
  # logs ffmpeg's own message instead of a bare, ambiguous exit code.
  #
  # Scaled to the device's own display resolution, not a fixed low size: the
  # carousel now shows this full-screen (gameswitcher.c fits it to the screen
  # preserving aspect ratio at draw time), so capturing at native resolution
  # avoids downscaling then blowing it back up again for display.
  local ff_err rc size
  size="$(gs_display_size)"
  ff_err="$("${ffmpeg_bin}" -y -loglevel error -i "${shot}" \
    -vf "scale=${size}:force_original_aspect_ratio=decrease,pad=${size}:(ow-iw)/2:(oh-ih)/2" \
    -pix_fmt bgr24 "${GS_THUMBS}/${GS_S_KEY}.bmp" 2>&1)"
  rc=$?
  rm -f "${shot}" 2>/dev/null
  if [ "${rc}" -ne 0 ]; then
    gs_log "ffmpeg conversion failed with exit ${rc}: ${ff_err}"
    return 1
  fi
  gs_fix_perm "${GS_THUMBS}/${GS_S_KEY}.bmp"
}

gs_capture_thumb || gs_log "no thumbnail captured for ${GS_S_ROM}"

# Set the marker before quitting: the shim watches for the emulator to exit,
# and must never see that happen without knowing why.
: > "${GS_SWITCH}" 2>/dev/null
gs_fix_perm "${GS_SWITCH}"

# Two QUITs is what Quick Mode sends; RetroArch's quit_press_twice is on.
gs_log "quitting ${GS_S_EMULATOR} (${GS_S_ROM})"
gs_ra_cmd QUIT
gs_ra_cmd QUIT

waited=0
while kill -0 "${GS_S_PID}" 2>/dev/null; do
  [ "${waited}" -ge "$(( GS_QUIT_TIMEOUT * 10 ))" ] && break
  sleep 0.1
  waited=$(( waited + 1 ))
done

# It ignored us.  Take the game down anyway - but only after the grace period
# above, so a slow autosave on a big core is never cut short.  Kill the
# tracked PID directly, never by name: gs-shim.sh shares the exact same
# comm as the real RetroArch binary (see the comment above), so a
# name-based pkill here would kill gs-shim.sh's own process too, ending the
# whole switch session and handing control back to EmulationStation as an
# unintended side effect (confirmed on real hardware -- this was the actual
# cause of "EmulationStation flickering" during a switch).
if kill -0 "${GS_S_PID}" 2>/dev/null; then
  gs_log "RetroArch did not quit in ${GS_QUIT_TIMEOUT}s, terminating pid ${GS_S_PID}"
  kill -TERM "${GS_S_PID}" 2>/dev/null
fi

exit 0
