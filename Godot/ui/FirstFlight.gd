# OpenRC Simulator - the guided first flight.
#
# Six things, in order, each a goal rather than a key map: take off, climb,
# settle the power, turn around, come back over the field, land. The checklist
# sits where the aircraft's name usually is, and the hint bar says only how to
# do the CURRENT item, in the words of the controls in use - keycaps for the
# keyboard, stick names for a transmitter, Mode 1 and Mode 2 each told their
# own sticks.
#
# A pure function of a state dictionary, like ContextHints, so the tests can pin
# each rule down without flying anything:
#
#   input        "keyboard" | "radio"
#   mode         1 | 2                      stick mode
#   units        "metric" | "imperial" | "si"
#   crashed      bool
#   on_ground    bool
#   flown        bool                       has left the ground this attempt
#   air_s        seconds continuously airborne
#   height       m above the ground below
#   throttle     0..1
#   band_s       seconds the throttle has been in the cruise band
#   turned_deg   heading change since the turn item began (signed sum, abs)
#   been_away    bool, farther than AWAY_M from home this attempt
#   position     Vector3 (Godot axes)
#   home         Vector3, the spawn point on the strip
#   heading_deg  track over the ground, 0 = -Z, clockwise positive
#   speed        m/s over the ground
#   airspeed     m/s
#   slow_mps     too slow below this on the approach (0 = unknown)
#
# evaluate(state, step) -> {step, hints, done}
#   step   the current item after this frame, 1..6, or 7 once all are done
#   hints  [{keys: Array[String], text: String}] for the hint bar
#   done   true once item 6 is ticked
class_name FirstFlight
extends RefCounted

const Settings := preload("res://ui/Settings.gd")

const STEPS: int = 6
const TAKEOFF_AIR_S: float = 1.0
const CLIMB_TO_M: float = 20.0
const CRUISE_LOW: float = 0.40
const CRUISE_HIGH: float = 0.70
const CRUISE_HOLD_S: float = 2.0
const TURN_DEG: float = 150.0
const HOME_RADIUS_M: float = 60.0
## "Back" over the field means the model was away from it first: farther than
## this since the attempt began. A tight turn that never left the strip does
## not count as coming back.
const AWAY_M: float = 100.0
const LANDED_MPS: float = 2.0
## Below this the take-off roll has barely begun: power first, then lift off.
const FULL_POWER: float = 0.9
## Height for an in-the-air retry of each item. Item 2 starts below the target
## so there is still a climb to make.
const RETRY_ALTITUDE := {2: 12.0, 3: 40.0, 4: 40.0}

const COMPLETE_TITLE: String = "First flight complete."
const COMPLETE_BODY: String = "You took off, turned and landed."


static func evaluate(state: Dictionary, step: int) -> Dictionary:
	var current: int = clampi(step, 1, STEPS + 1)
	if current > STEPS:
		return {"step": current, "hints": [], "done": true}
	if bool(state.get("crashed", false)):
		return {"step": current, "hints": [], "done": false}
	if _complete(state, current):
		current += 1
	if current > STEPS:
		return {"step": current, "hints": [], "done": true}
	return {"step": current, "hints": hints_for(state, current), "done": false}


## Has `step` been achieved by this state?
static func _complete(state: Dictionary, step: int) -> bool:
	var on_ground: bool = bool(state.get("on_ground", true))
	match step:
		1:
			return not on_ground and float(state.get("air_s", 0.0)) > TAKEOFF_AIR_S
		2:
			return not on_ground and float(state.get("height", 0.0)) >= CLIMB_TO_M
		3:
			return not on_ground and float(state.get("band_s", 0.0)) >= CRUISE_HOLD_S
		4:
			return not on_ground and absf(float(state.get("turned_deg", 0.0))) >= TURN_DEG
		5:
			return not on_ground and bool(state.get("been_away", true)) \
					and home_distance(state) <= HOME_RADIUS_M
		6:
			return on_ground and bool(state.get("flown", false)) \
					and float(state.get("speed", 99.0)) < LANDED_MPS
	return false


## Horizontal distance from the model to the spawn point.
static func home_distance(state: Dictionary) -> float:
	var at: Vector3 = state.get("position", Vector3.ZERO)
	var home: Vector3 = state.get("home", Vector3.ZERO)
	return Vector2(at.x - home.x, at.z - home.z).length()


## Where home is relative to the model's track: -180..180, positive = right.
static func home_relative_deg(state: Dictionary) -> float:
	var at: Vector3 = state.get("position", Vector3.ZERO)
	var home: Vector3 = state.get("home", Vector3.ZERO)
	var to_home := Vector2(home.x - at.x, home.z - at.z)
	if to_home.length() < 0.01:
		return 0.0
	var bearing: float = rad_to_deg(atan2(to_home.x, -to_home.y))
	return wrapf(bearing - float(state.get("heading_deg", 0.0)), -180.0, 180.0)


static func _direction_words(relative: float) -> String:
	var a: float = absf(relative)
	if a <= 30.0:
		return "ahead"
	if a >= 135.0:
		return "behind you"
	return "to your right" if relative > 0.0 else "to your left"


## The hint bar for the item being worked on.
static func hints_for(state: Dictionary, step: int) -> Array:
	var keyboard: bool = String(state.get("input", "keyboard")) == "keyboard"
	var mode: int = int(state.get("mode", 2))
	var units: String = String(state.get("units", "metric"))
	# The keyboard swaps throttle and elevator between the modes, exactly as the
	# sticks do (RCInputNode: Mode 1 puts the throttle on the arrows).
	var throttle_up: String = "UP" if mode == 1 else "W"
	var throttle_down: String = "DOWN" if mode == 1 else "S"
	var nose_up: String = "S" if mode == 1 else "DOWN"
	var nose_down: String = "W" if mode == 1 else "UP"
	var throttle_stick: String = "right stick" if mode == 1 else "left stick"
	var elevator_stick: String = "left stick" if mode == 1 else "right stick"

	var on_ground: bool = bool(state.get("on_ground", true))
	var throttle: float = float(state.get("throttle", 0.0))
	var height: float = float(state.get("height", 0.0))

	match step:
		1:
			if keyboard:
				if on_ground and throttle < FULL_POWER:
					return [{"keys": [throttle_up], "text": "Hold for full power"}]
				if on_ground:
					return [{"keys": [nose_up], "text": "Gently, to lift off"},
							{"keys": ["A", "D"], "text": "Keep it straight"}]
				return [{"keys": [nose_up], "text": "A little, to keep climbing"}]
			if on_ground and throttle < FULL_POWER:
				return [{"keys": [], "text": "Throttle up (%s) for full power" % throttle_stick}]
			return [{"keys": [], "text": "Ease the %s back to lift off" % elevator_stick}]
		2:
			var target: String = " ".join(Settings.format_height(CLIMB_TO_M, units))
			if keyboard:
				return [{"keys": [nose_up], "text": "Hold a little to keep climbing to %s" % target}]
			return [{"keys": [], "text": "A little back on the %s to climb to %s"
					% [elevator_stick, target]}]
		3:
			if keyboard:
				if throttle < CRUISE_LOW:
					return [{"keys": [throttle_up], "text": "Tap to bring the power up to about 60 %"}]
				return [{"keys": [throttle_down], "text": "Tap to bring the power back to about 60 %"}]
			return [{"keys": [], "text": "Throttle (%s) back to about the middle" % throttle_stick}]
		4:
			if keyboard:
				return [{"keys": ["LEFT"], "text": "Hold to bank"},
						{"keys": [nose_up], "text": "Then a little, to turn around"}]
			return [{"keys": [], "text": "Bank with the right stick, then a little back on the %s"
					% elevator_stick}]
		5:
			var where: String = _direction_words(home_relative_deg(state))
			var distance: String = " ".join(Settings.format_height(home_distance(state), units))
			if not bool(state.get("been_away", true)):
				# Still over the field after the turn: go out, then come back.
				return [{"keys": [], "text": "Fly out a little way, then come back over the field"}]
			if where == "ahead":
				return [{"keys": [], "text": "The field is ahead, %s. Fly over it" % distance}]
			if keyboard:
				return [{"keys": ["LEFT", "RIGHT"],
						"text": "The field is %s, %s. Turn towards the arrow" % [where, distance]}]
			return [{"keys": [], "text": "The field is %s, %s. Turn towards the arrow"
					% [where, distance]}]
		6:
			return _landing(state, keyboard, throttle_down, throttle_up, nose_up,
					nose_down, throttle_stick, elevator_stick, on_ground, throttle, height)
	return []


static func _landing(state: Dictionary, keyboard: bool, throttle_down: String,
		throttle_up: String, nose_up: String, nose_down: String,
		throttle_stick: String, elevator_stick: String, on_ground: bool,
		throttle: float, height: float) -> Array:
	if on_ground:
		if throttle > 0.05:
			if keyboard:
				return [{"keys": [throttle_down], "text": "Close the throttle and let it roll to a stop"}]
			return [{"keys": [], "text": "Throttle (%s) right back and let it roll to a stop" % throttle_stick}]
		return [{"keys": [], "text": "Let it roll to a stop"}]
	var slow: float = float(state.get("slow_mps", 0.0))
	if slow > 0.0 and height > 1.0 and float(state.get("airspeed", 99.0)) < slow:
		if keyboard:
			return [{"keys": [nose_down, throttle_up], "text": "Too slow: nose down, add power",
					"tone": "warn"}]
		return [{"keys": [], "text": "Too slow: nose down, add power", "tone": "warn"}]
	if throttle > 0.3:
		if keyboard:
			return [{"keys": [throttle_down], "text": "Bring the power right back"},
					{"keys": ["LEFT", "RIGHT"], "text": "Line up with the runway"}]
		return [{"keys": [], "text": "Throttle (%s) right back and line up with the runway" % throttle_stick}]
	if height > 3.0:
		if keyboard:
			return [{"keys": ["LEFT", "RIGHT"], "text": "Line up with the runway"},
					{"keys": [nose_down], "text": "Keep the nose slightly down"}]
		return [{"keys": [], "text": "Line up with the runway, nose slightly down"}]
	if keyboard:
		return [{"keys": [nose_up], "text": "Ease back to flare"}]
	return [{"keys": [], "text": "Ease back on the %s to flare" % elevator_stick}]


## The checklist card: [{text, done, current}].
static func items(step: int, units: String = "metric") -> Array:
	var climb: String = " ".join(Settings.format_height(CLIMB_TO_M, units))
	var texts: Array[String] = ["Take off", "Climb to %s" % climb, "Set cruise power",
			"Turn around", "Fly back over the field", "Land"]
	var out: Array = []
	for i in texts.size():
		var n: int = i + 1
		out.append({"text": texts[i], "done": n < step, "current": n == step})
	return out


## Where a retry of `step` starts: the take-off from the runway, the landing on
## approach, everything else in the air so the take-off is never flown twice.
## The way home (5) starts on approach as well: an in-the-air start is over the
## strip, so it would tick at once.
static func retry_spawn(step: int) -> String:
	if step <= 1:
		return "runway"
	if step >= 5:
		return "approach"
	return "air"


static func retry_altitude(step: int) -> float:
	return float(RETRY_ALTITUDE.get(step, 40.0))


static func retry_label(step: int) -> String:
	return "Try again from step %d" % clampi(step, 1, STEPS)


## The memory evaluate() is handed: how long airborne, how long in the cruise
## band, how far the model has turned since the turn item began. Kept apart from
## evaluate() so that stays a pure function of what it is given.
class Tracker:
	var air_s: float = 0.0
	var band_s: float = 0.0
	var turned_deg: float = 0.0
	var flown: bool = false
	var been_away: bool = false
	var _step: int = -1
	var _last_heading: float = NAN

	func reset() -> void:
		air_s = 0.0
		band_s = 0.0
		turned_deg = 0.0
		flown = false
		been_away = false
		_step = -1
		_last_heading = NAN

	## `heading_deg` is NAN when the model is too slow for a track to mean
	## anything.
	func update(delta: float, step: int, on_ground: bool, crashed: bool,
				throttle: float, heading_deg: float, home_distance: float = -1.0) -> void:
		if crashed:
			return
		if home_distance > AWAY_M:
			been_away = true
		if on_ground:
			air_s = 0.0
		else:
			air_s += delta
			if air_s > 0.6:
				flown = true
		if throttle >= CRUISE_LOW and throttle <= CRUISE_HIGH:
			band_s += delta
		else:
			band_s = 0.0
		if step != _step:
			_step = step
			turned_deg = 0.0
			_last_heading = NAN
		if step == 4:
			if is_nan(heading_deg):
				_last_heading = NAN
			else:
				if not is_nan(_last_heading):
					turned_deg += wrapf(heading_deg - _last_heading, -180.0, 180.0)
				_last_heading = heading_deg
