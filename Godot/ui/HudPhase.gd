# OpenRC Simulator - which part of the flight this is, and what the HUD shows.
#
# A pilot parked on the strip does not need a height of 0 m, and a pilot ten
# seconds into the climb does not need to be told the battery is full. The HUD
# shows what the phase of the flight makes relevant and nothing else. Both
# questions - "which phase?" and "what shows in it?" - are pure functions of
# plain values, so the in-engine tests can pin every boundary down without
# flying anything.
#
# EVERY THRESHOLD BELOW IS A DISPLAY AID, NOT PHYSICS.
class_name HudPhase
extends RefCounted

const PARKED := "parked"
const ROLL := "roll"            # on the wheels and moving: take-off or roll-out
const CLIMB := "climb"          # the first seconds after lift-off
const CRUISE := "cruise"
const LANDING := "landing"
const CRASHED := "crashed"

## Below this ground speed on the wheels the model is parked. A breeze reads as
## airspeed on a stationary model, so this is measured over the ground.
const PARKED_MPS: float = 2.0
## How long after lift-off the climb-out lasts.
const CLIMB_S: float = 20.0
## Landing: airborne, lower than this...
const LANDING_HEIGHT_M: float = 15.0
## ...coming down faster than this...
const LANDING_SINK_MPS: float = 0.3
## ...with the power mostly off...
const LANDING_THROTTLE: float = 0.35
## ...and this close to the field, horizontally.
const LANDING_RANGE_M: float = 120.0
## The home indicator shows beyond this distance from the field.
const HOME_SHOW_M: float = 80.0
## Airborne, the battery only shows once it is below this.
const BATTERY_SHOW: float = 0.40


## The phase of the flight. `state` keys, all optional:
##   crashed        bool
##   on_ground      bool    (default true)
##   ground_speed   m/s over the ground
##   air_s          seconds airborne on this flight
##   height_m       above the ground below
##   sink_mps       positive DOWNWARDS
##   throttle       0..1
##   distance_home  horizontal metres to the field; negative = unknown
static func evaluate(state: Dictionary) -> String:
	if bool(state.get("crashed", false)):
		return CRASHED
	if bool(state.get("on_ground", true)):
		return PARKED if float(state.get("ground_speed", 0.0)) < PARKED_MPS else ROLL
	var home: float = float(state.get("distance_home", -1.0))
	if float(state.get("height_m", INF)) < LANDING_HEIGHT_M \
			and float(state.get("sink_mps", 0.0)) > LANDING_SINK_MPS \
			and float(state.get("throttle", 1.0)) < LANDING_THROTTLE \
			and home >= 0.0 and home < LANDING_RANGE_M:
		return LANDING
	if float(state.get("air_s", 0.0)) < CLIMB_S:
		return CLIMB
	return CRUISE


static func is_airborne(phase: String) -> bool:
	return phase == CLIMB or phase == CRUISE or phase == LANDING


## What the HUD shows, as booleans, for a phase in a preset.
##   preset    "clean" | "standard" | "detailed"
##   view      "pilot" | "follow" | "FPV"
##   battery   0..1 state of charge (1 when there is no battery)
##   home_m    horizontal metres to the field; negative = unknown
## Returns {speed, height, throttle, battery, ring, home, identity, legend,
##          chips, hints, engineering, dim}. `dim` is the crash dimming.
static func elements(phase: String, preset: String, view: String = "follow",
		battery: float = 1.0, home_m: float = -1.0) -> Dictionary:
	var crashed: bool = phase == CRASHED
	var airborne: bool = is_airborne(phase)
	var out := {
		# Hidden while parked: "3.2 m/s" on a stationary model in a breeze is
		# the most confusing number a beginner can be shown.
		"speed": phase != PARKED,
		# On the wheels the height is zero and says nothing.
		"height": airborne or crashed,
		"throttle": true,
		"battery": not airborne or battery < BATTERY_SHOW,
		# In the follow view the camera keeps the horizon level and the model
		# itself is the attitude instrument. From the pilot's box at a distance
		# it is not, and the ring earns its place.
		"ring": view == "pilot" and airborne,
		"home": (phase == CRUISE or phase == LANDING) and home_m > HOME_SHOW_M,
		"identity": true,
		"legend": true,
		"chips": not crashed,
		"hints": not crashed,
		"engineering": false,
		"dim": crashed,
	}
	match preset:
		"detailed":
			out["speed"] = true
			out["height"] = true
			out["battery"] = true
			out["ring"] = view != "FPV"
			out["engineering"] = true
		"clean":
			out["throttle"] = false
			out["battery"] = false
			out["ring"] = false
			out["home"] = false
			out["identity"] = false
			out["legend"] = false
			out["chips"] = false
			out["hints"] = false
	return out
