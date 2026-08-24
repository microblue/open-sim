# OpenRC Simulator - transmitter diagnostic.
#
# Shows what the radio is actually sending, on two levels at once: the raw axes
# as Godot reports them, and the channel values the flight model will see after
# the active profile is applied. That split is the whole point - it separates
# "the radio is not reaching the simulator" from "the binding is wrong".
#
#   godot --headless --path Godot --script res://tests/AxisMonitor.gd
#
# Move one control at a time and watch which column follows it. Ctrl-C to stop;
# a travel summary prints on the way out.
extends SceneTree

const PROFILE_USER: String = "user://controller.json"
const PROFILE_BUILTIN: String = "Data/Input/Profiles/edgetx_aetr.json"
const AXIS_COUNT: int = 10
const REPORT_INTERVAL: float = 0.25
const SETTLE_SECONDS: float = 0.6

var _transmitter: RCInputNode
var _elapsed: float = 0.0
var _next_report: float = SETTLE_SECONDS
var _listed: bool = false
var _peak: Array[float] = []
var _trough: Array[float] = []


func _initialize() -> void:
	for i in AXIS_COUNT:
		_peak.append(-2.0)
		_trough.append(2.0)

	_transmitter = RCInputNode.new()
	_transmitter.name = "Transmitter"
	root.add_child(_transmitter)

	print("OpenRC transmitter monitor - move one control at a time, Ctrl-C to stop.")


func _process(delta: float) -> bool:
	_elapsed += delta

	# Joypad enumeration is not complete on the first frame; udev has not been
	# polled yet. Let the input node settle before reporting anything.
	if not _listed and _elapsed >= SETTLE_SECONDS:
		_listed = true
		_describe()

	if _listed and _elapsed >= _next_report:
		_next_report += REPORT_INTERVAL
		_report()

	return false


func _describe() -> void:
	if not _transmitter.is_connected():
		print("")
		print("  NO TRANSMITTER DETECTED.")
		print("  The radio must be in USB Joystick (HID) mode and plugged in")
		print("  before the simulator starts. Check with:  ls /dev/input/js*")
		print("")
		return

	print("")
	print("  device : %s" % _transmitter.get_device_name())
	print("  axes   : %d" % _transmitter.get_axis_count())

	if _transmitter.load_profile(PROFILE_USER):
		print("  profile: %s (saved by the wizard)" % PROFILE_USER)
	elif _transmitter.load_profile(_repo_path(PROFILE_BUILTIN)):
		print("  profile: %s (built in)" % PROFILE_BUILTIN)
	else:
		print("  profile: NONE - channels will read neutral until F3 has run")

	print("  bound  : %s" % ("yes" if _transmitter.is_fully_bound() else "no"))

	# What the radio's resting position says each axis is. A self-centring
	# stick sits in the middle of its travel; a throttle or a switch sits at
	# one end. That is enough to tell whether a binding is plausible without
	# anyone touching anything.
	print("")
	print("  at rest:")
	for axis in _transmitter.get_axis_count():
		var value: float = _transmitter.get_raw_axis(axis)
		var verdict: String = "centred - a self-centring stick"
		if absf(value) > 0.6:
			verdict = "at one end - a throttle or a switch"
		elif absf(value) > 0.25:
			verdict = "part way - a knob or slider"
		print("    ax%-2d %+6.3f   %s" % [axis, value, verdict])

	var problem: String = _transmitter.get_profile_problem()
	if problem.is_empty():
		print("")
		print("  the binding is consistent with this radio.")
	else:
		print("")
		print("  PROBLEM: %s" % problem)
	print("")

	var header: String = "     time |"
	for i in AXIS_COUNT:
		header += "   ax%d" % i
	header += "  |"
	for c in _transmitter.get_channel_count():
		header += " %8s" % _transmitter.get_channel_name(c)
	print(header)


func _report() -> void:
	if not _transmitter.is_connected():
		return

	var line: String = "  %7.2fs |" % _elapsed
	for axis in AXIS_COUNT:
		var value: float = _transmitter.get_raw_axis(axis)
		_peak[axis] = maxf(_peak[axis], value)
		_trough[axis] = minf(_trough[axis], value)
		line += " %5.2f" % value

	line += "  |"
	for c in _transmitter.get_channel_count():
		line += " %8.3f" % _transmitter.get_channel(c)
	print(line)


func _finalize() -> void:
	if not _listed or _transmitter == null or not _transmitter.is_connected():
		return
	print("")
	print("  Travel seen per axis (max - min). An axis you swept fully should be")
	print("  near 2.00; one you never touched stays at 0.00.")
	var line: String = "    travel |"
	for axis in AXIS_COUNT:
		var travel: float = 0.0
		if _peak[axis] > -2.0:
			travel = _peak[axis] - _trough[axis]
		line += " %5.2f" % travel
	print(line)


func _repo_path(relative: String) -> String:
	return _transmitter.resolve_data_path(relative)
