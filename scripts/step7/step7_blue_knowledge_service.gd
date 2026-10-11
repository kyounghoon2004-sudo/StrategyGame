class_name Step7BlueKnowledgeService
extends RefCounted

var projector: RefCounted

func configure(projector_ref: RefCounted) -> void:
	projector = projector_ref

func build(turn: int) -> Dictionary:
	return projector.build_blue_knowledge(turn) if projector else {"side": "blue"}
