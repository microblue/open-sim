#!/usr/bin/env bash
# OpenRC Simulator - is the transmitter reaching this machine?
#
# Reads the kernel joystick device directly, so it answers the question without
# the simulator, the extension or Godot being involved at all. Run it when the
# sticks do nothing and you need to know which side of the USB cable the problem
# is on.
#
# Usage:  scripts/check-transmitter.sh [seconds]
set -euo pipefail

WATCH="${1:-6}"

ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }
bad()  { printf '\033[31mfail\033[0m %s\n' "$*"; }
info() { printf '\033[1m%s\033[0m\n' "$*"; }

info "=== The device ==="
shopt -s nullglob
devices=(/dev/input/js*)
if [ ${#devices[@]} -eq 0 ]; then
    bad "no /dev/input/js* device."
    echo "     The radio is not presenting a USB joystick at all. Put it in"
    echo "     USB Joystick (HID) mode and plug it in - on EdgeTX that is the"
    echo "     popup when the cable goes in, or SYS -> Hardware -> USB Mode."
    exit 1
fi

for device in "${devices[@]}"; do
    name="$(cat "/sys/class/input/$(basename "$device")/device/name" 2>/dev/null || echo unknown)"
    if [ -r "$device" ]; then
        ok "$device  $name"
    else
        bad "$device  $name  - NOT READABLE by this user"
        echo "     Normally logind grants an ACL. Check: getfacl $device"
    fi
done

info ""
info "=== What it is sending ==="
echo "Move every stick through its full travel now - watching for ${WATCH}s."
echo ""

python3 - "$WATCH" <<'PY'
import os, select, struct, sys, time

WATCH = float(sys.argv[1])
EVENT = struct.Struct("IhBB")
JS_EVENT_AXIS = 0x02

fd = os.open("/dev/input/js0", os.O_RDONLY | os.O_NONBLOCK)
value, low, high, changes = {}, {}, {}, {}
deadline = time.time() + WATCH

while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.05)
    if not ready:
        continue
    data = os.read(fd, EVENT.size * 64)
    for i in range(0, len(data), EVENT.size):
        _t, raw, etype, number = EVENT.unpack_from(data, i)
        if not etype & JS_EVENT_AXIS:
            continue
        v = raw / 32767.0
        if number in value and abs(v - value[number]) > 0.01:
            changes[number] = changes.get(number, 0) + 1
        value[number] = v
        low[number] = min(low.get(number, v), v)
        high[number] = max(high.get(number, v), v)
os.close(fd)

if not value:
    print("  the device sent no events at all.")
    raise SystemExit(2)

print("  axis   now      travel seen   moved   looks like")
silent = True
for n in sorted(value):
    span = high[n] - low[n]
    moved = changes.get(n, 0)
    if abs(value[n]) > 1e-6 or span > 1e-6:
        silent = False
    if span > 1.4:
        kind = "swept fully"
    elif span > 0.05:
        kind = "moved a little"
    elif abs(value[n]) > 0.6:
        kind = "resting at one end - throttle or switch"
    elif abs(value[n]) > 0.25:
        kind = "part way - knob or slider"
    else:
        kind = "centred - self-centring stick, or dead"
    print("  ax%-3d %+7.3f  %8.3f      %5d   %s" % (n, value[n], span, moved, kind))

print("")
if silent:
    print("  EVERY CHANNEL IS EXACTLY ZERO AND NOTHING MOVED.")
    print("")
    print("  That is not a position a radio can physically be in - a throttle")
    print("  rests at one end of its travel. The device enumerated but the radio")
    print("  is not driving it. In order of likelihood:")
    print("")
    print("    1. EdgeTX 2.9+ configures USB Joystick PER MODEL.")
    print("       MDL -> USB Joystick -> Mode = Classic.")
    print("       On Advanced the channels must be assigned individually and")
    print("       default to nothing, which reports exactly this.")
    print("    2. The radio is off and merely charging.")
    print("    3. USB mode is not Joystick: SYS -> Hardware -> USB Mode.")
    print("    4. The selected model has no mixes. Check the radio's own")
    print("       channel monitor - if the bars do not move there, the problem")
    print("       is upstream of USB entirely.")
    raise SystemExit(2)

if not changes:
    print("  Channels are live but nothing moved while watching. If you were")
    print("  moving the sticks, the radio is sending a fixed frame.")
    raise SystemExit(2)

print("  The radio is sending. Whatever is wrong is not the connection.")
PY
