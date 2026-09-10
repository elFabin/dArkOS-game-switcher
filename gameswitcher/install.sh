#!/bin/bash
#############################################################################
# install.sh - install the dArkOS Game Switcher onto a running device.
#
# Everything it touches is backed up first, so uninstall.sh puts the system
# back exactly as it found it.  Nothing in the OS image is modified at build
# time; this is purely a runtime install.
#
# Usage:  ./install.sh [--yes] [--root DIR]
#           --yes    skip the A/B confirmation (for scripted installs and tests)
#           --root   install into a staging tree instead of / (used by tests)
#############################################################################

set -u

GS_SRC="$(cd "$(dirname "$0")" && pwd)"

ASSUME_YES=""
ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES="y" ;;
    --root)     ROOT="${2%/}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# In a staging tree there is no system to sudo against.
if [ -n "${ROOT}" ]; then
  SUDO=""
else
  SUDO="sudo"
fi

GS_USER="${GS_USER:-ark}"
GS_HOME="${GS_HOME:-/home/${GS_USER}}"

BIN="${ROOT}/usr/local/bin"
OPT="${ROOT}/opt/gameswitcher"
SYSMENU="${ROOT}/opt/system"
SYSADV="${SYSMENU}/Advanced"
STATE="${ROOT}${GS_HOME}/.config/gameswitcher"
CFGBACKUP="${STATE}/retroarch-cfg.backup"
IDLE_UNIT="${ROOT}/etc/systemd/system/gs-hotkeyd-idle.service"
CONF="${STATE}/gameswitcher.conf"

say() { printf '%s\n' "$*"; }
die() { printf 'Game Switcher: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Confirmation, in the same style as the other dArkOS tools
# ---------------------------------------------------------------------------
confirm() {
  [ -n "${ASSUME_YES}" ] && return 0
  [ -r /usr/local/bin/buttonmon.sh ] || return 0
  # shellcheck disable=SC1091
  . /usr/local/bin/buttonmon.sh
  printf '\nInstall the Game Switcher?'
  printf '\nPress A to continue.  Press B to exit.\n'
  while true; do
    Test_Button_A
    [ "$?" -eq 10 ] && return 0
    Test_Button_B
    [ "$?" -eq 10 ] && return 1
    sleep 0.2
  done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  [ -d "${GS_SRC}/scripts" ] || die "payload not found next to $0"

  # Quick Mode rewrites the same RetroArch settings we do (and pause.sh too,
  # if the power trigger is in use).  Running both would leave whichever was
  # installed last in charge and make the uninstall of either one wrong.
  if [ -e "${ROOT}/usr/local/bin/quickmode.sh" ]; then
    die "Quick Mode is enabled.  Run Options > Advanced > Disable Quick Mode
first, then install the Game Switcher.  They both take over the RetroArch
savestate settings (and pause.sh, with the power trigger), so only one can be
active at a time."
  fi

  if [ ! -e "${BIN}/retroarch" ]; then
    die "no /usr/local/bin/retroarch found - is this a dArkOS install?"
  fi
}

# ---------------------------------------------------------------------------
# retroarch.cfg
# ---------------------------------------------------------------------------

# Record the value a key had before we touched it, once per key, so uninstall
# can restore it rather than guessing a default.
remember_cfg() {
  local file="$1" key="$2" old
  grep -q "^${file}	${key}	" "${CFGBACKUP}" 2>/dev/null && return 0
  old="$(grep -m1 "^${key} = " "${file}" 2>/dev/null | cut -d'"' -f2)"
  printf '%s\t%s\t%s\n' "${file}" "${key}" "${old}" >> "${CFGBACKUP}"
}

set_cfg() {
  local file="$1" key="$2" value="$3"
  [ -f "${file}" ] || return 0
  remember_cfg "${file}" "${key}"
  if grep -q "^${key} = " "${file}"; then
    sed -i "s|^${key} = .*|${key} = \"${value}\"|" "${file}"
  else
    printf '%s = "%s"\n' "${key}" "${value}" >> "${file}"
  fi
}

patch_retroarch() {
  local emulator cfg
  # Only start a fresh record on a first install.  Reinstalling over an
  # existing one must not overwrite the original values with our own, or
  # uninstall would restore the patched settings instead of the stock ones.
  [ -f "${CFGBACKUP}" ] || : > "${CFGBACKUP}"
  for emulator in retroarch retroarch32; do
    # dArkOS restores settings from the .bak twin, so both must agree or a
    # reset would silently switch the switcher off.  Quick Mode does the same.
    for cfg in "${ROOT}${GS_HOME}/.config/${emulator}/retroarch.cfg" \
               "${ROOT}${GS_HOME}/.config/${emulator}/retroarch.cfg.bak"; do
      [ -f "${cfg}" ] || continue
      set_cfg "${cfg}" savestate_auto_save  "true"
      set_cfg "${cfg}" savestate_auto_load  "true"
      set_cfg "${cfg}" network_cmd_enable   "true"
      set_cfg "${cfg}" screenshot_directory "${GS_HOME}/.config/gameswitcher/shots"
      # screenshots_in_content_dir OVERRIDES screenshot_directory, and dArkOS
      # ships it on.  Left alone, RetroArch drops the PNG next to the ROM --
      # where we never look, and where ES would scrape it as a PICO-8 cart,
      # since .png is a real ROM extension for the fake08 core.
      set_cfg "${cfg}" screenshots_in_content_dir "false"
      # Take the shot from the core's framebuffer rather than glReadPixels on
      # the Mali blob: more reliable, and a cleaner thumbnail with no shaders
      # or overlays baked in.
      set_cfg "${cfg}" video_gpu_screenshot "false"
    done
  done
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

is_shim() {
  grep -q 'gs-shim' "$1" 2>/dev/null
}

# GS_TRIGGER decides whether pause.sh gets hooked at all: with the default
# (fn), the power button is never touched, so this has to be known before
# that decision -- read whichever config is about to be effective (an
# already-installed one if this is a reinstall, otherwise the shipped
# default), the same value gs-common.sh would end up sourcing.
effective_trigger() {
  local src="${CONF}"
  [ -f "${src}" ] || src="${GS_SRC}/config/gameswitcher.conf"
  local value
  value="$(grep -m1 '^GS_TRIGGER=' "${src}" 2>/dev/null | cut -d= -f2)"
  printf '%s' "${value:-fn}"
}

# The power-button hook is a system file (pause.sh), unlike every other
# trigger setting, so switching it on or off is an install-time action, not
# a live one -- this mirrors it against whatever GS_TRIGGER now says.
sync_pause_hook() {
  local trigger; trigger="$(effective_trigger)"
  case "${trigger}" in
    power|both)
      if [ -e "${BIN}/pause.sh" ] && ! grep -q 'gs-suspend' "${BIN}/pause.sh" 2>/dev/null; then
        ${SUDO} cp "${BIN}/pause.sh" "${BIN}/pause.sh.gs-orig"
      fi
      ${SUDO} cp "${GS_SRC}/scripts/pause.sh.gs" "${BIN}/pause.sh"
      ${SUDO} chmod 777 "${BIN}/pause.sh"
      ;;
    *)
      # fn-only (the default): pause.sh is never touched on a fresh install.
      # On a reinstall after switching away from power/both, put back
      # whatever this tool itself backed up, so a mode change actually
      # takes hold rather than leaving the hook installed but inert.
      if [ -e "${BIN}/pause.sh.gs-orig" ] && grep -q 'gs-suspend' "${BIN}/pause.sh" 2>/dev/null; then
        ${SUDO} cp -f "${BIN}/pause.sh.gs-orig" "${BIN}/pause.sh"
        ${SUDO} chmod 777 "${BIN}/pause.sh"
        ${SUDO} rm -f "${BIN}/pause.sh.gs-orig"
      fi
      ;;
  esac
  [ -e "${BIN}/pause.sh.gs-orig" ] && ${SUDO} chmod 777 "${BIN}/pause.sh.gs-orig"
}

# Older versions (rounds 9-13) installed a persistent systemd unit so the
# carousel could be opened straight from EmulationStation's idle menus, not
# just mid-game or via Options.  That path turned out to have no reliable
# fix (ES only releases its renderer cleanly on its own launch code path --
# see Game Switcher.sh's header comment) and was dropped.  Clean up any
# leftover install from an older version unconditionally, regardless of
# GS_TRIGGER, the same way uninstall.sh already does.
cleanup_idle_hotkey() {
  if [ -e "${IDLE_UNIT}" ]; then
    [ -z "${ROOT}" ] && ${SUDO} systemctl disable --now gs-hotkeyd-idle >/dev/null 2>&1
    ${SUDO} rm -f "${IDLE_UNIT}"
    [ -z "${ROOT}" ] && ${SUDO} systemctl daemon-reload
  fi
}

install_scripts() {
  local emulator

  ${SUDO} mkdir -p "${BIN}" "${OPT}/orig" "${SYSMENU}" "${SYSADV}" \
                   "${STATE}/thumbs" "${STATE}/shots"

  ${SUDO} cp "${GS_SRC}/scripts/gs-common.sh"   "${BIN}/gs-common.sh"
  ${SUDO} cp "${GS_SRC}/scripts/gs-suspend.sh"  "${BIN}/gs-suspend.sh"
  ${SUDO} cp "${GS_SRC}/scripts/gs-menu.sh"     "${BIN}/gs-menu.sh"
  ${SUDO} cp "${GS_SRC}/scripts/gs-hotkeyd.py"  "${BIN}/gs-hotkeyd.py"
  ${SUDO} cp "${GS_SRC}/scripts/gs-doctor.sh"   "${BIN}/gs-doctor.sh"

  # Move each stock RetroArch wrapper aside, keeping its original basename:
  # it branches on `basename "$0"` to serve retroarch and retroarch32 alike.
  for emulator in retroarch retroarch32; do
    [ -e "${BIN}/${emulator}" ] || continue
    if ! is_shim "${BIN}/${emulator}"; then
      ${SUDO} cp "${BIN}/${emulator}" "${OPT}/orig/${emulator}"
    fi
    ${SUDO} cp "${GS_SRC}/scripts/gs-shim.sh" "${BIN}/${emulator}"
  done

  ${SUDO} cp "${GS_SRC}/scripts/Game Switcher.sh" "${SYSMENU}/Game Switcher.sh"
  ${SUDO} cp "${GS_SRC}/scripts/Game Switcher Button.sh" "${SYSADV}/Game Switcher Button.sh"
  ${SUDO} cp "${GS_SRC}/scripts/Game Switcher Diagnostics.sh" "${SYSADV}/Game Switcher Diagnostics.sh"

  # Ship the tunables as a commented file, but never clobber an edited one.
  if [ ! -f "${CONF}" ] && [ -f "${GS_SRC}/config/gameswitcher.conf" ]; then
    ${SUDO} cp "${GS_SRC}/config/gameswitcher.conf" "${CONF}"
  fi

  # Decided from GS_TRIGGER now that the config above is in its final state.
  sync_pause_hook
  cleanup_idle_hotkey

  ${SUDO} chmod 777 "${BIN}/gs-common.sh" "${BIN}/gs-suspend.sh" "${BIN}/gs-menu.sh" \
                    "${BIN}/gs-hotkeyd.py" "${BIN}/gs-doctor.sh" \
                    "${SYSMENU}/Game Switcher.sh" \
                    "${SYSADV}/Game Switcher Button.sh" "${SYSADV}/Game Switcher Diagnostics.sh"
  for emulator in retroarch retroarch32; do
    [ -e "${BIN}/${emulator}" ] && ${SUDO} chmod 777 "${BIN}/${emulator}"
  done
  ${SUDO} chmod 777 "${OPT}/orig"/* 2>/dev/null

  ${SUDO} chmod 777 "${STATE}" "${STATE}/thumbs" "${STATE}/shots"
  [ -z "${ROOT}" ] && ${SUDO} chown -R "${GS_USER}:${GS_USER}" "${STATE}"
  return 0
}

# The carousel is a nicety; the dialog menu covers the same job.  Never fail
# the install because a compiler is missing.
#
# Building from source comes first: a bundled binary may well have been built
# on a desktop and be the wrong architecture for this device.
usable_binary() {
  [ -x "$1" ] || return 1
  # A wrong-architecture binary exits 126 here; ours prints usage and exits 2.
  "$1" --this-flag-does-not-exist >/dev/null 2>&1
  [ "$?" -eq 2 ]
}

install_ui() {
  if command -v cc >/dev/null 2>&1 && [ -e /usr/include/SDL2/SDL.h ]; then
    say "Building the carousel..."
    ( cd "${GS_SRC}" && make >/dev/null 2>&1 )
    if usable_binary "${GS_SRC}/gameswitcher"; then
      ${SUDO} cp "${GS_SRC}/gameswitcher" "${OPT}/gameswitcher"
      ${SUDO} chmod 777 "${OPT}/gameswitcher"
      return 0
    fi
    say "Build failed."
  fi

  if usable_binary "${GS_SRC}/gameswitcher"; then
    say "Using the bundled carousel binary."
    ${SUDO} cp "${GS_SRC}/gameswitcher" "${OPT}/gameswitcher"
    ${SUDO} chmod 777 "${OPT}/gameswitcher"
    return 0
  fi

  say "No compiler or SDL2 headers here - falling back to the text menu."
  say "(Everything still works; only the screenshot carousel is missing.)"
  ${SUDO} rm -f "${OPT}/gameswitcher"
  return 0
}

# Screenshots depend on ffmpeg actually running, not just being present -- a
# known dArkOS build gap on rk3326 leaves ffmpeg installed but unable to load
# libvulkan.so.1 (see gs-doctor.sh).  Surface that now rather than waiting for
# a failed thumbnail and a debug-log round trip.
check_ffmpeg() {
  local ffbin ff_out
  if [ -x /usr/bin/ffmpeg ]; then
    ffbin=/usr/bin/ffmpeg
  else
    ffbin="$(command -v ffmpeg 2>/dev/null)"
  fi
  if [ -z "${ffbin}" ]; then
    say "Warning: ffmpeg not found -- screenshots in the switcher will not work."
    return 0
  fi
  ff_out="$("${ffbin}" -version 2>&1)"
  if [ $? -eq 0 ]; then
    return 0
  fi
  say ""
  say "Warning: ffmpeg is installed but failed to run -- screenshots in the"
  say "switcher will not work until this is fixed:"
  say "${ff_out}"
  case "${ff_out}" in
    *"error while loading shared libraries: libvulkan.so"*)
      say "Fix: sudo apt-get install -y libvulkan1"
      ;;
  esac
}

# ---------------------------------------------------------------------------

preflight
if ! confirm; then
  say "Nothing was changed."
  exit 0
fi

say "Installing the Game Switcher..."
install_scripts
patch_retroarch
install_ui

# Give the carousel something to show before the first suspend.
if [ -z "${ROOT}" ]; then
  # shellcheck disable=SC1091
  . "${BIN}/gs-common.sh"
  gs_recents_seed
  check_ffmpeg
fi

say ""
case "$(effective_trigger)" in
  power)
    say "Done.  Press the power button briefly while a RetroArch game is"
    say "running to snapshot it and open the switcher."
    ;;
  both)
    say "Done.  Tap Fn, or press the power button briefly, while a RetroArch"
    say "game is running to snapshot it and open the switcher."
    ;;
  *)
    say "Done.  Tap Fn briefly while a RetroArch game is running to snapshot"
    say "it and open the switcher.  (On a device other than the A10 Mini,"
    say "use Options > Advanced > Game Switcher Button to teach it the right"
    say "button.)  The power button still just suspends."
    ;;
esac
say "The carousel is also reachable from Options > Game Switcher."
[ -z "${ASSUME_YES}" ] && sleep 4
exit 0
