# Build the Game Switcher carousel.
#
# Core SDL2 only: cleanup_filesystem.sh removes the SDL2_image and SDL2_ttf
# headers from the device image, while needed_packages.txt keeps libsdl2-dev,
# so this is the one SDL library we can count on being buildable on device.

CC      ?= cc
SDL_CFLAGS := $(shell sdl2-config --cflags 2>/dev/null)
SDL_LIBS   := $(shell sdl2-config --libs 2>/dev/null)

ifeq ($(strip $(SDL_LIBS)),)
SDL_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL_LIBS   := $(shell pkg-config --libs sdl2 2>/dev/null)
endif
ifeq ($(strip $(SDL_LIBS)),)
SDL_LIBS := -lSDL2
endif

CFLAGS  ?= -O2 -Wall -Wextra
CFLAGS  += $(SDL_CFLAGS)
LDLIBS  += $(SDL_LIBS) -lm

BIN := gameswitcher
SRC := src/gameswitcher.c
HDR := src/font.h

all: $(BIN)

$(BIN): $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

# Regenerate the baked-in glyph atlas.  Needs python3-pil; the output is
# committed, so this is only run when the font itself changes.
font:
	python3 tools/genfont.py > src/font.h

check: $(BIN)
	./test/run_tests.sh

# Lay out a drop-in for /roms/tools.  Source only, no binary: the carousel is
# compiled on the device, where the SDL2 that matters lives.
package: clean
	rm -rf dist
	mkdir -p dist/GameSwitcher/scripts dist/GameSwitcher/src dist/GameSwitcher/tools \
		dist/GameSwitcher/config
	cp Makefile install.sh uninstall.sh README.md dist/GameSwitcher/
	cp scripts/* dist/GameSwitcher/scripts/
	cp src/gameswitcher.c src/font.h dist/GameSwitcher/src/
	cp tools/genfont.py dist/GameSwitcher/tools/
	cp config/gameswitcher.conf dist/GameSwitcher/config/
	printf '#!/bin/bash\nexec "$$(dirname "$$0")/GameSwitcher/install.sh"\n' \
		> "dist/Install Game Switcher.sh"
	chmod 777 "dist/Install Game Switcher.sh" dist/GameSwitcher/*.sh dist/GameSwitcher/scripts/*
	cd dist && zip -qr GameSwitcher.zip "Install Game Switcher.sh" GameSwitcher
	@echo "dist/GameSwitcher.zip - unzip into /roms/tools on the device"

clean:
	rm -f $(BIN)

.PHONY: all font check package clean
