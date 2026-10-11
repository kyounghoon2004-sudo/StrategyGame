extends Node3D
## Twenty visual children, one owner/hex. No Unit, HexCell, navigation or combat.
signal attack_finished
const SOLDIER_SCENE = preload("res://scenes/formation_v0/soldier.tscn")
const COLS := 5
const ROWS := 4
const COUNT := 20
const COL_SPACING := 0.88
const ROW_SPACING := 1.12
const HEX_RADIUS := 4.5
const FOOTPRINT_RADIUS := HEX_RADIUS * (20.5/24.0)
@export var logical_hex := Vector2i.ZERO
@export var logical_formation_id := "review_formation_001"
var soldiers: Array[Node3D] = []
var offsets: Array[float] = []
var attacking := false
var elapsed := 0.0
var attack_events := 0

func _ready() -> void:
	set_meta("presentation_only",true)
	set_meta("logical_hex",logical_hex)
	set_meta("logical_formation_count",1)
	for row in range(ROWS):
		for col in range(COLS):
			var index := row*COLS+col
			var soldier := SOLDIER_SCENE.instantiate()
			soldier.name = "Soldier_%02d" % (index+1)
			# Deterministic small variation; each rank and file remains clear.
			var jitter_x := sin(index*2.41)*0.021
			var jitter_z := cos(index*1.71)*0.018
			soldier.position = Vector3((col-2)*COL_SPACING+jitter_x,0,(row-1.5)*ROW_SPACING+jitter_z)
			soldier.set_meta("visual_index",index+1)
			soldier.set_meta("owner_formation_id",logical_formation_id)
			add_child(soldier);soldiers.append(soldier)
			offsets.append(float((index*7)%5)*0.018)
	assert(soldiers.size() == COUNT)
	assert_layout_inside_hex()

func _process(delta: float) -> void:
	if not attacking: return
	elapsed += delta
	for i in range(COUNT):
		if elapsed >= offsets[i] and elapsed-delta < offsets[i]:soldiers[i].attack()
		elif elapsed == delta and offsets[i] == 0.0:soldiers[i].attack()
	if elapsed >= 0.76+0.072+0.06:
		for soldier in soldiers: soldier.reset_idle()
		attacking = false;attack_finished.emit()

func trigger_attack() -> void:
	if attacking: return
	attacking = true;elapsed = 0.0;attack_events += 1
	for i in range(COUNT):
		if offsets[i] == 0.0:soldiers[i].attack()

func seek_attack(time: float) -> void:
	for i in range(COUNT): soldiers[i].seek_attack(maxf(0,time-offsets[i]))

func reset_idle() -> void:
	attacking = false
	for soldier in soldiers: soldier.reset_idle()

func assert_layout_inside_hex() -> void:
	# Includes full horizontal source AABB and conservative extra attack reach.
	var half_width := 0.40311421454 * (1.65/1.0007815957)*0.5
	var half_depth := 0.24803921580 * (1.65/1.0007815957)*0.5 + 0.65
	for soldier in soldiers:
		for x in [-half_width,half_width]:
			for z in [-half_depth,half_depth]:
				var point := Vector2(soldier.position.x+x,soldier.position.z+z)
				assert(point.length() < FOOTPRINT_RADIUS)
		assert(soldier.get_meta("owner_formation_id") == logical_formation_id)

func all_idle() -> bool:
	return soldiers.all(func(soldier): return soldier.is_idle())
