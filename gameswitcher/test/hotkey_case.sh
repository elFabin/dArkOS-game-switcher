#!/bin/bash
#############################################################################
# hotkey_case.sh - exercise gs-hotkeyd.py's tap/combo/long-press logic.
#
# There is no /dev/uinput in most build/CI sandboxes to synthesize real
# evdev events with, so TapDetector (gs-hotkeyd.py's tap-vs-combo-vs-long-
# press state machine) is kept free of any evdev or select() dependency and
# is exercised directly here with synthetic (code, value, time) event
# tuples instead of a real input device.  This is the same coverage the
# plan called for -- clean tap fires; a tap with another button held does
# not; a long press does not -- just fed in through TapDetector.feed()
# rather than through the kernel.
#############################################################################

set -u

ROOT="$1"

python3 - "${ROOT}/scripts/gs-hotkeyd.py" <<'PYEOF'
import importlib.util
import sys

sys.dont_write_bytecode = True  # don't litter scripts/__pycache__
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("gs_hotkeyd", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
TapDetector = mod.TapDetector

FAIL = 0
TARGET = 708
OTHER = 305  # BTN_EAST -- any button that isn't the target.


def check(name, got, want):
    global FAIL
    if got == want:
        print(f"    ok   {name}")
    else:
        FAIL = 1
        print(f"    FAIL {name}: expected [{want}], got [{got}]")


# --- a clean tap fires ------------------------------------------------------
d = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
check("down does not fire",        d.feed(TARGET, 1, 0.0), False)
check("a quick clean tap fires",   d.feed(TARGET, 0, 0.1), True)

# --- another button held during the press spoils the tap (ogage's combos) --
d = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
d.feed(TARGET, 1, 0.0)
check("another key down mid-hold", d.feed(OTHER, 1, 0.05), False)
check("release after a combo does not fire",
      d.feed(TARGET, 0, 0.1), False)

# --- a long press does not fire --------------------------------------------
d = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
d.feed(TARGET, 1, 0.0)
check("release after a long hold does not fire",
      d.feed(TARGET, 0, 1.0), False)

# --- autorepeat on the target itself does not spoil or fire ----------------
d = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
d.feed(TARGET, 1, 0.0)
check("autorepeat of the held button itself is ignored",
      d.feed(TARGET, 2, 0.2), False)
check("a clean tap still fires after autorepeat noise",
      d.feed(TARGET, 0, 0.3), True)

# --- cooldown blocks a second tap too soon, then allows a later one --------
d = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
d.feed(TARGET, 1, 0.0)
check("first tap fires",  d.feed(TARGET, 0, 0.1), True)
d.feed(TARGET, 1, 0.2)
check("second tap within cooldown does not fire",
      d.feed(TARGET, 0, 0.3), False)
d.feed(TARGET, 1, 2.0)
check("a later tap past cooldown fires",
      d.feed(TARGET, 0, 2.1), True)

# --- release with no matching press (e.g. we started mid-hold) is inert ---
d = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
check("an unmatched release does not fire",
      d.feed(TARGET, 0, 0.0), False)

# --- events for a different device's TapDetector are independent ----------
a = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
b = TapDetector(TARGET, tap_max=0.6, cooldown=1.0)
a.feed(TARGET, 1, 0.0)
check("one device's press does not arm another's detector",
      b.feed(TARGET, 0, 0.1), False)
check("the pressed device's own release still fires",
      a.feed(TARGET, 0, 0.1), True)

sys.exit(FAIL)
PYEOF
