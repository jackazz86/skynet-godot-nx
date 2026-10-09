## TEST / DEBUG OVERLAY — a port-only aid for playtesting, not DOS.
##
## Off by default; F12 or the console's `debug on|off` toggles it and the
## state is kept in the settings (Settings.debug_overlay). `--debug-overlay`
## on the command line shows it for that run only, without saving.
##
## Three blocks, top left:
##   performance  FPS, frame time and Godot's Performance monitors (process /
##                physics time, draw calls, objects and primitives drawn,
##                object / node / physics-body counts). The editor profiler
##                stays the deep tool; this is the at-a-glance line.
##   mission      the mission key and the map, objectives total / done / left
##                — main.gd's own counter (_objectives_total/_objectives_left),
##                the one _finish_mission_if_done ends the mission on — and
##                the [M1]..[M5] lines still to come, from the NNN.TXT script.
##   pointer      for the pending objectives, the records that RAISE them, read
##                from the generated trigger graph (trigger_graph.gd, the same
##                MAP.NNN.triggers.json the verifier and the solver use):
##                an objective-act node (fx.objective = n) and the chain heads
##                that reach it (its chain.by — the self-starting triggers,
##                pads, shot props and kills whose walk flips it), or the node
##                itself when it starts on its own. The nearest live one on
##                this map gets an on-screen marker (an arrow at the edge when
##                it is off screen) with distance, name and act. When none is
##                on this map, the mission's other maps are searched along the
##                graphs' exits (ticks.exits) and the exit of THIS map that
##                leads there is pointed at instead. Nothing found = says so.
##
## Nothing here changes the game; it only reads main.gd's state.

extends CanvasLayer

const TriggerGraph := preload("res://scripts/triggers/trigger_graph.gd")
const TOGGLE_KEY: int = KEY_F12       # F1-F5 throwables, F6/F7 saves, F8/F9 cheats
const ACT_SPENT: int = 0xFF
const BFS_DEPTH: int = 8
## Maps one search may open (a mission without a baked map list walks
## every exit it finds).
const MAX_MAPS: int = 24

var main: Node = null                  # scripts/main.gd (its privates are read)
var _panel: PanelContainer = null
var _label: RichTextLabel = null
var _marks: Control = null
var _text_t: float = 0.0
var _frame_ms: float = 0.0
var _graphs: Dictionary = {}           # "MAP.NNN" → graph Dictionary ({} = none)
var _target: Dictionary = {}           # {pos, text} on this map, or {} for none
var _target_note: String = ""
var _target_t: float = 0.0

## Create the overlay under `m` (main.gd), shown when the setting or the
## CLI says so.
static func attach(m: Node) -> CanvasLayer:
	var o = load("res://scripts/debug_overlay.gd").new()
	o.main = m
	m.add_child(o)
	var on: bool = bool(Settings.get("debug_overlay")) if "debug_overlay" in Settings else false
	if OS.get_cmdline_user_args().has("--debug-overlay") or OS.get_cmdline_args().has("--debug-overlay"):
		on = true
	o.visible = on
	return o

func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_marks = Control.new()
	_marks.set_anchors_preset(Control.PRESET_FULL_RECT)
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.draw.connect(_draw_marks)
	add_child(_marks)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_content_margin_all(6)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.position = Vector2(8, 8)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", 14)
	_label.custom_minimum_size = Vector2(560, 0)
	_panel.add_child(_label)
	add_child(_panel)

## On / off; `save` keeps it in the settings.
func set_on(on: bool, save: bool = true) -> void:
	visible = on
	_target_t = 0.0
	_text_t = 0.0
	if save and "debug_overlay" in Settings:
		Settings.set("debug_overlay", on)
		Settings.save()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == TOGGLE_KEY and not event.ctrl_pressed:
		set_on(not visible)
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not visible:
		return
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1) if _frame_ms > 0.0 else delta * 1000.0
	_target_t -= delta
	if _target_t <= 0.0:
		_target_t = 1.0
		_find_target()
	_text_t -= delta
	if _text_t <= 0.0:
		_text_t = 0.25
		_label.text = _perf_text() + "\n" + _mission_text()
	_marks.queue_redraw()

# ---------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------
func _perf_text() -> String:
	return ("[b]FPS %d[/b]  frame %.1f ms  process %.1f ms  physics %.1f ms\n"
		+ "draw calls %d  objects %d  primitives %dk  |  objects %d  nodes %d  orphans %d  physics bodies %d  mem %.0f MB") % [
		Engine.get_frames_per_second(), _frame_ms,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)) / 1000,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0]

func _mission_text() -> String:
	if main == null:
		return ""
	var map: String = String(main.call("_level_name"))
	var key: int = int(main.get("_mission_key"))
	var total: int = int(main.get("_objectives_total"))
	var left: int = int(main.get("_objectives_left"))
	var lines: Array = []
	if key < 0 or total <= 0:
		lines.append("[b]%s[/b]  no mission script (mission %d)" % [map, key])
	else:
		lines.append("[b]mission %d  %s[/b]  objectives %d  done %d  left %d" % [
			key, map, total, total - left, left])
		var texts: Array = main.get("_mission_texts")
		var cur: Array = main.get("_objective_cursor")
		for i in texts.size():
			var sec: Array = texts[i]
			for j in range(int(cur[i]) if i < cur.size() else 0, sec.size()):
				lines.append("  [M%d] %s" % [i + 1, _bb(String(sec[j]).replace("\n", " ").left(110))])
	if not _target.is_empty():
		var d: float = _player_pos().distance_to(_target["pos"])
		lines.append("[color=#ffd040]> %s  %.0f u[/color]" % [_bb(String(_target["text"])), d])
	if not _target_note.is_empty():
		lines.append("[color=#ffd040]%s[/color]" % _bb(_target_note))
	return "\n".join(lines)

static func _bb(s: String) -> String:
	return s.replace("[", "[lb]")

# ---------------------------------------------------------------------
# Pointer
# ---------------------------------------------------------------------
func _player_pos() -> Vector3:
	var p = main.get("player") if main != null else null
	if p != null and is_instance_valid(p):
		return (p as Node3D).global_position
	return Vector3.ZERO

## The graph of one map, read from the converted cache (built on demand
## when the cache can write). {} when there is none.
func _graph(map_name: String) -> Dictionary:
	if _graphs.has(map_name):
		return _graphs[map_name]
	var g: Dictionary = {}
	var p: String = TriggerGraph.json_path(map_name)
	if p.is_empty() or not FileAccess.file_exists(p):
		p = String(Assets.triggers(map_name)) if Assets.has_method("triggers") else ""
	if not p.is_empty() and FileAccess.file_exists(p):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
		if parsed is Dictionary:
			g = parsed
	if g.is_empty() and Assets.has_method("map_bytes"):
		# No usable cache (--no-cache, or a read-only one of another
		# version): build it in memory, as the import would.
		var bytes: PackedByteArray = Assets.map_bytes(map_name)
		if not bytes.is_empty():
			g = TriggerGraph.build_from_bytes(map_name, bytes)
	_graphs[map_name] = g
	return g

## Pending objective sections: index → the [M] text shown next.
func _pending() -> Dictionary:
	var out: Dictionary = {}
	var texts: Array = main.get("_mission_texts")
	var cur: Array = main.get("_objective_cursor")
	for i in texts.size():
		var sec: Array = texts[i]
		var at: int = int(cur[i]) if i < cur.size() else 0
		if at < sec.size():
			out[i] = String(sec[at])
	return out

## The live act byte of a record: the running level's trigger runtime on
## the current map, the saved overlay of a map visited earlier, else the
## authored byte.
func _live_act(map_name: String, id: int, authored: int) -> int:
	var lvl = main.get("_current_level")
	if lvl != null and String(main.call("_level_name")) == map_name:
		var rt = lvl.get("triggers")
		if rt != null and rt.has_method("act"):
			return int(rt.call("act", id))
		return authored
	for store in ["_map_state", "_zone_state"]:
		var st = main.get(store)
		if st is Dictionary and (st as Dictionary).has(map_name):
			var snap: Dictionary = st[map_name]
			var trig: Dictionary = snap.get("triggers", snap.get("action", {}))
			var acts: Dictionary = trig.get("acts", {})
			for k in [id, str(id), float(id)]:
				if acts.has(k):
					return int(acts[k])
	return authored

## The sources that raise a pending objective on `map_name`:
## [{id, pos (DOS), text}], live records only.
func _sources(map_name: String, pending: Dictionary) -> Array:
	var g: Dictionary = _graph(map_name)
	var out: Array = []
	if g.is_empty():
		return out
	var by_id: Dictionary = {}
	for n in g.get("nodes", []):
		by_id[int(n["id"])] = n
	for n in g.get("nodes", []):
		var fx: Dictionary = n.get("fx", {})
		if not fx.has("objective"):
			continue
		var idx: int = int(fx["objective"])
		if not pending.has(idx):
			continue
		var oid: int = int(n["id"])
		if _live_act(map_name, oid, int(n["act"])) == ACT_SPENT:
			continue                    # counted already
		var obj_label: String = "[M%d] @%05x act %02X" % [idx + 1, oid, int(n["act"])]
		var heads: Array = []
		if _self_modes(n).size() > 0:
			heads.append(oid)
		for h in (n.get("chain", {}) as Dictionary).get("by", []):
			if not heads.has(int(h)):
				heads.append(int(h))
		var any: bool = false
		for h in heads:
			var hn: Dictionary = by_id.get(int(h), {})
			if hn.is_empty():
				continue
			if int(h) != oid and _live_act(map_name, int(h), int(hn["act"])) == ACT_SPENT:
				continue
			any = true
			out.append({"id": int(h), "pos": hn["pos"], "idx": idx,
				"text": "%s <- %s" % [obj_label, _describe(hn)]})
		if not any:
			out.append({"id": oid, "pos": n["pos"], "idx": idx, "unsure": true,
				"text": "%s (no trigger found in the graph; the record itself)" % obj_label})
	return out

static func _self_modes(n: Dictionary) -> Array:
	var out: Array = []
	for m in n.get("modes", []):
		var md: String = String((m as Dictionary).get("mode", ""))
		if md != "chain" and not out.has(md):
			out.append(md)
	return out

static func _describe(n: Dictionary) -> String:
	var who: String
	if n.has("name") and not String(n["name"]).is_empty():
		who = String(n["name"])
	elif int(n.get("marker", -1)) >= 0:
		who = "marker %d" % int(n["marker"])
		if n.has("enemy") and int(n["enemy"]) >= 0:
			who += " enemy %d" % int(n["enemy"])
	else:
		who = "sprite %s" % str(n.get("sprite", "?"))
	var modes: Array = _self_modes(n)
	return "%s @%05x act %02X %s [%s]" % [who, int(n["id"]), int(n["act"]),
		String((n.get("rule", {}) as Dictionary).get("kind", "?")),
		",".join(modes) if not modes.is_empty() else "chain"]

static func _dos_to_world(p: Array, origin: Vector3) -> Vector3:
	return Vector3(float(p[0]), -float(p[1]), -float(p[2])) + origin

static func _map_name(num: int) -> String:
	return "MAP.%03d" % num

func _find_target() -> void:
	_target = {}
	_target_note = ""
	var lvl = main.get("_current_level") if main != null else null
	if lvl == null:
		return
	var key: int = int(main.get("_mission_key"))
	if key < 0 or int(main.get("_objectives_left")) <= 0:
		return
	var pending: Dictionary = _pending()
	if pending.is_empty():
		return
	var here: String = String(main.call("_level_name"))
	var origin: Vector3 = lvl.get("origin")
	var me: Vector3 = _player_pos()
	# On this map: the nearest live source.
	var best: Dictionary = {}
	var best_d: float = INF
	for s in _sources(here, pending):
		var w: Vector3 = _dos_to_world(s["pos"], origin)
		var d: float = me.distance_to(w)
		if bool(s.get("unsure", false)):
			d += 1.0e7                   # a real trigger first
		if d < best_d:
			best_d = d
			best = {"pos": w, "text": s["text"]}
	if not best.is_empty():
		_target = best
		return
	# Elsewhere: breadth-first along the exits, within the mission's maps.
	var allowed: Dictionary = {}
	if Assets.has_method("mission_maps"):
		for m in Assets.mission_maps(key):
			allowed[_map_name(int(m))] = true
	var first_exit: Dictionary = {here: {}}     # map → the exit of HERE that leads to it
	var queue: Array = [here]
	var depth: Dictionary = {here: 0}
	var looked: int = 0
	while not queue.is_empty() and looked < MAX_MAPS:
		var cur: String = queue.pop_front()
		looked += 1
		if cur != here:
			var src: Array = _sources(cur, pending)
			if not src.is_empty():
				var ex: Dictionary = first_exit[cur]
				var s0: Dictionary = src[0]
				_target_note = "next objective on %s: %s" % [cur, s0["text"]]
				if not ex.is_empty():
					_target = {"pos": _dos_to_world(ex["pos"], origin),
						"text": "exit @%05x -> %s (towards %s)" % [int(ex["id"]),
							ex["to"], cur]}
				else:
					_target_note += " — no exit of %s found that leads there" % here
				return
		if int(depth[cur]) >= BFS_DEPTH:
			continue
		var g: Dictionary = _graph(cur)
		for ex in (g.get("ticks", {}) as Dictionary).get("exits", []):
			var to: String
			if int(ex["map"]) == 0:
				if cur != here:
					continue            # "back" — only known for this map
				to = String(main.get("_prev_map_name"))
				if to.is_empty():
					continue
			else:
				to = _map_name(int(ex["map"]))
			if first_exit.has(to):
				continue
			if not allowed.is_empty() and not allowed.has(to):
				continue
			var e: Dictionary = (ex as Dictionary).duplicate()
			e["to"] = to
			first_exit[to] = e if cur == here else first_exit[cur]
			depth[to] = int(depth[cur]) + 1
			queue.append(to)
	var names: Array = []
	for i in pending:
		names.append("[M%d]" % (int(i) + 1))
	_target_note = "pointer: no live record raising %s found on %s or the maps its exits reach (unknown)" % [
		" ".join(names), here]

# ---------------------------------------------------------------------
# On-screen marker
# ---------------------------------------------------------------------
func _draw_marks() -> void:
	if _target.is_empty():
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var w: Vector3 = _target["pos"]
	var size: Vector2 = _marks.size
	var centre: Vector2 = size * 0.5
	var col := Color(1.0, 0.82, 0.2)
	var dist: float = _player_pos().distance_to(w)
	var font: Font = ThemeDB.fallback_font
	var tag: String = "%.0f u  %s" % [dist, String(_target["text"]).left(70)]
	var behind: bool = cam.is_position_behind(w)
	var sp: Vector2 = cam.unproject_position(w)
	var inside: bool = not behind and Rect2(Vector2.ZERO, size).grow(-24).has_point(sp)
	if inside:
		var r: float = 12.0
		_marks.draw_polyline(PackedVector2Array([sp + Vector2(0, -r), sp + Vector2(r, 0),
			sp + Vector2(0, r), sp + Vector2(-r, 0), sp + Vector2(0, -r)]), col, 2.5)
		_marks.draw_string_outline(font, sp + Vector2(r + 6, 5), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 4, Color(0, 0, 0, 0.85))
		_marks.draw_string(font, sp + Vector2(r + 6, 5), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)
		return
	# Off screen: an arrow on a ring round the centre, pointing at it.
	var dir: Vector2 = sp - centre
	if behind:
		dir = -dir
	if dir.length() < 0.001:
		dir = Vector2(0, 1)
	dir = dir.normalized()
	var ring: float = minf(size.x, size.y) * 0.42
	var tip: Vector2 = centre + dir * ring
	var side := Vector2(-dir.y, dir.x)
	_marks.draw_colored_polygon(PackedVector2Array([tip, tip - dir * 26 + side * 12,
		tip - dir * 26 - side * 12]), col)
	var at: Vector2 = tip - dir * 40 + Vector2(-60, 0)
	_marks.draw_string_outline(font, at, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 4, Color(0, 0, 0, 0.85))
	_marks.draw_string(font, at, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)
