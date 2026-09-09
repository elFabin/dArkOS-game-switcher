#!/bin/bash
#############################################################################
# install_case.sh - install into a staging tree, then uninstall, and prove
# every file the installer touched came back exactly as it was.
#############################################################################

set -u

ROOT="$1"

# The caller may have exported these while testing gs-common; the installer
# honours them, and here we want it exercising its real defaults.
unset GS_HOME GS_STATE GS_OPT GS_BIN GS_RUN GS_COMMON GS_MAX_RECENTS GS_SHOW_SPLASH

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

T="${WORK}/tree"
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    printf '    ok   %s\n' "$1"
  else
    printf '    FAIL %s: expected [%s], got [%s]\n' "$1" "$3" "$2"
    FAIL=1
  fi
}

mkdir -p "${T}/usr/local/bin" "${T}/opt/system" \
         "${T}/home/ark/.config/retroarch" "${T}/home/ark/.config/retroarch32"

# A stand-in for the stock dArkOS wrapper, which serves both bitnesses.
for e in retroarch retroarch32; do
  printf '#!/usr/bin/env bash\nemulator=$(basename "$0")\n/opt/retroarch/bin/${emulator} "$@"\n' \
    > "${T}/usr/local/bin/${e}"
  chmod +x "${T}/usr/local/bin/${e}"
done
printf '#!/bin/bash\nsudo systemctl suspend\n' > "${T}/usr/local/bin/pause.sh"
chmod +x "${T}/usr/local/bin/pause.sh"

# retroarch.cfg with three of our four keys already present, so both the
# "rewrite in place" and the "append a missing key" paths get exercised.
for e in retroarch retroarch32; do
  for f in retroarch.cfg retroarch.cfg.bak; do
    cat > "${T}/home/ark/.config/${e}/${f}" <<CFG
menu_driver = "rgui"
savestate_auto_load = "false"
savestate_auto_save = "false"
network_cmd_enable = "false"
video_driver = "gl"
CFG
  done
done

snapshot() { ( cd "${T}" && find . -type f | sort | xargs md5sum ); }
BEFORE="$(snapshot)"

# --- install ---------------------------------------------------------------
"${ROOT}/install.sh" --yes --root "${T}" > "${WORK}/install.log" 2>&1
check "install succeeds" "$?" "0"

check "retroarch is now the shim" \
      "$(grep -c 'gs-shim' "${T}/usr/local/bin/retroarch")" "1"
check "retroarch32 is now the shim" \
      "$(grep -c 'gs-shim' "${T}/usr/local/bin/retroarch32")" "1"
check "the stock retroarch wrapper was kept" \
      "$([ -f "${T}/opt/gameswitcher/orig/retroarch" ] && echo yes || echo no)" "yes"
check "the stock wrapper kept its own name" \
      "$(grep -c 'basename' "${T}/opt/gameswitcher/orig/retroarch")" "1"
check "pause.sh is now the hook" \
      "$(grep -c 'gs-suspend' "${T}/usr/local/bin/pause.sh")" "1"
check "the stock pause.sh was kept" \
      "$(grep -c 'systemctl suspend' "${T}/usr/local/bin/pause.sh.gs-orig")" "1"
check "the Options entry was installed" \
      "$([ -f "${T}/opt/system/Game Switcher.sh" ] && echo yes || echo no)" "yes"

cfg="${T}/home/ark/.config/retroarch/retroarch.cfg"
check "autosave on"    "$(grep -m1 '^savestate_auto_save' "${cfg}" | cut -d'"' -f2)" "true"
check "autoload on"    "$(grep -m1 '^savestate_auto_load' "${cfg}" | cut -d'"' -f2)" "true"
check "net commands on" "$(grep -m1 '^network_cmd_enable' "${cfg}" | cut -d'"' -f2)" "true"
check "screenshot dir set" \
      "$(grep -m1 '^screenshot_directory' "${cfg}" | cut -d'"' -f2)" \
      "/home/ark/.config/gameswitcher/shots"
check "the .bak twin was patched too" \
      "$(grep -m1 '^savestate_auto_save' "${T}/home/ark/.config/retroarch/retroarch.cfg.bak" | cut -d'"' -f2)" "true"
check "retroarch32 was patched too" \
      "$(grep -m1 '^network_cmd_enable' "${T}/home/ark/.config/retroarch32/retroarch.cfg" | cut -d'"' -f2)" "true"

check "the settings file was installed" \
      "$([ -f "${T}/home/ark/.config/gameswitcher/gameswitcher.conf" ] && echo yes || echo no)" "yes"
echo "GS_MAX_RECENTS=99" >> "${T}/home/ark/.config/gameswitcher/gameswitcher.conf"

# Installing twice must not capture the shim as if it were the stock wrapper.
"${ROOT}/install.sh" --yes --root "${T}" >> "${WORK}/install.log" 2>&1
check "reinstalling keeps the real original" \
      "$(grep -c 'gs-shim' "${T}/opt/gameswitcher/orig/retroarch")" "0"
check "reinstalling keeps edited settings" \
      "$(grep -c 'GS_MAX_RECENTS=99' "${T}/home/ark/.config/gameswitcher/gameswitcher.conf")" "1"

# --- uninstall -------------------------------------------------------------
"${ROOT}/uninstall.sh" --yes --root "${T}" > "${WORK}/uninstall.log" 2>&1
check "uninstall succeeds" "$?" "0"

rm -rf "${T}/home/ark/.config/gameswitcher"
AFTER="$(snapshot)"
if [ "${BEFORE}" = "${AFTER}" ]; then
  printf '    ok   the tree is byte-for-byte as it started\n'
else
  printf '    FAIL the tree changed:\n'
  diff <(printf '%s\n' "${BEFORE}") <(printf '%s\n' "${AFTER}") | sed 's/^/         /'
  FAIL=1
fi

# --- Quick Mode must block the install ------------------------------------
printf '#!/bin/bash\n' > "${T}/usr/local/bin/quickmode.sh"
"${ROOT}/install.sh" --yes --root "${T}" > "${WORK}/qm.log" 2>&1
check "Quick Mode blocks the install" "$?" "1"
check "and says why" \
      "$(grep -c 'Quick Mode' "${WORK}/qm.log")" "1"

exit "${FAIL}"
