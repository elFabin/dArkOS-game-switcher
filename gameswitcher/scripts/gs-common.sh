#!/bin/bash
#############################################################################
# gs-common.sh - shared helpers for the dArkOS Game Switcher.
#
# Sourced by gs-shim.sh, gs-suspend.sh and gs-menu.sh.  Keep this free of
# side effects: sourcing it must never touch the screen or the running game.
#
# Note that gs-suspend.sh is reached from pause.sh, which ogage may run as
# root, so nothing here may rely on $HOME.
#############################################################################

GS_USER="${GS_USER:-ark}"
GS_HOME="${GS_HOME:-/home/${GS_USER}}"
GS_STATE="${GS_STATE:-${GS_HOME}/.config/gameswitcher}"
GS_OPT="${GS_OPT:-/opt/gameswitcher}"
GS_BIN="${GS_BIN:-/usr/local/bin}"

GS_RECENTS="${GS_STATE}/recents.tsv"
GS_THUMBS="${GS_STATE}/thumbs"
GS_SHOTS="${GS_STATE}/shots"
GS_CONF="${GS_STATE}/gameswitcher.conf"

# Runtime markers.  /dev/shm is tmpfs, so these never survive a reboot.
GS_RUN="${GS_RUN:-/dev/shm}"
GS_SESSION="${GS_RUN}/gs_session"
GS_SWITCH="${GS_RUN}/gs_switch"
GS_CHOICE="${GS_RUN}/gs_choice"

# Defaults, as ${VAR:-default} so an already-exported value (a test harness,
# or a caller that wants to override one setting for a single invocation)
# survives sourcing this file; gameswitcher.conf, sourced below, is still the
# normal way to change any of them for real and wins over both.
GS_MAX_RECENTS="${GS_MAX_RECENTS:-12}"
GS_RA_PORT="${GS_RA_PORT:-55355}"
# Off by default: it re-runs perfmax (a third DRM/KMS client, and on rk3326 a
# deletion of ~/.asoundrc that only ES's own game-end hook restores) right in
# the handover window between one game and the next.  See gs-shim.sh.
GS_SHOW_SPLASH="${GS_SHOW_SPLASH:-0}"
GS_QUIT_TIMEOUT="${GS_QUIT_TIMEOUT:-10}"
GS_SHOT_TIMEOUT="${GS_SHOT_TIMEOUT:-5}"

# fn | power | both.  Fn is BTN_TRIGGER_HAPPY5 (evdev 708) on the A10 Mini --
# confirmed against both es_input.cfg.a10mini (system_hk id="16") and the
# ogage a10mini branch's own HOTKEY constant.  Blank GS_HOTKEY_DEVICE matches
# by capability (any device that can emit the code) rather than by name, so a
# wrong device name only narrows the search instead of breaking it.
GS_TRIGGER="${GS_TRIGGER:-fn}"
GS_HOTKEY_CODE="${GS_HOTKEY_CODE:-708}"
GS_HOTKEY_DEVICE="${GS_HOTKEY_DEVICE:-}"

# Changing GS_TRIGGER here takes effect on the next game launch for the Fn
# watcher (gs-shim.sh starts/stops it live).  The power-button hook is a
# system file (pause.sh) and is only installed when the trigger requested at
# install time included "power" -- flip it on by re-running install.sh.

# Freeze EmulationStation (SIGSTOP) for the life of the switch loop and
# SIGCONT it on every exit path.  Off by default: the diagnosed cause of ES
# appearing to "take over" is a lost DRM-master race between the switcher and
# the next game (see gameswitcher.c's init retry), not ES itself running, and
# a frozen ES looks exactly like a dead device if this ever fails to resume.
# Try 1 only if GS_SHOW_SPLASH=0 plus the retry logic don't fix it.
GS_ES_FREEZE="${GS_ES_FREEZE:-0}"

# Log every switch, screenshot attempt and UI start to
# ~/.config/gameswitcher/gameswitcher.log with timestamps, for diagnosing
# reports that can't be reproduced here.
GS_DEBUG="${GS_DEBUG:-0}"

# Exit code gameswitcher.c uses for "the UI could not start at all" (as
# opposed to 10/back or 11/sleep, which are real user choices).  gs-shim.sh
# falls back to gs-menu.sh when it sees this, instead of treating it as "the
# player chose to leave".
GS_UI_FAILED_RC="${GS_UI_FAILED_RC:-12}"

if [ -r "${GS_CONF}" ]; then
  # shellcheck disable=SC1090
  . "${GS_CONF}"
fi

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

gs_log() {
  echo "gameswitcher: $*" >&2
  [ "${GS_DEBUG:-0}" = "1" ] || return 0
  local logf="${GS_STATE}/gameswitcher.log" line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  { mkdir -p "${GS_STATE}" 2>/dev/null && printf '%s\n' "${line}" >> "${logf}" 2>/dev/null; } \
    || { sudo mkdir -p "${GS_STATE}" 2>/dev/null; printf '%s\n' "${line}" | sudo tee -a "${logf}" >/dev/null 2>&1; }
  gs_fix_perm "${logf}"
}

# Files under ${GS_STATE} may be written by root (via pause.sh) or by ark (via
# the shim).  Keep everything group/world writable so neither locks the other
# out, mirroring how dArkOS treats /opt/system and /usr/local/bin.
gs_fix_perm() {
  local f
  for f in "$@"; do
    [ -e "${f}" ] || continue
    chmod 666 "${f}" 2>/dev/null || sudo chmod 666 "${f}" 2>/dev/null
    if [ "$(id -u)" = "0" ]; then
      chown "${GS_USER}:${GS_USER}" "${f}" 2>/dev/null
    fi
  done
}

gs_init_dirs() {
  local d
  for d in "${GS_STATE}" "${GS_THUMBS}" "${GS_SHOTS}"; do
    [ -d "${d}" ] && continue
    mkdir -p "${d}" 2>/dev/null || sudo mkdir -p "${d}" 2>/dev/null
    chmod 777 "${d}" 2>/dev/null || sudo chmod 777 "${d}" 2>/dev/null
    if [ "$(id -u)" = "0" ]; then
      chown "${GS_USER}:${GS_USER}" "${d}" 2>/dev/null
    fi
  done
}

# A stable id for a ROM, used to name its thumbnail.
gs_key() {
  printf '%s' "$1" | sha1sum | cut -c1-16
}

# "/roms/snes/Super Game (USA).smc" -> "Super Game (USA)"
gs_title() {
  local base="${1##*/}"
  printf '%s' "${base%.*}"
}

# "/roms/snes/x.smc" -> "snes";  "/roms2/psx/y.chd" -> "psx"
gs_system() {
  local p="${1#/}"
  p="${p#*/}"
  if [ "${p}" = "$1" ] || [ -z "${p}" ]; then
    printf 'games'
  else
    printf '%s' "${p%%/*}"
  fi
}

# ---------------------------------------------------------------------------
# Talking to a live RetroArch
# ---------------------------------------------------------------------------

# Send a RetroArch network command.  We deliberately do NOT shell out to
# `retroarch --command`: /usr/local/bin/retroarch is our own shim, so that
# would recurse.  netcat-openbsd is in needed_packages.txt.
gs_ra_cmd() {
  printf '%s\n' "$1" | nc -u -w1 127.0.0.1 "${GS_RA_PORT}" >/dev/null 2>&1
}

gs_ra_running() {
  pgrep -x retroarch >/dev/null 2>&1 || pgrep -x retroarch32 >/dev/null 2>&1
}

# A game's process exiting doesn't necessarily mean its GPU/DRM context has
# finished tearing down (amiberry/amiberry.sh documents exactly this kind of
# lag for EmulationStation's own handover).  Give it a brief, bounded window
# to settle before the switcher contends for the display.
gs_wait_for_teardown() {
  local waited=0
  while gs_ra_running; do
    [ "${waited}" -ge 20 ] && break
    sleep 0.1
    waited=$(( waited + 1 ))
  done
}

# ---------------------------------------------------------------------------
# Optional: freeze EmulationStation for the life of the switch loop
# (GS_ES_FREEZE=1).  Never `systemctl stop` it: emulationstation.service is
# Type=simple with the default KillMode=control-group, and our own shim is
# inside that same cgroup, so stopping the service would kill the switcher.
# SIGSTOP only pauses scheduling; the process resumes exactly where it left
# off, and never triggers systemd's Restart=on-failure.
# ---------------------------------------------------------------------------

gs_es_freeze() {
  [ "${GS_ES_FREEZE:-0}" = "1" ] || return 0
  pkill -STOP -x emulationstation 2>/dev/null
}

# Unconditional and safe to call even when nothing is frozen: this is the one
# call that must never be skipped, so it does not gate on GS_ES_FREEZE.
gs_es_resume() {
  pkill -CONT -x emulationstation 2>/dev/null
}

# A background watchdog that resumes ES if this process disappears without
# running its own EXIT trap (e.g. SIGKILL, which no trap can catch).
gs_es_watchdog_start() {
  [ "${GS_ES_FREEZE:-0}" = "1" ] || return 0
  local watch_pid="$1"
  (
    while kill -0 "${watch_pid}" 2>/dev/null; do
      sleep 2
    done
    pkill -CONT -x emulationstation 2>/dev/null
  ) &
  disown 2>/dev/null
}

# ---------------------------------------------------------------------------
# Session marker: what is playing right now
# ---------------------------------------------------------------------------

gs_session_write() {
  local emulator="$1" core="$2" rom="$3" key="$4"
  {
    printf 'GS_S_EMULATOR=%s\n' "${emulator}"
    printf 'GS_S_CORE=%s\n' "${core}"
    printf 'GS_S_ROM=%s\n' "${rom}"
    printf 'GS_S_KEY=%s\n' "${key}"
  } > "${GS_SESSION}" 2>/dev/null
  gs_fix_perm "${GS_SESSION}"
}

gs_session_clear() {
  rm -f "${GS_SESSION}" 2>/dev/null
}

gs_session_read() {
  [ -r "${GS_SESSION}" ] || return 1
  GS_S_EMULATOR=""; GS_S_CORE=""; GS_S_ROM=""; GS_S_KEY=""
  # Only well-formed GS_S_* assignments are honoured; the file is ours, but
  # sourcing something writable by anyone would be careless.
  local name value
  while IFS='=' read -r name value; do
    case "${name}" in
      GS_S_EMULATOR) GS_S_EMULATOR="${value}" ;;
      GS_S_CORE)     GS_S_CORE="${value}" ;;
      GS_S_ROM)      GS_S_ROM="${value}" ;;
      GS_S_KEY)      GS_S_KEY="${value}" ;;
    esac
  done < "${GS_SESSION}"
  [ -n "${GS_S_ROM}" ]
}

# ---------------------------------------------------------------------------
# The recents list
#
# TSV, newest first, one game per line:
#   key <TAB> epoch <TAB> emulator <TAB> core <TAB> system <TAB> title <TAB> rom
# ---------------------------------------------------------------------------

gs_recents_add() {
  local emulator="$1" core="$2" rom="$3"
  local key title system now tmp
  [ -n "${rom}" ] || return 0
  key="$(gs_key "${rom}")"
  title="$(gs_title "${rom}")"
  system="$(gs_system "${rom}")"
  now="$(date +%s)"
  gs_init_dirs
  tmp="${GS_RECENTS}.$$"
  {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${key}" "${now}" "${emulator}" "${core}" "${system}" "${title}" "${rom}"
    if [ -r "${GS_RECENTS}" ]; then
      awk -F'\t' -v k="${key}" '$1 != k' "${GS_RECENTS}" 2>/dev/null
    fi
  } | head -n "${GS_MAX_RECENTS}" > "${tmp}" 2>/dev/null
  mv -f "${tmp}" "${GS_RECENTS}" 2>/dev/null
  gs_fix_perm "${GS_RECENTS}"
}

gs_recents_remove() {
  local key="$1" tmp
  [ -n "${key}" ] || return 0
  [ -r "${GS_RECENTS}" ] || return 0
  tmp="${GS_RECENTS}.$$"
  awk -F'\t' -v k="${key}" '$1 != k' "${GS_RECENTS}" > "${tmp}" 2>/dev/null
  mv -f "${tmp}" "${GS_RECENTS}" 2>/dev/null
  gs_fix_perm "${GS_RECENTS}"
  rm -f "${GS_THUMBS}/${key}.bmp" 2>/dev/null
}

# Populate an empty recents list from RetroArch's own history playlist, so the
# carousel has something in it the very first time it is opened.  Same source
# of truth scripts/get_last_played.sh uses.
gs_recents_seed() {
  local emulator playlist
  [ -s "${GS_RECENTS}" ] && return 0
  gs_init_dirs
  for emulator in retroarch retroarch32; do
    playlist="${GS_HOME}/.config/${emulator}/playlists/builtin/content_history.lpl"
    [ -r "${playlist}" ] || continue
    python3 - "${playlist}" "${emulator}" <<'PY' >> "${GS_RECENTS}" 2>/dev/null
import hashlib, json, os, sys, time

playlist, emulator = sys.argv[1], sys.argv[2]
try:
    with open(playlist, encoding="utf-8", errors="replace") as fh:
        items = json.load(fh).get("items", [])
except (OSError, ValueError):
    sys.exit(0)

now = int(time.time())
for offset, item in enumerate(items[:12]):
    rom = item.get("path") or ""
    core = item.get("core_path") or ""
    if not rom or not os.path.exists(rom):
        continue
    key = hashlib.sha1(rom.encode("utf-8")).hexdigest()[:16]
    title = os.path.splitext(os.path.basename(rom))[0]
    parts = rom.strip("/").split("/")
    system = parts[1] if len(parts) > 2 else "games"
    # Stagger the timestamps so playlist order survives the newest-first sort.
    print("\t".join([key, str(now - offset - 1), emulator, core, system, title, rom]))
PY
  done
  gs_fix_perm "${GS_RECENTS}"
}

# ---------------------------------------------------------------------------
# The UI's answer
# ---------------------------------------------------------------------------

# Reads /dev/shm/gs_choice into GS_C_ACTION / GS_C_* .  Same restricted parse
# as the session marker.
gs_choice_read() {
  [ -r "${GS_CHOICE}" ] || return 1
  GS_C_ACTION=""; GS_C_KEY=""; GS_C_EMULATOR=""; GS_C_CORE=""; GS_C_ROM=""
  local name value
  while IFS='=' read -r name value; do
    case "${name}" in
      action)   GS_C_ACTION="${value}" ;;
      key)      GS_C_KEY="${value}" ;;
      emulator) GS_C_EMULATOR="${value}" ;;
      core)     GS_C_CORE="${value}" ;;
      rom)      GS_C_ROM="${value}" ;;
    esac
  done < "${GS_CHOICE}"
  [ -n "${GS_C_ACTION}" ]
}
