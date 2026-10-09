## The status panel's message window — the right-hand recess of PANEL0,
## where DOS types the mission's hints and objectives (GAME.EXE v1.01):
##
##   - FUN_0012fa3d starts a message: it word-wraps the text to 0x62 =
##     98 px of FONT0004 (FUN_0012daa8: line breaks and CRs become spaces,
##     a break is "\r\n" after the last space that fits), clears the box
##     (FUN_0012faa0), plays sound 0x51 and points the typewriter at it.
##     Callers: the hint acts 0x1C-0x25 (0x137f9d), the objective acts
##     0x26-0x2A (0x137fd0, only for a text longer than 2 characters) and
##     the border-box hint (0x122789).
##   - FUN_0012fb4c, once per frame (FUN_0012f77a in the game loop), types
##     ONE character in palette 0xB7: "\r" returns to x 0, "\n" drops a
##     line of 5 + 1 px and, once the next line would pass y 27 of the
##     33 px box, scrolls the box up a line instead (FUN_0015569c) — five
##     lines show, the oldest scrolls off the top.
##   - FUN_0012fcf5 blits the box every frame to (219,164)-(317,196) of the
##     320x200 screen (the rectangle at 0x51b11: 218,163,317,196, +1 in).
##     Nothing expires it: the text stays until the next message replaces
##     it, and a level start empties it (FUN_0012f745).
##
## The other DOS message system, the 0x51600 queue (FUN_0012f8f7 — the
## pickups' item-table text, kills, network lines), prints at the TOP LEFT
## (4,3) for 210 ticks; that is main.gd's status line, not this box.
##
## This object only keeps the box's text; main.gd ticks it and hands the
## lines to whichever HUD is up.
extends RefCounted

const WRAP_PX: int = 0x62          # FUN_0012fa3d's wrap width
const LINES: int = 5               # (33 - 6) / 6 + 1 lines before a scroll
## DOS types one character per rendered frame; its frame rate is the
## machine's, so the port types at a fixed, DOS-like rate instead.
const CHARS_PER_SEC: float = 30.0

var _widths: PackedInt32Array = PackedInt32Array()   # FONT0004 glyph widths
var _em: int = 6
var _stream: String = ""           # the wrapped text still to type
var _at: int = 0
var _acc: float = 0.0
var _lines: PackedStringArray = PackedStringArray()

## `font_bytes`: FONT0004.FNT, for the wrap widths (FUN_0014691c).
func _init(font_bytes: PackedByteArray = PackedByteArray()) -> void:
	if font_bytes.size() >= 4 + 240 * 4:
		_em = maxi(font_bytes.decode_u16(0), 2)
		for i in 240:
			_widths.append(font_bytes.decode_u16(4 + i * 4 + 2))

## A new message: the box clears and the typing starts over.
func start(text: String) -> void:
	_stream = _wrap(text)
	_at = 0
	_acc = 0.0
	_lines = PackedStringArray([""])

## Empty the box (a level start).
func clear() -> void:
	_stream = ""
	_at = 0
	_lines = PackedStringArray()

## Type what `delta` seconds are worth; true when the lines changed.
func tick(delta: float) -> bool:
	if _at >= _stream.length():
		return false
	_acc += delta * CHARS_PER_SEC
	var changed: bool = false
	while _acc >= 1.0 and _at < _stream.length():
		_acc -= 1.0
		var c: String = _stream[_at]
		_at += 1
		changed = true
		if c == "\r":
			continue                    # x back to 0: the next line does that
		if c == "\n":
			_lines.append("")
			if _lines.size() > LINES:
				_lines.remove_at(0)     # the box scrolls up a line
			continue
		_lines[_lines.size() - 1] += c
	return changed

## The box's lines, top first (at most LINES).
func lines() -> PackedStringArray:
	return _lines

## The whole message typed out at once (tests, screenshots).
func finish() -> void:
	tick(float(_stream.length() - _at + 1) / CHARS_PER_SEC)

## Pixel advance of one FONT0004 character: its width + 1, a space the
## em width (FUN_0014691c, spacing [0x33348] = 1). The DOS font has lower
## case; anything it lacks counts as a space.
func _advance(c: String) -> int:
	var code: int = c.unicode_at(0)
	var i: int = code - 0x21
	if i < 0 or i >= _widths.size() or _widths[i] <= 0:
		return _em
	return _widths[i] + 1

## FUN_0012daa8's greedy wrap: "\r\n" goes in after the last space that
## still fits WRAP_PX; a word with no space before it breaks where it is.
func _wrap(text: String) -> String:
	var src: String = text.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
	var out: String = ""
	var line: String = ""
	var x: int = 0
	var i: int = 0
	while i < src.length():
		var c: String = src[i]
		var adv: int = _advance(c)
		if c != " " and x + adv >= WRAP_PX and not line.is_empty():
			var cut: int = line.rfind(" ")
			if cut >= 0:
				out += line.substr(0, cut + 1) + "\r\n"
				line = line.substr(cut + 1)
			else:
				out += line + "\r\n"
				line = ""
			x = 0
			for ch in line:
				x += _advance(ch)
			continue                    # measure this character again
		line += c
		x += adv
		i += 1
	return out + line
