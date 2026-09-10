#!/usr/bin/env python3
"""
gs-hotkeyd.py - fires an action on a clean tap of the Game Switcher hotkey
(the Fn / system_hk button) while a game is running.

Modeled on global/auto_suspend.py's device-scanning shape (same
select.select()-over-fds idiom, same "never grab, just observe" rule from its
comment: a grabbed device would stop the game itself from seeing input) and
on hotkeydaemon/killer_daemon.py's evdev-by-device shape.

Differences from killer_daemon.py, deliberately:
  - matches by which device reports the target keycode in its capabilities,
    not a fixed device-name table, so a wrong GS_HOTKEY_DEVICE only narrows
    the search rather than breaking detection outright
  - fires on a clean tap only: key down, then up, with no other key pressed
    in between and under TapDetector.tap_max seconds.  This is what lets
    every ogage combo that also uses this button (Fn+D-pad brightness,
    Fn+Volume, Fn+Power shutdown) keep working untouched -- we only ever act
    on the presses that were a tap and nothing else.
  - keeps running for the life of the game, firing on every clean tap, rather
    than exiting after the first one.

The tap/combo/long-press state machine is TapDetector, kept free of any
evdev or select() dependency so it can be unit-tested directly (there is no
/dev/uinput in most CI sandboxes to synthesize real input events with) --
see test/hotkey_case.sh.

Started and stopped by gs-shim.sh around each emulator launch, the same way
ppsspp/ppsspp.sh starts and stops watchpsp.sh.

    gs-hotkeyd.py                          # watch, using env vars / defaults
    gs-hotkeyd.py --learn                  # report the next button pressed
"""

import argparse
import os
import select
import subprocess
import sys
import time

from evdev import InputDevice, ecodes, list_devices

# BTN_TRIGGER_HAPPY5 -- the A10 Mini's Fn / system_hk button, confirmed
# against both es_input.cfg.a10mini (system_hk id="16") and the ogage
# a10mini branch's HOTKEY constant.
DEFAULT_CODE = 708

TAP_MAX_SECONDS = 0.6
COOLDOWN_SECONDS = 1.0
LEARN_TIMEOUT_SECONDS = 30


def log(msg):
    print(f"gs-hotkeyd: {msg}", file=sys.stderr, flush=True)


class TapDetector:
    """Clean-tap-vs-combo-vs-long-press state for one watched device.

    feed(code, value, now) is the only entry point: call it for every EV_KEY
    event seen (code = event.code, value = event.value, now = a monotonic
    clock reading), and it returns True exactly on the event that completes
    a clean tap of the target button -- key down, then up, nothing else
    pressed in between, held for less than tap_max seconds, and not within
    cooldown seconds of the last fire.
    """

    def __init__(self, target_code, tap_max=TAP_MAX_SECONDS, cooldown=COOLDOWN_SECONDS):
        self.target_code = target_code
        self.tap_max = tap_max
        self.cooldown = cooldown
        self._pressed_at = None
        self._spoiled = False
        self._last_fire = float("-inf")

    def feed(self, code, value, now):
        if code == self.target_code:
            if value == 1:
                self._pressed_at = now
                self._spoiled = False
            elif value == 0 and self._pressed_at is not None:
                held = now - self._pressed_at
                self._pressed_at = None
                if (not self._spoiled and held < self.tap_max
                        and now - self._last_fire > self.cooldown):
                    self._last_fire = now
                    return True
            # value == 2 (autorepeat) on the target code itself: still held,
            # nothing to decide yet.
        elif value == 1 and self._pressed_at is not None:
            # Some other button went down while the hotkey was held: this is
            # a combo (ogage's job), not a tap (ours).
            self._spoiled = True
        return False


def open_devices(name_filter):
    """Every input device with EV_KEY capability, optionally narrowed by name."""
    devices = {}
    for path in list_devices():
        try:
            dev = InputDevice(path)
            caps = dev.capabilities()
            if ecodes.EV_KEY not in caps:
                continue
            if name_filter and name_filter.lower() not in dev.name.lower():
                continue
            devices[dev.fd] = dev
        except OSError as exc:
            log(f"skipping {path}: {exc}")
    return devices


def learn(name_filter):
    """Watch every candidate device and report the next button pressed."""
    devices = open_devices(name_filter)
    if not devices:
        print("No input devices found.")
        return 1

    print("Press the button you want to use, then let go of it.")
    deadline = time.monotonic() + LEARN_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        readable, _, _ = select.select(devices.keys(), [], [], remaining)
        if not readable:
            break
        for fd in readable:
            dev = devices[fd]
            try:
                for event in dev.read():
                    if event.type == ecodes.EV_KEY and event.value == 1:
                        print(f"GS_HOTKEY_CODE={event.code}")
                        print(f"GS_HOTKEY_DEVICE=\"{dev.name}\"")
                        return 0
            except OSError:
                del devices[fd]
    print("Timed out waiting for a button press.")
    return 1


def watch(code, name_filter, action):
    """Watch every device that can emit `code`; run `action` on a clean tap."""
    devices = {fd: dev for fd, dev in open_devices(name_filter).items()
               if code in dev.capabilities().get(ecodes.EV_KEY, [])}
    if not devices:
        log(f"no device reports code {code}; nothing to watch")
        return 1
    log(f"watching for code {code} on: " + ", ".join(d.name for d in devices.values()))

    detectors = {fd: TapDetector(code) for fd in devices}

    while devices:
        readable, _, _ = select.select(devices.keys(), [], [])
        for fd in readable:
            dev = devices.get(fd)
            if not dev:
                continue
            try:
                events = list(dev.read())
            except OSError:
                log(f"device disappeared: {dev.path}")
                del devices[fd]
                detectors.pop(fd, None)
                continue

            for event in events:
                if event.type != ecodes.EV_KEY:
                    continue
                if detectors[fd].feed(event.code, event.value, time.monotonic()):
                    log("clean tap detected, firing")
                    try:
                        subprocess.run(action, check=False)
                    except OSError as exc:
                        log(f"failed to run {action}: {exc}")

    log("no devices left to watch, exiting")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--learn", action="store_true",
                         help="report the next button pressed instead of watching")
    parser.add_argument("--code", type=int,
                         default=int(os.environ.get("GS_HOTKEY_CODE") or DEFAULT_CODE))
    parser.add_argument("--device", default=os.environ.get("GS_HOTKEY_DEVICE", ""))
    parser.add_argument("--action", default=os.environ.get(
        "GS_HOTKEY_ACTION", "/usr/local/bin/gs-suspend.sh"))
    args = parser.parse_args()

    if args.learn:
        return learn(args.device)
    return watch(args.code, args.device, [args.action])


if __name__ == "__main__":
    sys.exit(main())
