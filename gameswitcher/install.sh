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
STATE="${ROOT}${GS_HOME}/.config/gameswitcher"
CFGBACKUP="${STATE}/retroarch-cfg.backup"

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

  # Quick Mode rewrites the same pause.sh and the same four RetroArch keys we
  # do.  Running both would leave whichever was installed last in charge and
  # make the uninstall of either one wrong.
  if [ -e "${ROOT}/usr/local/bin/quickmode.sh" ]; then
    die "Quick Mode is enabled.  Run Options > Advanced > Disable Quick Mode
first, then install the Game Switcher.  They both take over pause.sh and the
RetroArch savestate settings, so only one can be active at a time."
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
    done
  done
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

is_shim() {
  grep -q 'gs-shim' "$1" 2>/dev/null
}

install_scripts() {
  local emulator

  ${SUDO} mkdir -p "${BIN}" "${OPT}/orig" "${SYSMENU}" "${STATE}/thumbs" "${STATE}/shots"

  ${SUDO} cp "${GS_SRC}/scripts/gs-common.sh"  "${BIN}/gs-common.sh"
  ${SUDO} cp "${GS_SRC}/scripts/gs-suspend.sh" "${BIN}/gs-suspend.sh"
  ${SUDO} cp "${GS_SRC}/scripts/gs-menu.sh"    "${BIN}/gs-menu.sh"

  # Move each stock RetroArch wrapper aside, keeping its original basename:
  # it branches on `basename "$0"` to serve retroarch and retroarch32 alike.
  for emulator in retroarch retroarch32; do
    [ -e "${BIN}/${emulator}" ] || continue
    if ! is_shim "${BIN}/${emulator}"; then
      ${SUDO} cp "${BIN}/${emulator}" "${OPT}/orig/${emulator}"
    fi
    ${SUDO} cp "${GS_SRC}/scripts/gs-shim.sh" "${BIN}/${emulator}"
  done

  # pause.sh is what ogage runs on a power short-press.
  if [ -e "${BIN}/pause.sh" ] && ! grep -q 'gs-suspend' "${BIN}/pause.sh" 2>/dev/null; then
    ${SUDO} cp "${BIN}/pause.sh" "${BIN}/pause.sh.gs-orig"
  fi
  ${SUDO} cp "${GS_SRC}/scripts/pause.sh.gs" "${BIN}/pause.sh"

  ${SUDO} cp "${GS_SRC}/scripts/Game Switcher.sh" "${SYSMENU}/Game Switcher.sh"

  # Ship the tunables as a commented file, but never clobber an edited one.
  if [ ! -f "${STATE}/gameswitcher.conf" ] && [ -f "${GS_SRC}/config/gameswitcher.conf" ]; then
    ${SUDO} cp "${GS_SRC}/config/gameswitcher.conf" "${STATE}/gameswitcher.conf"
  fi

  ${SUDO} chmod 777 "${BIN}/gs-common.sh" "${BIN}/gs-suspend.sh" "${BIN}/gs-menu.sh" \
                    "${BIN}/pause.sh" "${SYSMENU}/Game Switcher.sh"
  for emulator in retroarch retroarch32; do
    [ -e "${BIN}/${emulator}" ] && ${SUDO} chmod 777 "${BIN}/${emulator}"
  done
  [ -e "${BIN}/pause.sh.gs-orig" ] && ${SUDO} chmod 777 "${BIN}/pause.sh.gs-orig"
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
fi

say ""
say "Done.  Press the power button briefly while a RetroArch game is running"
say "to snapshot it and open the switcher.  The carousel is also under"
say "Options > Game Switcher."
[ -z "${ASSUME_YES}" ] && sleep 4
exit 0
