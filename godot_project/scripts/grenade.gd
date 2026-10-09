## A thrown or launched explosive: the GRENADE LAUNCHER shell, and every
## item on the THROW key (pipe bomb, molotov, grenade, canister bomb,
## satchel — see fly_camera.THROWABLES). Flies fast and fairly flat
## (the DOS launcher lobbed only a shallow arc), bounces off level
## geometry, and detonates the moment it touches anything that can take
## damage — a robot, a car, a crate, a generator, another player — or
## when its fuse runs out on the ground.
##
## DOS models this as a generic projectile (FUN_00122a64, skynet_gh.c:
## 25675) whose ammo type (t3 at 0x40728 + 3*0x32) installs the gravity
## callback 0x000f3414, draws the grenade as the billboard sprite named
## at +0x04 (sprite index 27778 = TEXTURE.217 record 2), and on impact
## spawns the effect bank at +0x08 (0xB200 = TEXTURE.356) with the sound
## at +0x20 (33 = explo1.raw). Launch is straight along the aim — the arc
## comes from gravity alone, so aiming up is what gives range.
##
## The thrown items use their OWN ammo types (v1.01 table 0x40828, stride
## 0x32; the weapon record's +0x14 picks the row), and each one names its
## own sprite, effect bank and bang — fly_camera.THROWABLES carries them
## ("spr", "fx", "isnd", "bounce"). Only the launcher shell and the hand
## grenade share TEXTURE.217 record 2.

extends Node3D

const Explosion  := preload("res://scripts/explosion.gd")
const Projectile := preload("res://scripts/projectile.gd")
const ZoneLayers := preload("res://scripts/mission/zone_layers.gd")

## Playtest 2026-09-03: the DOS grenade flew "more in a straight
## line than a ballistic curve" — 2400/2400 dropped 1200 u per 2400 u of
## travel, a visible lob. Faster and lighter: 3400 u/s, 1400 u/s².
const GRAVITY: float = 1400.0
const FUSE_TIME: float = 2.5
const RESTITUTION: float = 0.3               # off a wall: bounce energy retained
const FLOOR_SLIDE: float = 0.3               # on the floor: no bounce, a short skid
const SPEED: float = 3400.0                  # initial muzzle velocity
const SPRITE_BANK: int = 217
const SPRITE_RECORD: int = 2
const IMPACT_BANK: int = 356
const IMPACT_SOUND: int = 33                 # explo1.raw
const SPRITE_PIXEL_SIZE: float = 2.0
## Ammo flag +0x28 bit 0 (pipe bomb, canister bomb): off level geometry
## and anything that takes no damage the item BOUNCES (0x1233ea). The
## velocity is mirrored in the surface and scaled by 0xaaab / 0x10000 =
## 2/3 (FUN_0011c19a → FUN_0011c100); it goes off instead when the
## bounced speed is under 50 u/s, or at most 100 u/s on a floor (the
## normal's up component at least 252/256). Each bounce plays sound id
## 0x18.
const BOUNCE_KEEP: float = 2.0 / 3.0
const BOUNCE_DEAD_SPEED: float = 50.0
const BOUNCE_REST_SPEED: float = 100.0
const BOUNCE_FLOOR_UP: float = 252.0 / 256.0
const BOUNCE_SOUND: int = 0x18               # jmpmet.raw

## Sprite textures by DOS sprite index (bank << 7 | record).
static var _sprite_cache: Dictionary = {}

## Another game's data came in (SkynetPaths.switch_game): its sprite bank.
static func reset_game() -> void:
	_sprite_cache.clear()
## The fallback body when the sprite is missing, shared.
static var _body_mesh: SphereMesh = null
static var _body_mat: StandardMaterial3D = null

var _vel: Vector3 = Vector3.ZERO
var _life: float = FUSE_TIME
var _damage: float = 200.0
var _splash: float = 256.0
var _owner: Node = null
var _exploded: bool = false
## Per-item overrides from fly_camera.THROWABLES: `fuse` seconds (only
## the launcher's shell has one to run out), `burst` = shatter on the
## first thing it touches; a thrown item (`_contact`) goes off on anything.
var _fuse: float = FUSE_TIME
var _burst: bool = false
var _contact: bool = false
var _bounce: bool = false
var _impact_bank: int = IMPACT_BANK
var _impact_sound: int = IMPACT_SOUND
## A replicated copy of somebody else's grenade: flies and bangs, hurts
## nobody on this machine (the thrower's copy does the damage).
var visual_only: bool = false
## The flight ray, built once in setup() (the thrower left out).
var _ray: PhysicsRayQueryParameters3D = null

## A thrown item's sprite (TEXTURE.217 record 2 by default) as a
## texture, index 0 transparent — the same record decode the level's
## billboards get, converted once into the asset cache
## (converted/tex/T217_002_A).
static func sprite_texture(bank: int = SPRITE_BANK, rec: int = SPRITE_RECORD) -> Texture2D:
	var key: int = (bank << 7) | rec
	if not _sprite_cache.has(key):
		_sprite_cache[key] = Assets.texture(bank, rec, true)
	return _sprite_cache[key]

## Launch from `from` heading `dir` (unit vector). Initial speed is
## constant; `damage` and `splash` set the detonation payload.
func setup(from: Vector3, dir: Vector3, damage: float, splash: float,
		shooter: Node, speed: float = SPEED, cfg: Dictionary = {}) -> void:
	add_to_group("projectile")               # cleared on a map change
	global_position = from
	_vel = dir.normalized() * speed
	_damage = damage
	_splash = splash
	_owner = shooter
	_fuse = float(cfg.get("fuse", FUSE_TIME))
	_life = _fuse
	_burst = bool(cfg.get("burst", false))
	_contact = not cfg.is_empty()              # a thrown item: off on contact
	_bounce = bool(cfg.get("bounce", false))
	_impact_bank = int(cfg.get("fx", IMPACT_BANK))
	_impact_sound = int(cfg.get("isnd", IMPACT_SOUND))
	var spr_id: Array = cfg.get("spr", [SPRITE_BANK, SPRITE_RECORD])
	var tex := sprite_texture(int(spr_id[0]), int(spr_id[1]))
	if tex != null:
		var spr := Sprite3D.new()
		spr.texture = tex
		spr.pixel_size = Assets.sprite_pixel_size(int(spr_id[0]), int(spr_id[1]), tex,
			SPRITE_PIXEL_SIZE)
		spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		spr.shaded = false
		spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		add_child(spr)
	else:
		if _body_mesh == null:
			_body_mesh = SphereMesh.new()
			_body_mesh.radius = 14.0
			_body_mesh.height = 28.0
			_body_mat = StandardMaterial3D.new()
			_body_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_body_mat.albedo_color = Color(0.32, 0.45, 0.22)   # olive-drab body
		var mi := MeshInstance3D.new()
		mi.mesh = _body_mesh
		mi.material_override = _body_mat
		add_child(mi)
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.collision_mask = ZoneLayers.world_mask()
	_ray.collide_with_areas = true             # enemy hitboxes are areas
	if _owner is CollisionObject3D:
		_ray.exclude = [(_owner as CollisionObject3D).get_rid()]

func _physics_process(delta: float) -> void:
	if _exploded:
		return
	# The thrower may die while the grenade is in the air. Godot 4 makes a
	# freed instance compare equal to null, so only is_instance_valid()
	# catches it — otherwise `_owner is …` raises every frame.
	if not is_instance_valid(_owner):
		_owner = null
	_life -= delta
	_vel.y -= GRAVITY * delta
	var to: Vector3 = global_position + _vel * delta
	var space := get_world_3d().direct_space_state
	if space != null and _ray != null:
		_ray.from = global_position
		_ray.to = to
		var hit := space.intersect_ray(_ray)
		if hit.has("position"):
			# Detonate on anything damageable (DOS: the projectile's impact
			# callback fires on the first object hit — a robot, a car, a
			# crate, the player's own jeep …); bounce off level geometry.
			var c: Node = hit.get("collider") as Node
			var n: Node = c
			while n != null and not n.has_method("take_damage") and not n.has_method("net_damage") and not n.is_in_group("dm_vehicle"):
				n = n.get_parent()
			# DOS: the impact callback runs on the first thing struck, the
			# ground and the walls included — a thrown item without the
			# bounce flag never bounces (2026-09-15 audit; the fuse and the
			# bounce were the port's).
			var target: bool = n != null and n != _owner and n is Node3D and _is_target(n)
			if _burst or target or (_contact and not _bounce):
				_detonate(hit["position"])
				return
			var nrm: Vector3 = hit.get("normal", Vector3.UP)
			if _contact:
				# The bounce flag (pipe bomb, canister bomb), 0x1233ea.
				var out: Vector3 = _vel.bounce(nrm) * BOUNCE_KEEP
				var sp: float = out.length()
				if sp < BOUNCE_DEAD_SPEED or (sp <= BOUNCE_REST_SPEED and nrm.y >= BOUNCE_FLOOR_UP):
					_detonate(hit["position"])
					return
				_vel = out
				global_position = hit["position"] + nrm * 2.0
				Audio.play_id_3d(BOUNCE_SOUND, global_position)
				return
			# Off a wall it bounces; on the floor it drops dead and skids a
			# little — the DOS grenade never hopped back up off the ground
			# (playtest, 2026-09-05).
			global_position = hit["position"] + nrm * 2.0
			if nrm.y > 0.6:
				_vel = (_vel - nrm * _vel.dot(nrm)) * FLOOR_SLIDE
				_vel.y = 0.0
			else:
				_vel = _vel.bounce(nrm) * RESTITUTION
			return
	global_position = to
	if _life <= 0.0:
		_detonate(global_position)

## Something the grenade should burst on rather than bounce off: enemies,
## deathmatch actors and vehicles, and action targets that actually take
## damage (cars, crates, generators — not door leaves or wall buttons).
static func _is_target(n: Node) -> bool:
	if n.is_in_group("enemy") or n.is_in_group("dm_actor") or n.is_in_group("dm_vehicle"):
		return true
	if n.is_in_group("hittable") and n.has_method("is_damageable"):
		return bool(n.call("is_damageable"))
	return false

func _detonate(at: Vector3) -> void:
	_exploded = true
	Audio.play_id_3d(_impact_sound, at, -1.0)
	if visual_only:
		var vscene := get_tree().current_scene
		if vscene != null:
			Explosion.spawn(vscene, at, 280.0, _impact_bank)
		queue_free()
		return
	for a in get_tree().get_nodes_in_group("dm_actor"):
		if a is Node3D and a != _owner and a.has_method("net_damage"):
			var da := (a as Node3D).global_position.distance_to(at)
			if da < _splash:
				a.net_damage(_damage * (1.0 - da / _splash), _owner)
	# One DOS radial blast (Projectile.dos_blast) over everything in reach.
	for h in get_tree().get_nodes_in_group("hittable"):
		if h is Node3D and h.has_method("take_damage") and not ZoneLayers.asleep(h):
			var bh: float = Projectile.dos_blast(_damage, (h as Node3D).global_position.distance_to(at))
			if bh > 0.0:
				h.take_damage(bh)
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D and e.has_method("take_damage") and not ZoneLayers.asleep(e):
			# To the hitbox, not the origin (Enemy.blast_distance): a
			# grenade bursting on an HK's nose is 300 u from its centre.
			var d: float = e.blast_distance(at) if e.has_method("blast_distance") 				else (e as Node3D).global_position.distance_to(at)
			var bd: float = Projectile.dos_blast(_damage, d)
			if bd > 0.0:
				e.take_damage(bd)
	Projectile.blast_player(at, _damage, _splash, _owner, get_tree())
	# (No pool of burning fuel: DOS v1.00 has none — the molotov's fire is
	# eleven sparks and the effect sprite's own animation.)
	var scene := get_tree().current_scene
	if scene != null:
		Explosion.spawn(scene, at, 280.0, _impact_bank)
	queue_free()
