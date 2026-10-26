# OpenRC Simulator - what to do next.
#
# The flight overlay used to end in a line of twenty keys. Nobody reads twenty
# keys; a beginner sitting on the runway wants to know the ONE thing that gets
# the aeroplane moving. So the hint bar says only what applies now, in the
# words of the controls actually in use: keycaps for the keyboard, stick names
# for a transmitter, with Mode 1 and Mode 2 each told their own sticks.
#
# A pure function of a state dictionary, so the in-engine tests can pin each
# rule down without flying anything:
#
#   input        "keyboard" | "radio"
#   mode         1 | 2                      stick mode
#   crashed      bool
#   replay       bool                       the replay bar is up
#   armed        bool                       radio throttle interlock released
#   on_ground    bool
#   airspeed     m/s over the ground (a breeze is not a take-off roll)
#   throttle     0..1
#   air_s        seconds airborne on this flight
#   flown        bool                       has left the ground this flight
#
# Newer keys, all optional (a missing key never produces a hint):
#
#   phase          HudPhase phase ("landing" drives the landing script)
#   view           "pilot" | "follow" | "FPV"
#   offscreen_s    seconds the model has been out of frame
#   distance_home  horizontal metres to the field (negative = unknown)
#   home_dir       "ahead" | "behind" | "left" | "right", from the camera
#   height_m       above the ground below
#   air_mps        true airspeed (for the too-slow rule)
#   stall_mps      the aircraft's stall speed
#   aligned        bool, lined up with the runway (default true)
#   teach_view     bool, the one-time "C changes the view" lesson is due
#   hint_mode      "always" | "learn" | "off"   (default "always")
#   learned        Array of hint ids the pilot has learned
#   stuck_s        seconds the current hint has stood without progress
#
# Returns hints, most important first: [{id, keys: Array[String], text, level?}].
# A hint with no keys is a sentence about the transmitter. `level` "warn" is
# drawn amber.
class_name ContextHints
extends RefCounted

## How long after lift-off the "how to turn" hints stay up.
const AIRBORNE_TEACH_S: float = 14.0
## Rolling faster than this, the take-off roll has begun.
const ROLLING_MPS: float = 3.0
## Farther than this from the field, airborne, the pilot is told to turn back.
const FAR_HOME_M: float = 150.0
## Out of frame in the pilot view for longer than this: offer the follow view.
const OFFSCREEN_S: float = 2.0
## Below this height on the landing, flare.
const FLARE_M: float = 3.0
## Below this multiple of the stall speed on the approach, too slow.
const SLOW_FACTOR: float = 1.15
## Escalation: the hint pulses after this long without progress...
const PULSE_S: float = 6.0
## ...and offers the full controls card after this long.
const HELP_S: float = 15.0

## Hints a pilot can learn: after enough successes they stop being offered
## up front, and only come back when the pilot is stuck. Safety hints (too
## slow, far, lost) are never learned away.
const LEARNABLE: Array[String] = ["throttle", "takeoff", "turn", "land", "view"]


## The hints to show now: the candidates, less any the pilot has learned
## (unless they are stuck), plus the controls-card line once stuck long enough.
static func evaluate(state: Dictionary) -> Array:
	var mode_name: String = String(state.get("hint_mode", "always"))
	if mode_name == "off":
		# The arming prompt is not a lesson; it is why the motor will not run.
		var all: Array = candidates(state)
		return all if not all.is_empty() and all[0].get("id", "") == "arm" else []
	var hints: Array = candidates(state)
	var stuck: float = float(state.get("stuck_s", 0.0))
	if mode_name == "learn":
		var learned: Array = state.get("learned", [])
		hints = hints.filter(func(h: Dictionary) -> bool:
			var id: String = h.get("id", "")
			return not (id in LEARNABLE and id in learned) or stuck >= PULSE_S)
	if not hints.is_empty() and escalation(stuck) >= 2:
		hints.append({"id": "help", "keys": ["H"], "text": "See all the controls",
				"line": 2})
	return hints


## 0 = shown, 1 = pulse once (stuck), 2 = add the controls-card line.
static func escalation(stuck_s: float) -> int:
	if stuck_s >= HELP_S:
		return 2
	if stuck_s >= PULSE_S:
		return 1
	return 0


## Every hint that applies, before learning and escalation.
static func candidates(state: Dictionary) -> Array:
	var keyboard: bool = String(state.get("input", "keyboard")) == "keyboard"
	var mode: int = int(state.get("mode", 2))
	if bool(state.get("crashed", false)) or bool(state.get("replay", false)):
		return []

	var throttle_stick: String = "right stick" if mode == 1 else "left stick"
	var elevator_stick: String = "left stick" if mode == 1 else "right stick"
	var throttle_up: String = "UP" if mode == 1 else "W"
	var throttle_down: String = "DOWN" if mode == 1 else "S"
	var nose_up: String = "S" if mode == 1 else "DOWN"
	var nose_down: String = "W" if mode == 1 else "UP"

	if not keyboard and not bool(state.get("armed", true)):
		return [{"id": "arm", "keys": [],
				"text": "Pull the throttle (%s) all the way down to arm the motor" % throttle_stick}]

	var on_ground: bool = bool(state.get("on_ground", true))
	var flown: bool = bool(state.get("flown", false))
	var speed: float = float(state.get("airspeed", 0.0))

	if on_ground and not flown:
		if speed < ROLLING_MPS and float(state.get("throttle", 0.0)) < 0.6:
			if keyboard:
				return [{"id": "throttle", "keys": [throttle_up],
						"text": "Hold to open the throttle and start the take-off"}]
			return [{"id": "throttle", "keys": [],
					"text": "Push the throttle (%s) up to start the take-off" % throttle_stick}]
		if keyboard:
			return [{"id": "takeoff", "keys": ["A", "D"], "text": "Keep it straight"},
					{"id": "takeoff", "keys": [nose_up], "text": "Hold gently to lift off"}]
		return [{"id": "takeoff", "keys": [],
				"text": "Keep it straight with the rudder, then ease the %s back to lift off" % elevator_stick}]

	if on_ground and flown:
		if speed < 1.0:
			return [{"id": "again", "keys": ["R"], "text": "Fly again"},
					{"id": "again", "keys": ["TAB"], "text": "Watch the replay"}]
		return []

	# ---- airborne ----
	var view: String = String(state.get("view", ""))
	if view == "pilot" and float(state.get("offscreen_s", 0.0)) > OFFSCREEN_S:
		return [{"id": "lost", "keys": ["C"], "text": "Press C for the follow view"}]

	if String(state.get("phase", "")) == "landing":
		var stall: float = float(state.get("stall_mps", 0.0))
		var air: float = float(state.get("air_mps", INF))
		if stall > 0.0 and air < stall * SLOW_FACTOR:
			if keyboard:
				return [{"id": "slow", "keys": [nose_down, throttle_up],
						"text": "Too slow: nose down, add power", "level": "warn"}]
			return [{"id": "slow", "keys": [], "text": "Too slow: nose down, add power",
					"level": "warn"}]
		if float(state.get("height_m", INF)) < FLARE_M:
			if keyboard:
				return [{"id": "land", "keys": [nose_up], "text": "Ease back to flare"}]
			return [{"id": "land", "keys": [], "text": "Ease the %s back to flare" % elevator_stick}]
		if not bool(state.get("aligned", true)):
			return [{"id": "land", "keys": [], "text": "Line up with the runway"}]
		if keyboard:
			return [{"id": "land", "keys": [throttle_down], "text": "Throttle back"},
					{"id": "land", "keys": [nose_down], "text": "Keep the nose slightly down"}]
		return [{"id": "land", "keys": [], "text": "Throttle back, keep the nose slightly down"}]

	var home: float = float(state.get("distance_home", -1.0))
	if home > FAR_HOME_M:
		var where: String = {"behind": "behind you", "left": "to your left",
				"right": "to your right", "ahead": "ahead"}.get(
				String(state.get("home_dir", "")), "")
		var text: String = "Turn back. The field is %d m %s" % [roundi(home), where]
		return [{"id": "far", "keys": [], "text": text.strip_edges(), "level": "warn"}]

	if float(state.get("air_s", 0.0)) < AIRBORNE_TEACH_S:
		if keyboard:
			return [{"id": "turn", "keys": ["LEFT", "RIGHT"], "text": "Bank to turn"},
					{"id": "turn", "keys": [nose_up, nose_down], "text": "Nose up / down"},
					{"id": "turn", "keys": [throttle_up, throttle_down], "text": "Throttle"}]
		return [{"id": "turn", "keys": [],
				"text": "Bank with the ailerons, then hold a little back stick to turn"}]

	if bool(state.get("teach_view", false)):
		return [{"id": "view", "keys": ["C"],
				"text": "Changes the view. Try the pilot's view: it is how you see it at a real field"}]
	return []
