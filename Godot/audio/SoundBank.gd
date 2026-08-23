# OpenRC Simulator - procedurally generated audio.
#
# Every sound here is synthesised at load time rather than shipped as a file.
# Three reasons, in the order they mattered:
#
#   1. An electric model's noise IS its rpm. A recorded loop pitched up and down
#      drifts away from what the motor is doing; a waveform built from the blade
#      passing frequency does not.
#   2. The repository stays text. Everything else in this project is readable
#      and diffable, and a binary blob of engine noise would be the one thing
#      nobody could review.
#   3. It is tunable from the same place as the aircraft. Blade count changes
#      the sound because it changes the harmonic series, not because someone
#      swapped a sample.
#
# Loops are built to an exact whole number of cycles of their fundamental, so
# they repeat without a click. The engine loop is generated at REFERENCE_HZ and
# the player shifts it with pitch_scale, which is also what lets Godot layer
# Doppler on top - the aircraft passing the pilot is most of what makes an RC
# simulator sound right.
class_name SoundBank
extends RefCounted

const MIX_RATE: int = 22050
## Blade passing frequency the engine loop is generated at. Everything else is
## a pitch_scale away from this.
const REFERENCE_HZ: float = 100.0
const ENGINE_SECONDS: float = 0.5
const NOISE_SECONDS: float = 1.5


## An electric power system: the prop's blade passing tone, the motor's own
## higher electrical whine, and the broad rush of disturbed air.
static func engine() -> AudioStreamWAV:
	var frames: int = int(MIX_RATE * ENGINE_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(frames)

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5CA1AB1E
	var rumble: float = 0.0

	for i in frames:
		var phase: float = TAU * REFERENCE_HZ * float(i) / float(MIX_RATE)
		var value: float = 0.0

		# Blade passing tone. A propeller is not a sine - the pressure pulse as
		# each blade goes past is closer to a narrow spike, which is why the
		# harmonics fall off slowly and why a model sounds buzzy rather than
		# smooth.
		var harmonic: int = 1
		while harmonic <= 9:
			var amplitude: float = 1.0 / pow(float(harmonic), 1.35)
			value += amplitude * sin(phase * float(harmonic))
			harmonic += 1
		value *= 0.42

		# Motor whine: the electrical commutation sits well above the blade
		# tone and is what separates an electric model from a glow engine.
		value += 0.10 * sin(phase * 13.0)
		value += 0.05 * sin(phase * 21.0)

		# Air rushing off the disc. Low-passed so it reads as air rather than
		# hiss, and mixed low - it comes up with throttle in the player.
		rumble = rumble * 0.86 + rng.randf_range(-1.0, 1.0) * 0.14
		value += rumble * 0.22

		samples[i] = value * 0.55

	return _to_stream(samples, true)


## Airframe noise: the rush over the wing and fuselage. Broadband, shaped so it
## sits under the engine rather than fighting it.
static func airflow() -> AudioStreamWAV:
	var frames: int = int(MIX_RATE * NOISE_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(frames)

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x0A17F10D
	var low: float = 0.0
	var mid: float = 0.0

	for i in frames:
		var white: float = rng.randf_range(-1.0, 1.0)
		low = low * 0.93 + white * 0.07
		mid = mid * 0.72 + white * 0.28
		samples[i] = (low * 0.75 + mid * 0.45) * 0.8

	_crossfade_ends(samples, int(MIX_RATE * 0.05))
	return _to_stream(samples, true)


## Wheels on grass: low, irregular, and only there while rolling.
static func ground_roll() -> AudioStreamWAV:
	var frames: int = int(MIX_RATE * NOISE_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(frames)

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9E0110ED
	var low: float = 0.0

	for i in frames:
		# Heavily low-passed noise with occasional grains, which is what a small
		# wheel over grass and gravel actually sounds like.
		var white: float = rng.randf_range(-1.0, 1.0)
		if rng.randf() < 0.004:
			white *= 4.0
		low = low * 0.975 + white * 0.025
		samples[i] = low * 3.2

	_crossfade_ends(samples, int(MIX_RATE * 0.05))
	return _to_stream(samples, true)


## The moment of the crash: a broadband crack decaying fast, with a bit of body
## to it so it reads as a model hitting the ground rather than a click.
static func impact() -> AudioStreamWAV:
	var frames: int = int(MIX_RATE * 0.55)
	var samples := PackedFloat32Array()
	samples.resize(frames)

	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC7A54ED
	var body: float = 0.0

	for i in frames:
		var t: float = float(i) / float(frames)
		var envelope: float = pow(1.0 - t, 3.5)
		var white: float = rng.randf_range(-1.0, 1.0)
		body = body * 0.90 + white * 0.10
		# A short low thud under the crack: airframe and ground, not just noise.
		var thud: float = sin(TAU * 70.0 * float(i) / float(MIX_RATE)) * pow(1.0 - t, 8.0)
		samples[i] = (white * 0.35 + body * 0.9 + thud * 0.5) * envelope

	return _to_stream(samples, false)


# ------------------------------------------------------------------ helpers --

## Blend the tail of a buffer into its head so a looping noise bed has no seam.
## Tonal loops do not need this - they are generated at a whole number of
## cycles - but noise has no period to land on.
static func _crossfade_ends(samples: PackedFloat32Array, blend: int) -> void:
	var count: int = samples.size()
	if blend <= 0 or blend * 2 >= count:
		return
	for i in blend:
		var t: float = float(i) / float(blend)
		var head: float = samples[i]
		var tail: float = samples[count - blend + i]
		samples[i] = head * t + tail * (1.0 - t)


static func _to_stream(samples: PackedFloat32Array, looping: bool) -> AudioStreamWAV:
	var frames: int = samples.size()
	var data := PackedByteArray()
	data.resize(frames * 2)

	var peak: float = 0.0
	for value in samples:
		peak = maxf(peak, absf(value))
	var scale: float = 32767.0 / maxf(peak, 1e-6)
	# Leave a little headroom so summing several players cannot clip the bus.
	scale *= 0.85

	for i in frames:
		data.encode_s16(i * 2, int(clampf(samples[i] * scale, -32767.0, 32767.0)))

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	if looping:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = frames
	return stream
