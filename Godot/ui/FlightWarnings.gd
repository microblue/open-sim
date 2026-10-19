# OpenRC Simulator - the warning chips, as a pure function.
#
# The HUD's banner says the one thing that needs saying - a failure, a crash, a
# stall. These chips are the quieter tier underneath it: short, steady facts a
# pilot should fold into what they are already doing, several of which can be
# true at once. They are worked out here from plain numbers, not from the
# simulation node, so the in-engine tests can state exactly when each one shows.
#
# EVERY THRESHOLD BELOW IS A DISPLAY AID, NOT PHYSICS. They were chosen for what
# a pilot can usefully act on, not derived from the flight model, and moving
# one changes when a chip appears and nothing else.
extends RefCounted

## LOW · SINKING. Sinking faster than this...
const LOW_SINK_MPS: float = 2.0
## ...and fewer than this many seconds from the ground at that rate. Two
## seconds is about the time it takes a trainee to see it, decide, and get the
## throttle and elevator moving.
const LOW_TIME_S: float = 2.0

## FAR · COME CLOSER. A wingspan smaller than this on screen - in the interface's
## 1080-line space, at the narrowest the pilot view will go - is a model whose
## attitude can no longer be read. Below that a pilot is guessing which way up
## it is, which is how models are lost.
const FAR_SPAN_PX: float = 30.0

## BATTERY LOW. A LiPo holds its voltage and then falls off a cliff; at a fifth
## left there is still a comfortable circuit and landing, and not much more.
const BATTERY_LOW: float = 0.20

const WARN: String = "warn"
const DANGER: String = "danger"


## How many pixels tall `span_m` appears at `distance_m` through a camera whose
## vertical field is `fov_deg`, on a frame `frame_height_px` tall.
static func span_pixels(span_m: float, distance_m: float, fov_deg: float,
						frame_height_px: float) -> float:
	if distance_m <= 0.01 or fov_deg <= 0.01:
		return frame_height_px
	var subtended: float = 2.0 * atan(span_m * 0.5 / distance_m)
	return subtended / deg_to_rad(fov_deg) * frame_height_px


## The chips to show, in display order. Each is {id, text, level}.
##
## `state` keys, all optional (a missing key never produces a chip):
##   crashed        bool    nothing shows on a wreck - the banner has it
##   airborne       bool
##   sink_mps       float   positive DOWNWARDS
##   height_m       float   above the ground directly below
##   span_px        float   wingspan on screen at the narrowest pilot zoom;
##                          negative when not in the pilot view
##   battery        float   0..1 state of charge
##   has_battery    bool
static func evaluate(state: Dictionary) -> Array[Dictionary]:
	var chips: Array[Dictionary] = []
	if bool(state.get("crashed", false)):
		return chips

	var sink: float = float(state.get("sink_mps", 0.0))
	var height: float = float(state.get("height_m", INF))
	if bool(state.get("airborne", false)) and sink > LOW_SINK_MPS \
			and height / sink < LOW_TIME_S:
		chips.append({"id": "low", "text": "LOW · SINKING", "level": DANGER})

	var span_px: float = float(state.get("span_px", -1.0))
	if span_px >= 0.0 and span_px < FAR_SPAN_PX:
		chips.append({"id": "far", "text": "FAR · COME CLOSER", "level": WARN})

	if bool(state.get("has_battery", false)) \
			and float(state.get("battery", 1.0)) < BATTERY_LOW:
		chips.append({"id": "battery", "text": "BATTERY LOW", "level": WARN})

	return chips
