## Autoload: game controller support.
##
## While a pad is connected:
##   * in the game, the sticks and buttons drive the player the way the touch
##     overlay does (ui_move / ui_look / ui_vert / ui_sprint / ui_fire) and the
##     one-shot actions call the player directly. The touch overlay hides.
##   * in a menu, an overlay or the briefing, the left stick (or the D-pad)
##     moves a visible cursor and A clicks, so the mouse-driven screens work.
##
## Layout (Nintendo labels; the indices are Godot's JoyButton / JoyAxis):
##   left stick   move                right stick   look
##   ZR           fire (hold)         ZL            throw
##   R / L        next / previous weapon (also D-pad right / left)
##   B            jump (hold)         Y             crouch / sink (hold)
##   A            use / open          X             next thrown item (also D-pad up)
##   L3           run (hold)          R3 (click)    gyro on / off
##   -            automap             +             menu (Esc)
##   D-pad down   centre the view
## The gyro on/off choice is remembered in user://gamepad.cfg.
## In a menu: A click, B back (Esc), stick or D-pad moves the cursor.

extends CanvasLayer

const PauseState := preload("res://scripts/pause_state.gd")

signal active_changed(active: bool)

const DEADZONE: float = 0.20
## Look speed on top of the player's touch_look_speed (a stick has a real
## range, the touch pad was a switch).
const LOOK_GAIN: float = 1.9
## Response curve of both sticks: one continuous curve over the whole range.
const STICK_CURVE: float = 1.6
const TRIGGER_ON: float = 0.5
## Menu cursor speed in canvas pixels per second at full tilt.
const CURSOR_SPEED: float = 760.0

var _active: bool = false
var _device: int = 0
var _cursor: Control = null
var _pos: Vector2 = Vector2(640.0, 360.0)
var _flash: float = 0.0
var _held_click: bool = false
var _prev_zl: bool = false
var _prev_zr: bool = false
var _was_in_game: bool = false
var _poll: float = 0.0

const CFG_PATH: String = "user://gamepad.cfg"
var _gyro_on: bool = true
var _toast: Label = null
var _toast_t: float = 0.0

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		_gyro_on = bool(cfg.get_value("gamepad", "gyro", true))
	_toast = Label.new()
	_toast.add_theme_font_size_override("font_size", 28)
	_toast.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_toast.add_theme_constant_override("outline_size", 8)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_top = 40.0
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	add_child(_toast)
	_cursor = _CursorDraw.new()
	_cursor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	add_child(_cursor)
	Input.joy_connection_changed.connect(func(_d: int, _c: bool) -> void: _refresh())
	_refresh()
	print("[gamepad] ready, pads=%s" % [Input.get_connected_joypads()])

func is_active() -> bool:
	return _active

func _refresh() -> void:
	var pads: Array[int] = Input.get_connected_joypads()
	var now: bool = not pads.is_empty()
	if now:
		_device = pads[0]
	if now != _active:
		_active = now
		print("[gamepad] %s (device %d)" % ["connected" if now else "gone", _device])
		active_changed.emit(_active)
	if not _active:
		_cursor.visible = false
		_stop_click()

# ---- mode ----------------------------------------------------------------

func _player() -> Node:
	return get_tree().get_first_node_in_group("player")

func _in_game(p: Node) -> bool:
	return p != null and not PauseState.is_paused() and not PauseState.mouse_wanted() \
		and not get_tree().paused

# ---- sticks ---------------------------------------------------------------

## Radial dead zone and one continuous curve; returns a vector of length 0..1.
func _stick(ax: int, ay: int) -> Vector2:
	var v := Vector2(Input.get_joy_axis(_device, ax), Input.get_joy_axis(_device, ay))
	var m: float = v.length()
	if m <= DEADZONE:
		return Vector2.ZERO
	var t: float = minf((m - DEADZONE) / (1.0 - DEADZONE), 1.0)
	return v / m * pow(t, STICK_CURVE)

func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast.visible = false
	_poll += delta
	if _poll >= 0.5:
		_poll = 0.0
		_refresh()
	if not _active:
		return
	var p: Node = _player()
	var game: bool = _in_game(p)
	if game:
		_game_axes(p)
		_cursor.visible = false
		if not _was_in_game:
			_stop_click()
	else:
		if _was_in_game:
			_release_player(p)
		_menu_cursor(delta)
	if game != _was_in_game:
		print("[gamepad] mode: %s" % ("game" if game else "menu cursor"))
	_was_in_game = game

# ---- gameplay -------------------------------------------------------------

func _game_axes(p: Node) -> void:
	var l: Vector2 = _stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
	var r: Vector2 = _stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	p.set("ui_move", Vector2(l.x, -l.y))
	p.set("ui_look", r * LOOK_GAIN + _gyro_look(p))
	var vert: float = 0.0
	if Input.is_joy_button_pressed(_device, JOY_BUTTON_B):
		vert += 1.0
	if Input.is_joy_button_pressed(_device, JOY_BUTTON_Y):
		vert -= 1.0
	p.set("ui_vert", vert)
	p.set("ui_sprint", Input.is_joy_button_pressed(_device, JOY_BUTTON_LEFT_STICK))
	if Input.get_joy_axis(_device, JOY_AXIS_TRIGGER_RIGHT) > TRIGGER_ON:
		p.set("ui_fire", true)
	var zl: bool = Input.get_joy_axis(_device, JOY_AXIS_TRIGGER_LEFT) > TRIGGER_ON
	if zl and not _prev_zl and not bool(p.get("input_locked")):
		p.call("_throw_secondary")
	_prev_zl = zl

## Motion aiming. Input.get_gyroscope() carries view-rotation rates in rad/s
## (x = looking up, y = turning left) when the platform feeds a gyroscope; it
## is zero otherwise, so this adds nothing without one. The rate goes through
## the same ui_look path as the stick, which divides out the player's look
## speed and the mouse-rate settings so the result is the rate asked for.
func _gyro_look(p: Node) -> Vector2:
	if not _gyro_on:
		return Vector2.ZERO
	var g: Vector3 = Input.get_gyroscope()
	if g.x == 0.0 and g.y == 0.0:
		return Vector2.ZERO
	var spd: float = maxf(float(p.get("touch_look_speed")), 0.01)
	var base: float = Settings.MOUSE_BASE_RATE
	var rx: float = maxf(Settings.mouse_rate_x() / base, 0.01)
	var ry: float = maxf(Settings.mouse_rate_y() / base, 0.01)
	var sgn: float = Settings.mouse_pitch_sign()
	return Vector2(-g.y / (spd * rx), -g.x / (spd * ry * sgn))

func _set_gyro(on: bool) -> void:
	_gyro_on = on
	var cfg := ConfigFile.new()
	cfg.set_value("gamepad", "gyro", on)
	cfg.save(CFG_PATH)
	_toast.text = "GYRO ON" if on else "GYRO OFF"
	_toast.visible = true
	_toast_t = 1.5
	print("[gamepad] gyro %s" % ("on" if on else "off"))

## Hand the player back neutral when a menu takes over, so nothing keeps
## running under it.
func _release_player(p: Node) -> void:
	if p == null or not is_instance_valid(p):
		return
	p.set("ui_move", Vector2.ZERO)
	p.set("ui_look", Vector2.ZERO)
	p.set("ui_vert", 0.0)
	p.set("ui_sprint", false)

func _weapon_step(p: Node, dir: int) -> void:
	if bool(p.call("_weapon_keys_blocked")):
		return
	p.call("_select_weapon", p.call("_next_owned", int(p.get("_weapon_idx")), dir))

func _tap_key(code: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventKey.new()
	up.keycode = code as Key
	up.physical_keycode = code as Key
	up.pressed = false
	Input.parse_input_event.call_deferred(up)

func _input(event: InputEvent) -> void:
	if not _active or not (event is InputEventJoypadButton):
		return
	var e := event as InputEventJoypadButton
	if e.device != _device:
		return
	var p: Node = _player()
	if _in_game(p):
		if not e.pressed:
			return
		var locked: bool = bool(p.get("input_locked"))
		match e.button_index:
			JOY_BUTTON_START:
				_tap_key(KEY_ESCAPE)
			JOY_BUTTON_BACK:
				_tap_key(int(Controls.binds.get("automap", KEY_TAB)))
			JOY_BUTTON_A:
				if not locked:
					p.call("_try_activate")
			JOY_BUTTON_X, JOY_BUTTON_DPAD_UP:
				if not locked and not bool(p.call("_weapon_keys_blocked")):
					p.call("cycle_throwable", 1)
			JOY_BUTTON_DPAD_DOWN:
				if not locked:
					p.call("set_view", float(p.get("_yaw")), 0.0)
			JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_DPAD_RIGHT:
				if not locked:
					_weapon_step(p, 1)
			JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_DPAD_LEFT:
				if not locked:
					_weapon_step(p, -1)
			JOY_BUTTON_RIGHT_STICK:
				_set_gyro(not _gyro_on)
		get_viewport().set_input_as_handled()
		return
	# Menu mode: A clicks, B goes back.
	match e.button_index:
		JOY_BUTTON_A:
			if e.pressed:
				_start_click()
			else:
				_stop_click()
		JOY_BUTTON_B:
			if e.pressed:
				_tap_key(KEY_ESCAPE)
		JOY_BUTTON_START:
			if e.pressed:
				_tap_key(KEY_ESCAPE)

# ---- menu cursor ----------------------------------------------------------

func _menu_cursor(delta: float) -> void:
	_cursor.visible = true
	var mv: Vector2 = _stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
	if mv == Vector2.ZERO:
		mv = _stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	if Input.is_joy_button_pressed(_device, JOY_BUTTON_DPAD_LEFT):
		mv.x -= 0.6
	if Input.is_joy_button_pressed(_device, JOY_BUTTON_DPAD_RIGHT):
		mv.x += 0.6
	if Input.is_joy_button_pressed(_device, JOY_BUTTON_DPAD_UP):
		mv.y -= 0.6
	if Input.is_joy_button_pressed(_device, JOY_BUTTON_DPAD_DOWN):
		mv.y += 0.6
	var size: Vector2 = get_viewport().get_visible_rect().size
	if mv != Vector2.ZERO:
		var old: Vector2 = _pos
		_pos = (_pos + mv * CURSOR_SPEED * delta).clamp(Vector2.ZERO, size - Vector2.ONE)
		_send_motion(_pos - old)
	_flash = maxf(_flash - delta * 4.0, 0.0)
	_cursor.set("pos", _pos)
	_cursor.set("flash", _flash)
	_cursor.set("down", _held_click)
	_cursor.queue_redraw()

func _window_pos() -> Vector2:
	return get_viewport().get_final_transform() * _pos

func _mouse_mask() -> int:
	return MOUSE_BUTTON_MASK_LEFT if _held_click else 0

func _send_motion(rel: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = _window_pos()
	ev.global_position = ev.position
	ev.relative = rel
	ev.button_mask = _mouse_mask()
	Input.parse_input_event(ev)

func _send_button(pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = _window_pos()
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(ev)

func _start_click() -> void:
	if _held_click:
		return
	_held_click = true
	_flash = 1.0
	_send_motion(Vector2.ZERO)
	_send_button(true)

func _stop_click() -> void:
	if not _held_click:
		return
	_held_click = false
	_send_button(false)

## The cursor: an arrow with an outline, and a ring that opens when A clicks.
class _CursorDraw extends Control:
	var pos: Vector2 = Vector2.ZERO
	var flash: float = 0.0
	var down: bool = false

	func _draw() -> void:
		var tip: Vector2 = pos
		var s: float = 0.85 if down else 1.0
		var pts := PackedVector2Array([
			tip,
			tip + Vector2(0.0, 26.0) * s,
			tip + Vector2(6.5, 20.5) * s,
			tip + Vector2(11.5, 31.0) * s,
			tip + Vector2(16.0, 29.0) * s,
			tip + Vector2(11.0, 18.5) * s,
			tip + Vector2(19.0, 18.5) * s,
		])
		var fill := Color(1.0, 0.85, 0.2) if down else Color(1.0, 1.0, 1.0)
		draw_colored_polygon(pts, fill)
		var outline := PackedVector2Array(pts)
		outline.append(pts[0])
		draw_polyline(outline, Color(0.0, 0.0, 0.0), 2.0, true)
		if flash > 0.0:
			var r: float = 8.0 + (1.0 - flash) * 34.0
			draw_arc(tip, r, 0.0, TAU, 32, Color(1.0, 0.85, 0.2, flash), 3.0, true)
