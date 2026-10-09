## Aiming crosshair at the view's centre (in the jeep the camera is the
## turret, so the aim is always there). That centre is DOS's: the middle
## of the 3D view ABOVE the HUD bar, (160, 80) of the 320x200 screen, not
## the middle of the window — the player's camera projects round it
## (fly_camera.aim_screen_point / _update_projection) and every shot is
## aimed through it (playtest 2026-09-15).
##
## On foot: a small green cross — the DOS one is a few pixels, and the
## port's first was three times that ("zameriavaci kriz je prilis velky",
## 2026-09-04). In a vehicle: the DOS reticle CROSHAIR.IMG, the dashed
## circle in the DOS jeep screenshots (2026-09-11). Skynet.exe's aim
## table (0x443ca) names mdmaim.img on foot and croshair.img for the jeep
## and the HK. Its pixels are palette colours; it is drawn as a mask in the
## DOS green, scaled from the 200-line screen to this one — or, when
## MDMDHRES.BSA has it, the 640x480 version (120x120 against 71x59: the
## 320x200 one is squashed for that mode's tall pixels) scaled from 480
## lines, which is sharp instead of a blocky blow-up (playtest, 2026-09-11).
## DOS does the same: in /g mode FUN_00125892 loads it through the
## MDMDHRES.BSA handle (0x31037) when 0x43314 == 1. Scaled by a whole
## number only (_reticle_scale), so its 1-pixel lines stay even.
##
## With HI-RES ART on, the port draws that same art as vectors at the
## window's own resolution instead (_reticle_shape): the art is 120 pixels
## across, and even a whole-number blow-up of it is chunky at 1080 lines
## (playtest 2026-10-09). The circle arcs, the bars, the ticks and their
## end caps are read off CROSHAIR.IMG's pixels and drawn at window lines /
## 480, one art pixel wide, so it is DOS's shape and proportions, only
## sharp. With HI-RES ART off the DOS art is drawn as it is.

extends Control

const VEH_RETICLE: String = "CROSHAIR.IMG"
const GREEN := Color(0.40, 0.95, 0.45, 0.9)

var _player: Node = null
var _veh: int = -1
var _reticle: Texture2D = null
var _reticle_tried: bool = false
var _reticle_unit: float = 200.0       # screen lines the reticle's art is drawn for
var _pt: Vector2 = Vector2(-1.0, -1.0) # where the reticle was last drawn
var _hires_on: bool = false            # Settings.hires_weapons at the last draw
var _shape: Dictionary = {}            # CROSHAIR.IMG as vectors (_reticle_shape)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(queue_redraw)

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	var v: int = int(_player.get("vehicle")) if _player != null else 0
	# A scripted view (the torpedo ride) draws no reticle, nor does the
	# rocket's eye (DOS skips the aim image while 0x400000 is set).
	visible = _player == null or (_player.get("ride_view") != true
		and _player.get("rocket_view") != true)
	if v != _veh:
		_veh = v
		queue_redraw()
	var hi: bool = bool(Settings.hires_weapons)
	if hi != _hires_on:
		_hires_on = hi
		queue_redraw()
	var pt: Vector2 = _aim_point()
	if pt != _pt:
		_pt = pt
		queue_redraw()

## The projection centre in this control's pixels (it fills the viewport);
## the window's middle when there is no player to ask.
func _aim_point() -> Vector2:
	if _player != null and is_instance_valid(_player) and _player.has_method("aim_screen_point"):
		return _player.call("aim_screen_point")
	return size * 0.5

## CROSHAIR.IMG as a white mask, loaded once.
func _vehicle_reticle() -> Texture2D:
	if _reticle_tried:
		return _reticle
	_reticle_tried = true
	var main = get_tree().current_scene
	if main == null or not main.has_method("_load_panel_texture"):
		return null
	var tex: Texture2D = main.call("_load_panel_texture", VEH_RETICLE, true, true)
	if tex == null:
		return null
	_reticle_unit = 480.0 if tex.get_width() >= 100 else 200.0
	var img: Image = tex.get_image()
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	if _reticle_unit == 480.0:
		_shape = _reticle_shape(img)
	for y in img.get_height():
		for x in img.get_width():
			img.set_pixel(x, y, Color(1, 1, 1, img.get_pixel(x, y).a))
	_reticle = ImageTexture.create_from_image(img)
	return _reticle

## CROSHAIR.IMG's pixels as drawing elements, in art pixels from the art's
## centre (its size / 2, where the port has always put the view centre):
##   "arcs":  [radius, from, to] - a run of pixels on one circle round the
##            centre. DOS's 640x480 art has eight: radius 59.5, 6-28
##            degrees either side of the horizontal and 7-28 degrees
##            either side of the vertical (gaps round the end ticks).
##   "rects": Rect2 - every other pixel, as row runs merged downwards: the
##            cross bars, the ticks and their 3-pixel end caps.
## The art's straight elements are one pixel wide ON pixel 60 of 120, half
## a pixel off the circle's centre (60.0, the arcs' pixels are symmetric
## round it); a straight piece centred on that pixel moves the half pixel,
## so the cross runs through the view centre. An art with no circle comes
## out as rects alone - still sharp, drawn at the exact scale.
static func _reticle_shape(img: Image) -> Dictionary:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var ctr := Vector2(w, h) * 0.5
	var on := {}
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a > 0.5:
				on[Vector2i(x, y)] = true
	# The circle: the radius most pixels share (1-pixel bins), refined to
	# the mean distance of the pixels within a pixel of it.
	var bins := {}
	for p: Vector2i in on:
		var k: int = roundi((Vector2(p) + Vector2(0.5, 0.5) - ctr).length())
		bins[k] = int(bins.get(k, 0)) + 1
	var r0: int = -1
	for k: int in bins:
		if k >= 8 and int(bins[k]) >= 24 and (r0 < 0 or int(bins[k]) > int(bins[r0])):
			r0 = k
	var arcs: Array = []
	var rest := on.duplicate()
	if r0 > 0:
		var ang: Array = []
		var sum: float = 0.0
		for p: Vector2i in on:
			var v: Vector2 = Vector2(p) + Vector2(0.5, 0.5) - ctr
			if absf(v.length() - r0) <= 1.0:
				ang.append([atan2(v.y, v.x), p])
				sum += v.length()
		var rad: float = sum / maxf(1.0, ang.size())
		# Split the ring by angle where neighbours are > 2 pixels apart,
		# starting after the widest gap so no run straddles +-PI.
		ang.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		var n: int = ang.size()
		var start: int = 0
		var widest: float = -1.0
		for i in n:
			var gap: float = fposmod(float(ang[(i + 1) % n][0]) - float(ang[i][0]), TAU) \
				if n > 1 else TAU
			if gap > widest:
				widest = gap
				start = (i + 1) % n
		var runs: Array = []
		var cur: Array = []
		for j in n:
			var e: Array = ang[(start + j) % n]
			if not cur.is_empty():
				var prev: float = float(cur[cur.size() - 1][0])
				if fposmod(float(e[0]) - prev, TAU) * rad > 2.0:
					runs.append(cur)
					cur = []
			cur.append(e)
		if not cur.is_empty():
			runs.append(cur)
		for run: Array in runs:
			var a0: float = float(run[0][0])
			var span: float = fposmod(float(run[run.size() - 1][0]) - a0, TAU)
			# A run of a few pixels is the end of a bar or a cap that only
			# happens to touch the ring: it stays a rect.
			if span * rad < 4.0:
				continue
			var pad: float = 0.5 / rad
			arcs.append([rad, a0 - pad, a0 + span + pad])
			for e: Array in run:
				rest.erase(e[1])
	# Everything else: row runs, merged down while the next row repeats them.
	var rects: Array = []
	var growing := {}      # Vector2i(x0, x1) -> Rect2 still growing
	for y in h:
		var row := {}
		var x: int = 0
		while x < w:
			if not rest.has(Vector2i(x, y)):
				x += 1
				continue
			var x0: int = x
			while x < w and rest.has(Vector2i(x, y)):
				x += 1
			row[Vector2i(x0, x)] = true
		for key: Vector2i in growing.keys():
			if row.has(key):
				var r: Rect2 = growing[key]
				r.size.y += 1.0
				growing[key] = r
				row.erase(key)
			else:
				rects.append(growing[key])
				growing.erase(key)
		for key: Vector2i in row:
			growing[key] = Rect2(key.x, y, key.y - key.x, 1)
	for key: Vector2i in growing:
		rects.append(growing[key])
	# Centre the straight pieces that sit on the centre pixel, per
	# connected piece (a bar and its end cap move together).
	var piece := {}
	var boxes: Array = []
	for i in rects.size():
		if piece.has(i):
			continue
		var stack: Array = [i]
		piece[i] = boxes.size()
		var box: Rect2 = rects[i]
		while not stack.is_empty():
			var a: Rect2 = rects[stack.pop_back()]
			box = box.merge(a)
			for j in rects.size():
				if not piece.has(j) and a.grow(0.5).intersects(rects[j]):
					piece[j] = boxes.size()
					stack.append(j)
		boxes.append(box)
	var out_rects: Array = []
	for i in rects.size():
		var box: Rect2 = boxes[int(piece[i])]
		var shift := Vector2.ZERO
		if is_equal_approx(box.get_center().x, ctr.x + 0.5):
			shift.x = -0.5
		if is_equal_approx(box.get_center().y, ctr.y + 0.5):
			shift.y = -0.5
		var r: Rect2 = rects[i]
		out_rects.append(Rect2(r.position - ctr + shift, r.size))
	return {"arcs": arcs, "rects": out_rects}

## The vector reticle round `c`, one art pixel = window lines / 480 (the
## art's own screen), in this control's units. Rects have their edges on
## whole window pixels, so a straight line keeps one width along its
## length and the pieces of a bar meet without a seam; the arcs are
## antialiased lines one art pixel wide.
func _draw_shape(c: Vector2) -> void:
	var xf: Transform2D = get_viewport().get_final_transform() \
		* get_global_transform_with_canvas()
	var inv: Transform2D = xf.affine_inverse()
	var s: float = size.y / _reticle_unit
	var k: float = maxf(xf.get_scale().y, 0.001)
	for r: Rect2 in _shape["rects"]:
		var a: Vector2 = (xf * (c + r.position * s)).round()
		var b: Vector2 = (xf * (c + r.end * s)).round().max(a + Vector2.ONE)
		var ia: Vector2 = inv * a
		draw_rect(Rect2(ia, inv * b - ia), GREEN)
	for arc: Array in _shape["arcs"]:
		var rad: float = float(arc[0]) * s
		var a0: float = float(arc[1])
		var a1: float = float(arc[2])
		var pts: int = maxi(8, ceili((a1 - a0) * rad * k / 3.0))
		draw_arc(c, rad, a0, a1, pts, GREEN, s, true)

## How many window pixels one pixel of the reticle art takes: a WHOLE
## number. DOS blits CROSHAIR.IMG 1:1 onto its 640x480 (or 320x200)
## screen (FUN_00126016 → FUN_0013af00 at the view centre 0x3e230/34,
## no scaling). The port scaled it by window lines / 480 — 2.25 at 1080
## — and with nearest sampling that drew the 1-pixel lines 2 or 3 pixels
## thick by turns and stair-stepped the arcs, the "low-res" look
## (playtest 2026-10-09). The nearest whole step keeps every line the
## same width; the reticle comes out within half a step of DOS's share
## of the screen (240 px at 1080 instead of 270).
func _reticle_scale(window_lines: float) -> float:
	return maxf(1.0, roundf(window_lines / _reticle_unit))

func _draw() -> void:
	var c: Vector2 = _aim_point()
	if _veh > 0:
		var tex := _vehicle_reticle()
		if tex != null and _hires_on and not _shape.is_empty():
			_draw_shape(c)
			return
		if tex != null:
			# Sized and placed in WINDOW pixels: this control lives on the
			# 1280x720 canvas the stretch mode scales up (1.5x at 1080).
			var xf: Transform2D = get_viewport().get_final_transform() \
				* get_global_transform_with_canvas()
			var k: float = maxf(xf.get_scale().y, 0.001)
			var sz: Vector2 = tex.get_size() * (_reticle_scale(size.y * k) / k)
			var tl: Vector2 = xf.affine_inverse() * (xf * (c - sz * 0.5)).round()
			draw_texture_rect(tex, Rect2(tl, sz), false, GREEN)
			return
	var col := Color(0.55, 1.0, 0.65, 0.85)
	var shadow := Color(0.0, 0.0, 0.0, 0.6)
	var gap := 4.0
	var ln := 8.0
	var dirs: Array[Vector2] = [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
	for d in dirs:
		var a: Vector2 = c + d * gap
		var b: Vector2 = c + d * (gap + ln)
		draw_line(a + Vector2.ONE, b + Vector2.ONE, shadow, 2.0)
		draw_line(a, b, col, 1.0)
	draw_circle(c, 1.0, col)
