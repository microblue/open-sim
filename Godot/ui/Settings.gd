# OpenRC Simulator - the pilot's preferences, kept between sessions.
#
# A small static store rather than an autoload: the project has no autoloads,
# every screen already preloads what it uses, and a preloaded script's static
# variables are shared by everything that preloads it. So there is exactly one
# copy of the settings in a running game, and the in-engine tests can drive it
# without a scene.
#
#   const Settings := preload("res://ui/Settings.gd")
#   Settings.ensure_loaded()
#   Settings.get_value("units/system")
#   Settings.set_value("units/system", "imperial")    # saves
#
# The file is a ConfigFile at user://settings.cfg with a schema version in it.
# Two rules about that file matter more than anything else here:
#
#   - A file that does not parse is renamed to settings.cfg.bad, not silently
#     overwritten. Whatever was in it might be the only copy of something the
#     pilot set up; renaming keeps it where a person can find it.
#   - A file written by a NEWER version of the simulator is never overwritten.
#     Running an old build once must not quietly downgrade the preferences of
#     the new one. Values this version understands are still read from it; the
#     session simply does not save.
extends RefCounted

const SCHEMA_VERSION: int = 1
const DEFAULT_PATH: String = "user://settings.cfg"

## Unit systems the readouts can be shown in.
const UNITS: Array[String] = ["metric", "imperial", "si"]
const WINDOW_MODES: Array[String] = ["windowed", "fullscreen"]

## Every setting, with its default. The key is "section/name" in the file.
##
## Units default to SI because that is what the HUD showed before there was a
## choice - m/s and metres - and a preference nobody has touched should not
## change what the screen says.
const DEFAULTS: Dictionary = {
	"audio/game_volume": 0.8,
	"audio/menu_volume": 0.6,
	"display/window_mode": "windowed",
	"display/units": "si",
	"controls/stick_mode": 2,
	"interface/key_hints": true,
	"interface/reduced_motion": false,
	"camera/auto_zoom": true,
	"camera/height_cue": true,
	# The view a flight starts in. Follow keeps the model in frame from behind,
	# which is where a beginner can see what it is doing; the pilot's view is
	# the real thing, standing on the field.
	"camera/view": "follow",
	# A marker on the model when it is small, and an arrow at the edge of the
	# frame when it is out of it.
	"interface/locator": true,
	# Set once the first-run setup (input, stick mode, view) has been seen.
	"onboarding/done": false,
	# Failure practice: the chance a flight has a failure at all (0 is off),
	# whether radio failures are in the pool, and whether the pilot is told.
	"practice/failure_chance": 0.0,
	"practice/radio_failures": false,
	"practice/failure_notice": true,
	# Number keys 4-8 cause a failure on purpose and 9 clears it. Off unless
	# the pilot asks: a beginner mashing keys must not get a dead servo.
	"practice/failure_keys": false,
	# The last loadout flown, so a returning pilot is one key from the air.
	# Empty means "the default".
	"last/aircraft": "",
	"last/scene": "",
	"last/weather": "",
	"last/spawn": "runway",
	# How much the flight overlay shows: clean, standard or detailed.
	"interface/hud": "standard",
	# The two stick gates: auto (keyboard only), on, off.
	"interface/stick_display": "auto",
	# Hints: always, learn (stop offering one after it has been done three
	# times), off. interface/key_hints = false still means off.
	"interface/hints": "learn",
	# Hint id -> times the pilot has done what it asks.
	"hints/learned": {},
	# Ticked "I already fly RC models" in the setup: hints start learned.
	"onboarding/experienced": false,
	"onboarding/first_flight_done": false,
	"onboarding/first_crash_seen": false,
}

## String settings that take one of a fixed set of values.
const ENUMS: Dictionary = {
	"display/units": ["metric", "imperial", "si"],
	"display/window_mode": ["windowed", "fullscreen"],
	"camera/view": ["follow", "pilot", "fpv"],
	"last/spawn": ["runway", "air", "approach"],
	"interface/hud": ["clean", "standard", "detailed"],
	"interface/stick_display": ["auto", "on", "off"],
	"interface/hints": ["always", "learn", "off"],
}

## After this many successes a hint stops offering itself (it still shows if
## the pilot is stuck).
const HINT_LEARNED_AFTER: int = 3

## Audio buses the game mixes into. Created in code if the project has no bus
## layout that declares them, so nothing depends on an editor-saved resource.
const BUS_GAME: String = "Game"
const BUS_MENU: String = "Menu"

static var _values: Dictionary = {}
static var _path: String = DEFAULT_PATH
static var _loaded: bool = false
## True when the file on disk belongs to a newer schema: read, never written.
static var _read_only: bool = false
## What happened on the last load, in words a settings screen can show.
static var _status: String = ""


# ------------------------------------------------------------------ store ---

## Loads the default file once. Safe to call from every screen's _ready.
##
## RC_SETTINGS_PATH points the store elsewhere, so a scripted render or a test
## does not depend on - or disturb - the preferences of whoever runs it.
static func ensure_loaded() -> void:
	if _loaded:
		return
	var path: String = DEFAULT_PATH
	if OS.has_environment("RC_SETTINGS_PATH"):
		path = OS.get_environment("RC_SETTINGS_PATH")
	load_from(path)


## Reads `path` into the store. Never fails: whatever happens, the store ends
## up holding a complete, valid set of values.
static func load_from(path: String) -> void:
	_path = path
	_loaded = true
	_read_only = false
	_status = ""
	_values = DEFAULTS.duplicate(true)

	if not FileAccess.file_exists(path):
		return

	var file := ConfigFile.new()
	var error: Error = file.load(path)
	if error != OK:
		# Renamed, not deleted. Overwritten on the next save it would be gone,
		# and a file that fails to parse is usually one a person edited by hand.
		var bad: String = path + ".bad"
		var absolute: String = ProjectSettings.globalize_path(path)
		var absolute_bad: String = ProjectSettings.globalize_path(bad)
		if FileAccess.file_exists(bad):
			DirAccess.remove_absolute(absolute_bad)
		DirAccess.rename_absolute(absolute, absolute_bad)
		_status = "settings file was unreadable - kept as %s, starting from defaults" \
				% bad.get_file()
		push_warning("Settings: %s did not parse (error %d); moved to %s."
				% [path, error, bad])
		return

	var schema: int = int(file.get_value("meta", "schema", 0))
	if schema > SCHEMA_VERSION:
		_read_only = true
		_status = "saved by a newer version - changes last this session only"

	for key in DEFAULTS:
		var parts: PackedStringArray = String(key).split("/")
		if file.has_section_key(parts[0], parts[1]):
			_values[key] = _validated(key, file.get_value(parts[0], parts[1]))


## Writes the store to the file it was loaded from. Refuses for a newer-schema
## file - see the header.
static func save() -> bool:
	if _read_only:
		return false
	var file := ConfigFile.new()
	file.set_value("meta", "schema", SCHEMA_VERSION)
	for key in DEFAULTS:
		var parts: PackedStringArray = String(key).split("/")
		file.set_value(parts[0], parts[1], _values.get(key, DEFAULTS[key]))
	var error: Error = file.save(_path)
	if error != OK:
		push_warning("Settings: could not write %s (error %d)." % [_path, error])
		return false
	return true


static func get_value(key: String) -> Variant:
	ensure_loaded()
	return _values.get(key, DEFAULTS.get(key))


## Sets, applies whatever the setting drives, and saves.
static func set_value(key: String, value: Variant, persist: bool = true) -> void:
	ensure_loaded()
	if not DEFAULTS.has(key):
		push_warning("Settings: unknown key %s" % key)
		return
	_values[key] = _validated(key, value)
	if key.begins_with("audio/"):
		apply_audio()
	elif key == "display/window_mode":
		apply_window()
	if persist:
		save()


static func is_read_only() -> bool:
	return _read_only


static func status() -> String:
	return _status


static func path() -> String:
	return _path


## Coerces a value read from a file a person may have edited into the type and
## range the game expects. Anything unusable falls back to the default rather
## than to a crash three screens later.
static func _validated(key: String, value: Variant) -> Variant:
	var fallback: Variant = DEFAULTS[key]
	match typeof(fallback):
		TYPE_FLOAT:
			if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
				return fallback
			return clampf(float(value), 0.0, 1.0)
		TYPE_BOOL:
			return bool(value) if typeof(value) == TYPE_BOOL else fallback
		TYPE_INT:
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				return fallback
			if key == "controls/stick_mode":
				return 1 if int(value) == 1 else 2
			return int(value)
		TYPE_STRING:
			var text: String = String(value) if typeof(value) == TYPE_STRING else ""
			if ENUMS.has(key):
				return text if (ENUMS[key] as Array).has(text) else fallback
			return text
		TYPE_DICTIONARY:
			return (value as Dictionary).duplicate(true) if typeof(value) == TYPE_DICTIONARY \
					else (fallback as Dictionary).duplicate(true)
	return fallback


# ---------------------------------------------------------------- applying ---

## Everything that lives outside the screens that read it: the mixer and the
## window. Called once at startup and again whenever one of them changes.
static func apply_all() -> void:
	apply_audio()
	apply_window()


static func ensure_buses() -> void:
	for bus_name in [BUS_GAME, BUS_MENU]:
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		AudioServer.add_bus()
		var index: int = AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, "Master")


static func apply_audio() -> void:
	ensure_buses()
	_apply_bus(BUS_GAME, float(get_value("audio/game_volume")))
	_apply_bus(BUS_MENU, float(get_value("audio/menu_volume")))


static func _apply_bus(bus_name: String, level: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	# Muted rather than sent to -80 dB at zero: "off" should be off.
	AudioServer.set_bus_mute(index, level <= 0.001)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(level, 0.001)))


## Borderless fullscreen, not exclusive: alt-tab to a setup guide and back
## should not cost a mode switch on the monitor.
static func apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var wanted: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_FULLSCREEN \
			if get_value("display/window_mode") == "fullscreen" \
			else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != wanted:
		DisplayServer.window_set_mode(wanted)


# ------------------------------------------------------------------- units ---

## Speed as [number, unit] in the chosen system. Pure, so the HUD and the tests
## agree on what "imperial" means.
static func format_speed(mps: float, system: String) -> PackedStringArray:
	match system:
		"metric":   return PackedStringArray(["%.0f" % (mps * 3.6), "km/h"])
		"imperial": return PackedStringArray(["%.0f" % (mps * 2.236936), "mph"])
	return PackedStringArray(["%.1f" % mps, "m/s"])


static func format_height(metres: float, system: String) -> PackedStringArray:
	if system == "imperial":
		return PackedStringArray(["%.0f" % (metres * 3.280840), "ft"])
	return PackedStringArray(["%.0f" % metres, "m"])


## Vertical speed. Feet per minute is what an imperial vario reads; metres per
## second is what everyone else's does.
static func format_climb(mps: float, system: String) -> String:
	if system == "imperial":
		return "%+.0f ft/min" % (mps * 196.8504)
	return "%+.1f m/s" % mps


static func units() -> String:
	return String(get_value("display/units"))


static func reduced_motion() -> bool:
	return bool(get_value("interface/reduced_motion"))


# ------------------------------------------------------------------- hints ---

## "always", "learn" or "off". The older on/off switch still wins when off.
static func hint_mode() -> String:
	if not bool(get_value("interface/key_hints")):
		return "off"
	return String(get_value("interface/hints"))


static func hint_count(id: String) -> int:
	if bool(get_value("onboarding/experienced")):
		return HINT_LEARNED_AFTER
	return int((get_value("hints/learned") as Dictionary).get(id, 0))


## True once the pilot has done what hint `id` asks often enough that it no
## longer needs offering (only in "learn" mode).
static func hint_learned(id: String) -> bool:
	return hint_mode() == "learn" and hint_count(id) >= HINT_LEARNED_AFTER


## Records one success for hint `id`.
static func hint_success(id: String) -> void:
	var learned: Dictionary = (get_value("hints/learned") as Dictionary).duplicate()
	learned[id] = int(learned.get(id, 0)) + 1
	set_value("hints/learned", learned)


static func reset_hints() -> void:
	set_value("hints/learned", {})
