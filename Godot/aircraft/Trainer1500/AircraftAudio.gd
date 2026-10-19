# OpenRC Simulator - what the aircraft sounds like from where the pilot stands.
#
# Four positional players parented to the aircraft, so distance, stereo position
# and Doppler all come out of the aircraft's actual motion rather than being
# faked. That matters more here than the timbre does: an RC pilot locates and
# judges their model largely by ear, and the pitch rising as it comes towards
# you and falling as it goes away is most of what makes a pass feel real.
#
# The engine loop is generated at SoundBank.REFERENCE_HZ and shifted with
# pitch_scale, so the tone follows rpm exactly - and Godot multiplies its own
# Doppler shift on top of that.
extends Node3D

const BankScript := preload("res://audio/SoundBank.gd")
const SettingsScript := preload("res://ui/Settings.gd")

## Blades passing per revolution. Two-blade prop, so the fundamental the ear
## hears is twice the shaft frequency.
const BLADE_COUNT: float = 2.0
## Beyond this the model is a speck and effectively silent. Real RC audibility
## runs further, but a simulator that stays loud at 300 m sounds wrong indoors.
const MAX_DISTANCE: float = 260.0
## Airspeed at which airframe noise reaches full volume.
const WIND_REFERENCE_MPS: float = 22.0
## How quickly the mix follows the model. Fast enough to catch a throttle chop,
## slow enough that per-frame jitter does not buzz.
const SMOOTHING: float = 12.0

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _engine: AudioStreamPlayer3D
var _wind: AudioStreamPlayer3D
var _roll: AudioStreamPlayer3D
var _impact: AudioStreamPlayer3D
var _stall: AudioStreamPlayer3D
## How loudly the warner is sounding, 0 to 1, eased so it does not chatter on
## and off as the wing brushes the stall.
var _stall_gain: float = 0.0

var _engine_gain: float = 0.0
var _wind_gain: float = 0.0
var _roll_gain: float = 0.0
var _was_crashed: bool = false


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	SettingsScript.ensure_buses()

	_engine = _player("Engine", BankScript.engine(), 0.0)
	_wind = _player("Airflow", BankScript.airflow(), -8.0)
	_roll = _player("GroundRoll", BankScript.ground_roll(), -6.0)
	_impact = _player("Impact", BankScript.impact(), 2.0)
	_impact.autoplay = false

	# The stall warner. Mixed in at the aeroplane, not at the pilot's ear, so
	# it fades with distance like everything else the model does - a warner you
	# cannot hear at two hundred metres is exactly as much use as a real one.
	_stall = _player("StallHorn", BankScript.stall_horn(), -40.0)
	_stall.play()

	# The looping beds run continuously and are mixed with volume, which avoids
	# the click a start/stop on every throttle movement would produce.
	_engine.play()
	_wind.play()
	_roll.play()


func _player(player_name: String, stream: AudioStream, db: float) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = player_name
	player.stream = stream
	player.max_db = db
	player.volume_db = -80.0
	player.max_distance = MAX_DISTANCE
	# Inverse-square is what air actually does, and it is what makes a model
	# fifty metres out sound fifty metres out.
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
	player.unit_size = 6.0
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
	# The world's bus, which the settings screen's game volume drives.
	player.bus = SettingsScript.BUS_GAME
	add_child(player)
	return player


func _process(delta: float) -> void:
	if _sim == null:
		return

	var follow: float = clampf(delta * SMOOTHING, 0.0, 1.0)
	var rpm: float = _sim.get_rpm()
	var airspeed: float = _sim.get_airspeed_mps()
	var on_ground: bool = _sim.is_on_ground()
	var crashed: bool = _sim.has_crashed()

	# --- the stall warner --------------------------------------------------
	# Sounds while the wing is separating and the aeroplane is actually flying.
	# Parked in a breeze the relative wind comes from behind the wing, which is
	# "separated" and is not a stall - a warner that sounds on the ground is a
	# warner a student learns to ignore.
	var flying: bool = not on_ground or airspeed > 6.0
	var separation: float = _sim.get_stalled_fraction()
	var warn: float = 0.0
	if flying and not crashed and separation > 0.05:
		# Full volume by the time a third of the wing has let go, which is
		# early enough to be a warning rather than an epitaph.
		warn = clampf((separation - 0.05) / 0.28, 0.0, 1.0)
	_stall_gain = lerpf(_stall_gain, warn, clampf(delta * 6.0, 0.0, 1.0))
	_stall.volume_db = _gain_to_db(_stall_gain * 0.9)

	# --- the motor ---------------------------------------------------------
	# Blade passing frequency, which is what the ear actually tracks.
	var blade_hz: float = rpm / 60.0 * BLADE_COUNT
	if blade_hz > 1.0:
		_engine.pitch_scale = clampf(blade_hz / BankScript.REFERENCE_HZ, 0.25, 4.0)

	# Loudness rises faster than rpm does - a motor at half rpm is much less
	# than half as loud - so the gain is shaped rather than linear.
	var engine_target: float = 0.0 if crashed else pow(clampf(blade_hz / 320.0, 0.0, 1.0), 0.7)
	_engine_gain = lerpf(_engine_gain, engine_target, follow)
	_engine.volume_db = _gain_to_db(_engine_gain)

	# --- the airframe ------------------------------------------------------
	var wind_target: float = 0.0 if crashed else clampf(airspeed / WIND_REFERENCE_MPS, 0.0, 1.2)
	# Airframe noise goes as roughly the square of speed.
	wind_target = wind_target * wind_target
	_wind_gain = lerpf(_wind_gain, wind_target, follow)
	_wind.volume_db = _gain_to_db(_wind_gain)
	_wind.pitch_scale = clampf(0.75 + airspeed / 40.0, 0.75, 1.6)

	# --- the wheels --------------------------------------------------------
	var ground_speed: float = _sim.get_ground_speed_mps()
	var roll_target: float = 0.0
	if on_ground and not crashed:
		roll_target = clampf(ground_speed / 10.0, 0.0, 1.0)
	_roll_gain = lerpf(_roll_gain, roll_target, follow)
	_roll.volume_db = _gain_to_db(_roll_gain)
	_roll.pitch_scale = clampf(0.6 + ground_speed / 16.0, 0.6, 1.8)

	# --- the crash ---------------------------------------------------------
	if crashed and not _was_crashed:
		_impact.volume_db = 0.0
		_impact.play()
	_was_crashed = crashed


## Silence below the audible floor rather than letting a player idle at a level
## that still sums into the bus across four of them.
func _gain_to_db(gain: float) -> float:
	if gain <= 0.002:
		return -80.0
	return linear_to_db(gain)
