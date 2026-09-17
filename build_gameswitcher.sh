#!/bin/bash

# Build and install the dArkOS Game Switcher.
#
# This must be sourced AFTER finishing_touches.sh - it needs /opt/system and
# the stock /usr/local/bin/pause.sh to already be in place - and BEFORE
# cleanup_filesystem.sh, which strips the SDL2 headers the carousel needs.
#
# The switcher ships inactive, the same way Quick Mode does: the payload and
# the compiled carousel go onto the image, and the player turns it on from
# Options > Advanced > Game Switcher Setup.  Nothing hooks pause.sh or the
# RetroArch wrapper at build time.

call_chroot "mkdir -p /opt/gameswitcher/scripts /opt/gameswitcher/src /opt/gameswitcher/config"

sudo cp gameswitcher/src/gameswitcher.c Arkbuild/opt/gameswitcher/src/
sudo cp gameswitcher/src/font.h         Arkbuild/opt/gameswitcher/src/
sudo cp gameswitcher/src/png.h          Arkbuild/opt/gameswitcher/src/
sudo cp gameswitcher/Makefile           Arkbuild/opt/gameswitcher/
sudo cp gameswitcher/scripts/gs-install.sh         Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-uninstall.sh       Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-common.sh   Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-shim.sh     Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-suspend.sh  Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-menu.sh     Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-hotkeyd.py  Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/gs-doctor.sh   Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/scripts/pause.sh.gs    Arkbuild/opt/gameswitcher/scripts/
sudo cp gameswitcher/"Game Switcher.sh" Arkbuild/opt/gameswitcher/
sudo cp gameswitcher/"Game Switcher Button.sh" Arkbuild/opt/gameswitcher/
sudo cp gameswitcher/"Game Switcher Diagnostics.sh" Arkbuild/opt/gameswitcher/
sudo cp gameswitcher/config/gameswitcher.conf Arkbuild/opt/gameswitcher/config/

# Compile the carousel now, while libsdl2-dev is still on the image.
call_chroot "cd /opt/gameswitcher &&
  make &&
  strip gameswitcher
  "

sudo mkdir -p Arkbuild/opt/system/Advanced/
sudo cp gameswitcher/"Game Switcher Setup.sh" Arkbuild/opt/system/Advanced/

call_chroot "chown -R ark:ark /opt"
sudo chmod -R 777 Arkbuild/opt/gameswitcher
sudo chmod 777 Arkbuild/opt/system/Advanced/"Game Switcher Setup.sh"
