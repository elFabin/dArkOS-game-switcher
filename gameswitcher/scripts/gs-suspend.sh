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
gs_ra_running || exit 1

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
  local dir marker shot
  dir="$(gs_shot_dir)"
  gs_log "screenshot dir for ${GS_S_EMULATOR}: ${dir}"
  if [ ! -d "${dir}" ]; then
    gs_log "screenshot dir does not exist, skipping capture"
    return 1
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    gs_log "ffmpeg not found, skipping capture"
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
  gs_log "captured ${shot}, converting to BMP"

  # The carousel reads BMP: SDL2_image's headers are stripped from the device
  # by cleanup_filesystem.sh, so the UI links against core SDL2 only.
  ffmpeg -y -loglevel quiet -i "${shot}" \
    -vf "scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2" \
    -pix_fmt bgr24 "${GS_THUMBS}/${GS_S_KEY}.bmp" >/dev/null 2>&1
  local rc=$?
  rm -f "${shot}" 2>/dev/null
  if [ "${rc}" -ne 0 ]; then
    gs_log "ffmpeg conversion failed with exit ${rc}"
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
while gs_ra_running; do
  [ "${waited}" -ge "$(( GS_QUIT_TIMEOUT * 10 ))" ] && break
  sleep 0.1
  waited=$(( waited + 1 ))
done

# It ignored us.  Take the game down anyway - but only after the grace period
# above, so a slow autosave on a big core is never cut short.
if gs_ra_running; then
  gs_log "RetroArch did not quit in ${GS_QUIT_TIMEOUT}s, terminating"
  pkill -x retroarch 2>/dev/null
  pkill -x retroarch32 2>/dev/null
fi

exit 0
