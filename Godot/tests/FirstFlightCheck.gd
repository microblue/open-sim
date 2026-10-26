# The guided first flight's rules, checked without flying anything.
#
#   godot --headless --path Godot --script res://tests/FirstFlightCheck.gd
#
# Prints one line per check and exits 1 if any failed.
extends SceneTree

const FF := preload("res://ui/FirstFlight.gd")

var _failed: int = 0
var _passed: int = 0


func _initialize() -> void:
	_run()
	print("first flight: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  [ok] %s" % what)
	else:
		_failed += 1
		print("  [FAIL] %s" % what)


func _base(extra: Dictionary = {}) -> Dictionary:
	var s: Dictionary = {
		"input": "keyboard", "mode": 2, "units": "metric", "crashed": false,
		"on_ground": true, "flown": false, "air_s": 0.0, "height": 0.0,
		"throttle": 0.0, "band_s": 0.0, "turned_deg": 0.0,
		"position": Vector3.ZERO, "home": Vector3.ZERO, "heading_deg": 0.0,
		"speed": 0.0, "airspeed": 0.0, "slow_mps": 0.0,
	}
	s.merge(extra, true)
	return s


func _keys(result: Dictionary) -> Array:
	var out: Array = []
	for h in result["hints"]:
		out.append_array(h["keys"])
	return out


func _text(result: Dictionary) -> String:
	var out: String = ""
	for h in result["hints"]:
		out += String(h["text"]) + " | "
	return out


func _run() -> void:
	# 1 Take off
	var r: Dictionary = FF.evaluate(_base(), 1)
	_check(r["step"] == 1 and not r["done"], "parked: still on step 1")
	_check(_keys(r) == ["W"], "parked, keyboard Mode 2: hold W")
	r = FF.evaluate(_base({"mode": 1}), 1)
	_check(_keys(r) == ["UP"], "parked, keyboard Mode 1: throttle is on UP")
	r = FF.evaluate(_base({"throttle": 1.0}), 1)
	_check("DOWN" in _keys(r), "full power, Mode 2: DOWN to lift off")
	r = FF.evaluate(_base({"input": "radio"}), 1)
	_check(_keys(r).is_empty() and "left stick" in _text(r), "radio Mode 2: throttle on the left stick")
	r = FF.evaluate(_base({"input": "radio", "mode": 1}), 1)
	_check("right stick" in _text(r), "radio Mode 1: throttle on the right stick")
	r = FF.evaluate(_base({"on_ground": false, "air_s": 0.5}), 1)
	_check(r["step"] == 1, "airborne 0.5 s: not yet a take-off")
	r = FF.evaluate(_base({"on_ground": false, "air_s": 1.2}), 1)
	_check(r["step"] == 2, "airborne 1.2 s: take-off ticks")

	# 2 Climb to 20 m
	r = FF.evaluate(_base({"on_ground": false, "height": 12.0}), 2)
	_check(r["step"] == 2 and "20 m" in _text(r), "12 m: keep climbing to 20 m")
	r = FF.evaluate(_base({"on_ground": false, "height": 12.0, "units": "imperial"}), 2)
	_check("66 ft" in _text(r), "imperial: the target is in feet")
	r = FF.evaluate(_base({"on_ground": false, "height": 20.5}), 2)
	_check(r["step"] == 3, "20.5 m: climb ticks")

	# 3 Cruise power
	r = FF.evaluate(_base({"on_ground": false, "throttle": 1.0}), 3)
	_check(_keys(r) == ["S"], "full power: tap S")
	r = FF.evaluate(_base({"on_ground": false, "throttle": 0.6, "band_s": 1.0}), 3)
	_check(r["step"] == 3, "in the band for 1 s: not yet")
	r = FF.evaluate(_base({"on_ground": false, "throttle": 0.6, "band_s": 2.1}), 3)
	_check(r["step"] == 4, "in the band for 2 s: cruise ticks")

	# 4 Turn around
	r = FF.evaluate(_base({"on_ground": false, "turned_deg": 90.0}), 4)
	_check(r["step"] == 4 and "LEFT" in _keys(r), "90 degrees: keep turning")
	r = FF.evaluate(_base({"on_ground": false, "turned_deg": -155.0}), 4)
	_check(r["step"] == 5, "155 degrees the other way: turn ticks")

	# 5 Back over the field
	r = FF.evaluate(_base({"on_ground": false, "position": Vector3(0, 30, -200),
			"heading_deg": 0.0}), 5)
	_check(r["step"] == 5 and "behind you" in _text(r), "field behind: says so")
	r = FF.evaluate(_base({"on_ground": false, "position": Vector3(0, 30, -200),
			"heading_deg": 180.0}), 5)
	_check("ahead" in _text(r), "field ahead: says so")
	r = FF.evaluate(_base({"on_ground": false, "position": Vector3(0, 30, -200),
			"heading_deg": 90.0}), 5)
	_check("to your right" in _text(r), "flying east, field to the south: right")
	r = FF.evaluate(_base({"on_ground": false, "position": Vector3(30, 30, -40)}), 5)
	_check(r["step"] == 6, "50 m from home: over the field ticks")
	r = FF.evaluate(_base({"on_ground": false, "position": Vector3(30, 30, -40),
			"been_away": false}), 5)
	_check(r["step"] == 5 and "Fly out" in _text(r), "never left the field: fly out first")
	var a = FF.Tracker.new()
	a.update(0.1, 5, false, false, 0.5, 0.0, 50.0)
	_check(not a.been_away, "tracker: 50 m is not away")
	a.update(0.1, 5, false, false, 0.5, 0.0, 140.0)
	_check(a.been_away, "tracker: 140 m is away")

	# 6 Land
	r = FF.evaluate(_base({"on_ground": false, "height": 10.0, "throttle": 0.6}), 6)
	_check(_keys(r).has("S"), "approach with power: bring it back")
	r = FF.evaluate(_base({"on_ground": false, "height": 2.0, "throttle": 0.0}), 6)
	_check(_keys(r) == ["DOWN"] and "flare" in _text(r), "2 m: ease back to flare")
	r = FF.evaluate(_base({"on_ground": false, "height": 8.0, "airspeed": 6.0,
			"slow_mps": 9.0}), 6)
	_check("Too slow" in _text(r), "slow on approach: nose down, add power")
	r = FF.evaluate(_base({"on_ground": true, "flown": true, "speed": 4.0}), 6)
	_check(r["step"] == 6, "rolling at 4 m/s: not landed yet")
	r = FF.evaluate(_base({"on_ground": true, "flown": true, "speed": 1.0}), 6)
	_check(r["step"] == 7 and r["done"], "stopped on the ground: landed, all done")
	r = FF.evaluate(_base({"on_ground": true, "flown": false, "speed": 0.0}), 6)
	_check(not r["done"], "never left the ground: not a landing")

	# A crash freezes the checklist
	r = FF.evaluate(_base({"crashed": true, "on_ground": false, "height": 30.0}), 2)
	_check(r["step"] == 2 and r["hints"].is_empty(), "crashed: no tick, no hints")

	# Retries
	_check(FF.retry_spawn(1) == "runway", "retry 1 from the runway")
	_check(FF.retry_spawn(2) == "air" and FF.retry_spawn(4) == "air", "retry 2-4 in the air")
	_check(FF.retry_spawn(6) == "approach", "retry 6 on approach")
	_check(FF.retry_altitude(2) < FF.CLIMB_TO_M, "retry 2 starts below the climb target")
	_check(FF.retry_label(3) == "Try again from step 3", "retry label")

	# Checklist
	var items: Array = FF.items(3)
	_check(items.size() == 6, "six items")
	_check(items[0]["done"] and items[1]["done"] and not items[2]["done"], "1-2 ticked at step 3")
	_check(items[2]["current"] and not items[3]["current"], "3 is current")
	_check(FF.items(7)[5]["done"], "all ticked once complete")

	# Tracker: heading change accumulates, signed, only in step 4
	var t = FF.Tracker.new()
	for i in 20:
		t.update(0.1, 4, false, false, 0.6, float(i) * 10.0)
	_check(absf(t.turned_deg - 190.0) < 0.01, "tracker sums a 190 degree turn")
	t.update(0.1, 5, false, false, 0.6, 0.0)
	_check(t.turned_deg == 0.0, "tracker resets the turn on the next step")
	_check(t.band_s > 2.0 and t.flown, "tracker counts the cruise band and flown")
	t.update(0.1, 5, false, false, 0.9, 0.0)
	_check(t.band_s == 0.0, "tracker leaves the band at 90 %")
	var w = FF.Tracker.new()
	w.update(0.1, 4, false, false, 0.5, 170.0)
	w.update(0.1, 4, false, false, 0.5, -170.0)
	_check(absf(w.turned_deg - 20.0) < 0.01, "tracker wraps across 180")
