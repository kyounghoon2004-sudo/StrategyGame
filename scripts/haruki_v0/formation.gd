extends Node3D
const SOLDIER = preload("res://scenes/haruki_v0/haruki_soldier.tscn")
var soldiers: Array[Node3D] = []
var origin := Transform3D.IDENTITY
@export var logical_hex := Vector2i.ZERO
func _ready() -> void:
	origin = transform
	set_meta("logical_formation_count",1);set_meta("logical_hex",logical_hex)
	for row in range(4):
		for col in range(5):
			var i := row*5+col
			var soldier = SOLDIER.instantiate();soldier.name = "Haruki_%02d" % (i+1)
			soldier.position = Vector3((col-2)*1.35+sin(i*2.3)*.018,0,(row-1.5)*1.35+cos(i*1.9)*.018)
			add_child(soldier);soldiers.append(soldier)
	assert(soldiers.size() == 20)
func attack() -> void:
	for i in range(20):soldiers[i].attack(float((i*3)%5)*.015)
func pose_at(t: float) -> void:
	for i in range(20):soldiers[i].pose_at(maxf(0,t-float((i*3)%5)*.015))
func idle() -> void:
	for soldier in soldiers:soldier.idle()
func _process(_dt: float) -> void:
	assert(transform == origin)
