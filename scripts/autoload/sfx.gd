extends Node

## Sound effects, synthesized at startup into AudioStreamWAVs (there are no audio files).
## Sfx.play("zap"). A name that doesn't exist plays nothing.

const MIX_RATE: int = 22050
const POOL_SIZE: int = 14

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next: int = 0
var _last_play: Dictionary = {} # name -> msec, so a dozen hits in one frame don't stack up


func _ready() -> void:
	for i: int in range(POOL_SIZE):
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_streams["slash"] = _blade(0.2, 25)
	_streams["slam"] = _fx(0.45, 95.0, 30.0, 0, 1.0, 0.8, 260.0, 7.0, 5)
	_streams["zap"] = _fx(0.16, 1500.0, 260.0, 1, 0.5, 0.25, 3200.0, 14.0, 7)
	_streams["eshot"] = _fx(0.12, 760.0, 420.0, 1, 0.45, 0.1, 2000.0, 16.0, 9)
	_streams["hit"] = _metal(0.16, [880.0, 2420.0, 4310.0], 11)
	_streams["clang"] = _metal(0.3, [520.0, 1390.0, 2870.0], 13)
	_streams["crate"] = _fx(0.2, 210.0, 90.0, 0, 0.5, 0.9, 900.0, 15.0, 15)
	_streams["boom"] = _fx(0.7, 80.0, 28.0, 0, 0.8, 1.0, 330.0, 4.5, 17)
	_streams["die"] = _fx(0.5, 640.0, 70.0, 1, 0.45, 0.6, 700.0, 5.0, 19)
	_streams["hurt"] = _fx(0.18, 320.0, 110.0, 1, 0.6, 0.4, 1200.0, 12.0, 21)
	_streams["dash"] = _whoosh(0.2, 700.0, 2600.0, 23)
	_streams["scrap"] = _notes([1320.0, 1760.0], 0.04, 0, 0.35)
	_streams["kit"] = _notes([523.0, 659.0, 784.0, 1047.0], 0.06, 0, 0.35)
	_streams["buy"] = _notes([660.0, 880.0], 0.045, 1, 0.3)
	_streams["cant"] = _notes([220.0, 180.0], 0.07, 1, 0.3)
	_streams["ui"] = _notes([990.0], 0.03, 1, 0.22)
	_streams["warn"] = _notes([440.0, 440.0], 0.05, 1, 0.25)
	_streams["unlock"] = _notes([523.0, 659.0, 784.0, 1047.0, 1319.0], 0.07, 1, 0.3)
	_streams["alarm"] = _siren(0.9)
	_streams["warp"] = _warp(0.7)


func play(name: String, vol_db: float = -6.0, jitter: float = 0.05) -> void:
	if name not in Net.UI_SOUNDS:
		Net.ev("sfx", [name, vol_db, jitter]) # online co-op: clients hear the host's world too
	if not _streams.has(name) or Game.sfx_volume <= 0.01:
		return
	var now: int = Time.get_ticks_msec()
	if now - int(_last_play.get(name, -1000)) < 35:
		return
	_last_play[name] = now
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % POOL_SIZE
	p.stream = _streams[name]
	p.volume_db = vol_db + linear_to_db(Game.sfx_volume)
	p.pitch_scale = randf_range(1.0 - jitter, 1.0 + jitter)
	p.play()


func has(name: String) -> bool:
	return _streams.has(name)


func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i: int in range(samples.size()):
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var s: AudioStreamWAV = AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = MIX_RATE
	s.stereo = false
	s.data = bytes
	return s


# A pitch sweep (wave 0 = sine, 1 = square) mixed with band-passed noise, decaying fast.
func _fx(length: float, f0: float, f1: float, wave: int, tone_amp: float, noise_amp: float,
		noise_freq: float, decay: float, seed: int) -> AudioStreamWAV:
	var rate: float = float(MIX_RATE)
	var n: int = int(length * rate)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	var bp: BandPass = BandPass.new()
	bp.tune(noise_freq, 1.1, rate)
	var phase: float = 0.0
	for i: int in range(n):
		var t: float = float(i) / rate
		var k: float = float(i) / float(n)
		var f: float = f0 * pow(f1 / f0, k)
		phase = fmod(phase + f / rate, 1.0)
		var tone: float = sin(phase * TAU) if wave == 0 else (0.6 if phase < 0.5 else -0.6)
		var env: float = exp(-t * decay) * minf(1.0, t * 500.0) * (1.0 - k)
		out[i] = (tone * tone_amp + bp.process(rng.randf_range(-1.0, 1.0)) * noise_amp * 2.0) * env
	return _to_stream(_normalize(out, 0.8))


# Struck metal: a click of noise and a few inharmonic partials ringing down.
func _metal(length: float, partials: Array[float], seed: int) -> AudioStreamWAV:
	var rate: float = float(MIX_RATE)
	var n: int = int(length * rate)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	for i: int in range(n):
		var t: float = float(i) / rate
		var v: float = rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.8
		for p: int in range(partials.size()):
			v += sin(TAU * partials[p] * t) * exp(-t * (14.0 + 9.0 * float(p))) / float(p + 1)
		out[i] = v * (1.0 - float(i) / float(n))
	return _to_stream(_normalize(out, 0.7))


## An energy blade swing: a rushing whoosh with a buzzing hum that bends up through the swing.
func _blade(length: float, seed: int) -> AudioStreamWAV:
	var rate: float = float(MIX_RATE)
	var n: int = int(length * rate)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	var bp: BandPass = BandPass.new()
	var phase: float = 0.0
	for i: int in range(n):
		var k: float = float(i) / float(n)
		if i % 16 == 0:
			bp.tune(lerpf(900.0, 3400.0, k), 2.5, rate)
		phase = fmod(phase + lerpf(180.0, 330.0, k) / rate, 1.0)
		var hum: float = (phase * 2.0 - 1.0) * 0.35 + sin(phase * TAU * 2.0) * 0.25
		var env: float = sin(minf(k * 1.4, 1.0) * PI * 0.5) * (1.0 - k) * (1.0 - k) * 1.6
		out[i] = (bp.process(rng.randf_range(-1.0, 1.0)) + hum) * env
	return _to_stream(_normalize(out, 0.6))


func _whoosh(length: float, f0: float, f1: float, seed: int) -> AudioStreamWAV:
	var rate: float = float(MIX_RATE)
	var n: int = int(length * rate)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	var bp: BandPass = BandPass.new()
	for i: int in range(n):
		var k: float = float(i) / float(n)
		if i % 16 == 0:
			bp.tune(lerpf(f0, f1, k), 2.0, rate)
		out[i] = bp.process(rng.randf_range(-1.0, 1.0)) * sin(k * PI)
	return _to_stream(_normalize(out, 0.6))


# A short run of notes. wave 0 = sine, 1 = square.
func _notes(freqs: Array[float], note_len: float, wave: int, amp: float) -> AudioStreamWAV:
	var out: PackedFloat32Array = PackedFloat32Array()
	var per: int = int(note_len * float(MIX_RATE))
	var phase: float = 0.0
	for k: int in range(freqs.size()):
		var tail: int = per * (3 if k == freqs.size() - 1 else 1)
		for i: int in range(tail):
			phase = fmod(phase + freqs[k] / float(MIX_RATE), 1.0)
			var env: float = 1.0 - float(i) / float(tail)
			var v: float = sin(phase * TAU) if wave == 0 else (0.6 if phase < 0.5 else -0.6)
			out.append(v * env * env * amp)
	return _to_stream(out)


func _siren(length: float) -> AudioStreamWAV:
	var rate: float = float(MIX_RATE)
	var n: int = int(length * rate)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	var phase: float = 0.0
	for i: int in range(n):
		var k: float = float(i) / float(n)
		var f: float = 520.0 + 380.0 * sin(k * TAU * 1.5)
		phase = fmod(phase + f / rate, 1.0)
		out[i] = (0.5 if phase < 0.5 else -0.5) * sin(k * PI) * 0.6
	return _to_stream(out)


func _warp(length: float) -> AudioStreamWAV:
	var rate: float = float(MIX_RATE)
	var n: int = int(length * rate)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	var phase: float = 0.0
	var phase2: float = 0.0
	for i: int in range(n):
		var k: float = float(i) / float(n)
		var f: float = 180.0 * pow(9.0, k)
		phase = fmod(phase + f / rate, 1.0)
		phase2 = fmod(phase2 + f * 1.5 / rate, 1.0)
		var shimmer: float = 0.5 + 0.5 * sin(k * TAU * 24.0)
		out[i] = (sin(phase * TAU) * 0.6 + sin(phase2 * TAU) * 0.3 * shimmer) * sin(k * PI) * 0.5
	return _to_stream(out)


func _normalize(buf: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m: float = 0.0001
	for x: float in buf:
		m = maxf(m, absf(x))
	var g: float = peak / m
	for i: int in range(buf.size()):
		buf[i] *= g
	return buf


class BandPass:
	var b0: float = 0.0
	var b2: float = 0.0
	var a1: float = 0.0
	var a2: float = 0.0
	var x1: float = 0.0
	var x2: float = 0.0
	var y1: float = 0.0
	var y2: float = 0.0

	func tune(freq: float, q: float, rate: float) -> void:
		var w0: float = TAU * clampf(freq, 20.0, rate * 0.45) / rate
		var alpha: float = sin(w0) / (2.0 * q)
		var a0: float = 1.0 + alpha
		b0 = alpha / a0
		b2 = -alpha / a0
		a1 = -2.0 * cos(w0) / a0
		a2 = (1.0 - alpha) / a0

	func process(x: float) -> float:
		var y: float = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		return y
