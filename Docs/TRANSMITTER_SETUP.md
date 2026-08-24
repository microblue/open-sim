# Transmitter setup

## The short version

Put the radio in **USB Joystick (HID)** mode, plug it in, then start the
simulator. A recognised radio is bound automatically and you go straight to the
field — there is no wizard to run.

```bash
godot --path Godot
```

Close the throttle stick once. The motor is interlocked until the simulator has
seen the throttle at idle, and the HUD says so until you do.

## Getting the radio into HID mode

### EdgeTX / OpenTX — RadioMaster, Jumper, FrSky

This is the only family that needs no adapter; the radio is a USB HID device on
its own. The RF module makes no difference — an ELRS Boxer and a stock Boxer
present the same USB device.

1. Plug the radio into the PC with a data USB cable. Charge-only cables are the
   single most common reason a radio never appears.
2. EdgeTX shows a popup with three choices. Pick **USB Joystick (HID)**.
   To skip the popup in future: `SYS` → `Hardware` → `USB Mode` → `Joystick`.
3. Set the model up **AETR** (aileron, elevator, throttle, rudder on channels
   1–4). That is the EdgeTX default and what the built-in profile assumes.

Leave expo and dual rates on the radio. EdgeTX applies them before the value
reaches USB, so the built-in profile deliberately adds none of its own —
otherwise the shaping would be applied twice and the simulator would stop
feeling like your transmitter.

### Radios without native USB

Spektrum (DX/NX), Futaba and FlySky do not present a USB joystick. They need a
dongle into the trainer port, which then appears as a generic game controller.
Those are not in the built-in table, so run the wizard: press `F3`.

### Any game controller

An Xbox or PlayStation pad works for trying the simulator out. Run the wizard —
`F3` — since the axis layout is nothing like a radio's.

## Checking that Linux sees it

```bash
ls /dev/input/js*
cat /sys/class/input/js0/device/name
```

Permissions are usually already correct: logind grants the local user an ACL on
the device. Confirm with `getfacl /dev/input/event*` if a radio is visible to
`ls` but not to the simulator — you are looking for a `user:<you>:rw-` line. Add
yourself to the `input` group only if that line is missing.

## Checking what the simulator sees

```bash
godot --headless --path Godot --script res://tests/AxisMonitor.gd
```

This prints the raw axes on the left and the resulting channel values on the
right, updating four times a second. Move one control at a time and watch which
column follows it. It is the fastest way to tell a radio that is not reaching
the simulator from a binding that is wrong, and it prints a per-axis travel
summary when you stop it.

## Why the input does not go through Godot

`RCInputNode` reads `/dev/input/js*` directly on Linux. Godot's joystick layer
cost this project three separate defects, and the third is the one that made a
correct binding impossible to write:

1. It applies an SDL gamepad mapping to any device whose GUID it recognises,
   including RC transmitters. That mapping folds the device into the six-axis
   Xbox model, so a radio with more channels loses the surplus and the ones that
   survive arrive renumbered and rescaled.
2. It only refreshes an axis when the value changes, so an axis nobody has
   touched since the device was opened reads zero - and zero is the *middle* of
   a throttle's travel, not the bottom.
3. Its axis numbering is its own, and could not be reconciled with the device's
   real axis order from outside: with (2) in play there was no resting state to
   compare against.

Opening the kernel device replays a synthetic event for every axis, so the full
current state arrives immediately and correctly, the axis order is the device's
own, and nothing is remapped. Everywhere other than Linux, the Godot path is
still used - it is correct for a gamepad even where it is wrong for a radio.

## "The transmitter is connected but sending nothing"

The radio enumerates on USB but every channel reads exactly zero. That is not a
position a radio can physically be in - a throttle rests at one end of its
travel, and even a centred gimbal lands a count or two off - so it means the
device is on the bus but the radio is not driving it. In order of likelihood:

- **The radio is off and merely charging.** Plugging in powers the USB interface
  whether or not the radio itself is running.
- **USB mode is not Joystick.** Check `SYS` -> `Hardware` -> `USB Mode`, or the
  popup that appears when the cable goes in.
- **The selected model has no mixes** - a freshly created model, or one whose
  channels are all driven from switches. The radio's own channel monitor page
  is the check: the bars should move when you move the sticks.

The most commonly missed one is the first: **EdgeTX 2.9 and later configure USB
Joystick per model**, on `MDL` -> `USB Joystick`. Set `Mode` to `Classic`. On
`Advanced` the channels have to be assigned individually and default to nothing,
so the device enumerates and reports exactly zero on everything - which looks
identical to a radio that is switched off.

Confirm from outside the simulator, with nothing of ours in the way:

```bash
scripts/check-transmitter.sh          # reads /dev/input/js* directly
```

It reports each axis, how far it travelled while watching, and what it looks
like. Every axis at 0.000 there means the problem is on the radio and no amount
of recalibrating will help.

## The binding is checked against the radio

A binding can be well-formed and still wrong for the device attached, and the
dangerous case is a throttle bound to a stick: the motor then answers the stick
the pilot is steering with. A transmitter at rest already says which axis is
which - a self-centring stick rests in the middle of its travel, a throttle
rests at one end - so the check needs no calibration and no pilot action. A
mismatch is reported at startup and shown on the HUD before the aircraft moves.

See `Source/RCPhysics/Public/RCPhysics/Input/ProfileCheck.h`.

## Two Godot behaviours worth knowing

**Godot applies an SDL gamepad mapping to radios it recognises.** That mapping
folds any device into the six-axis Xbox model, so a radio with more channels
silently loses the surplus and the survivors arrive renumbered and rescaled.
`RCInputNode` removes the mapping as soon as it selects a device, so every
physical axis reaches us unmodified.

**Godot only refreshes an axis when it changes.** An axis nobody has touched
since the device was opened reads zero — and zero is the *middle* of a
throttle's raw travel, not the bottom. That is why the throttle interlock
exists: see `Source/RCPhysics/Public/RCPhysics/Input/ThrottleArming.h`.

## Built-in profiles

`Data/Input/Profiles/*.json`, matched against the USB product name in
`Godot/scenes/Flight.gd`. They are pinned by
`Tests/Regression/TestBuiltinProfiles.cpp`, which checks that each one parses,
binds every channel, rests at zero with the throttle closed, and produces the
stick sense the flight model expects — a pilot who never runs the wizard would
otherwise discover a typo as an aircraft that rolls the wrong way.

A profile you save yourself lands in `user://controller.json` and always wins
over the built-in one. To go back to the built-in, delete it:

```bash
rm "$HOME/.local/share/godot/app_userdata/OpenRC Simulator/controller.json"
```

## If a control goes the wrong way

The axis assignment is fixed by EdgeTX and was measured against a real radio, so
it is the *sense* that varies between setups — mostly elevator, because whether
a forward stick reads positive depends on how the model is set up. Press `F3`,
step to the channel, press `R` to reverse it, `S` to save. That writes
`user://controller.json` and the built-in profile is bypassed from then on.
