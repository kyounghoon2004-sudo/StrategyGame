extends Node

## Central turn-state machine for the strategy game.
## Emits signals for faction turns and phase transitions so that
## UI, AI, and combat systems can react without tight coupling.
##
## Phase enum:
##   RECON  - 정찰/정보 (Phase 1)
##   DEPLOY - 배치 (Phase 2)
##   ENGAGE - 교전 (Phase 3)
##   RESOLVE - 종결 (Phase 4)
##
## Turn counter increments once per full cycle (player + enemy).
## Autoload singleton - accessible as TurnManager everywhere.
## Note: No class_name to avoid collision with autoload name.

signal turn_started(faction: StringName)
signal turn_ended(faction: StringName)
signal phase_changed(old_phase: int, new_phase: int, faction: StringName)
signal turn_count_changed(turn: int)

## ---- Phase constants ----
enum BattlePhase {
	RECON = 0,    # Phase 1: 정찰/정보 - 참모 인터뷰 모드
	DEPLOY = 1,   # Phase 2: 배치 - 헥스 맵에서 부대 배치
	ENGAGE = 2,   # Phase 3: 교전 - 인터뷰 + 헥스 턴제 전투
	RESOLVE = 3   # Phase 4: 종결 - 결과 보고, 추격/철수 결정
}

## ---- State ----
var current_turn: int = 0
var current_faction: StringName = &"player"
var current_phase: int = BattlePhase.RECON
var is_player_turn: bool = true

# Faction names (configurable; default two-faction)
var player_faction: StringName = &"player"
var enemy_faction: StringName = &"enemy"

# Step2R shell-mode guard — when true, suppresses automatic turn/phase progression.
# Default OFF (false) so normal game behavior is unaffected.
# Step2R battlefield shell sets this true on _ready and restores on _exit_tree.
var shell_mode: bool = false


func _ready() -> void:
	if shell_mode:
		print("[TurnManager] shell_mode=ON — suppressing auto start_player_turn")
		return
	start_player_turn()


## Begin the player's turn: increment turn counter, set faction, emit signals.
func start_player_turn() -> void:
	if shell_mode:
		print("[TurnManager] shell_mode=ON — start_player_turn suppressed")
		return
	current_turn += 1
	current_faction = player_faction
	is_player_turn = true
	current_phase = BattlePhase.RECON
	turn_started.emit(player_faction)
	turn_count_changed.emit(current_turn)
	phase_changed.emit(BattlePhase.RECON - 1, BattlePhase.RECON, player_faction)
	print("[TurnManager] Turn %d: %s phase=RECON" % [current_turn, player_faction])


## Advance from player turn to enemy turn.
func advance_to_enemy_turn() -> void:
	if shell_mode:
		return
	if not is_player_turn:
		return
	turn_ended.emit(player_faction)
	current_faction = enemy_faction
	is_player_turn = false
	current_phase = BattlePhase.RECON
	turn_started.emit(enemy_faction)
	phase_changed.emit(BattlePhase.RECON - 1, BattlePhase.RECON, enemy_faction)
	print("[TurnManager] Turn %d: %s phase=RECON" % [current_turn, enemy_faction])


## Advance from enemy turn back to player turn (next day).
func advance_to_player_turn() -> void:
	if shell_mode:
		return
	if is_player_turn:
		return
	turn_ended.emit(enemy_faction)
	start_player_turn()


## Set the battle phase within the current faction's turn.
func set_phase(phase: int) -> void:
	if shell_mode:
		print("[TurnManager] shell_mode=ON — set_phase(%d) suppressed" % phase)
		return
	if phase < BattlePhase.RECON or phase > BattlePhase.RESOLVE:
		push_warning("TurnManager.set_phase: invalid phase %d" % phase)
		return
	var old_phase: int = current_phase
	current_phase = phase
	phase_changed.emit(old_phase, phase, current_faction)
	print("[TurnManager] %s phase: %d -> %d" % [current_faction, old_phase, phase])


## Advance to the next phase (RECON -> DEPLOY -> ENGAGE -> RESOLVE).
func next_phase() -> void:
	if shell_mode:
		return
	var next: int = current_phase + 1
	if next > BattlePhase.RESOLVE:
		if is_player_turn:
			advance_to_enemy_turn()
		else:
			advance_to_player_turn()
	else:
		set_phase(next)


## Check if the given faction is currently active.
func is_faction_active(faction: StringName) -> bool:
	return current_faction == faction


## Get a human-readable phase label.
static func phase_label(phase: int) -> String:
	match phase:
		BattlePhase.RECON:   return "정찰/정보"
		BattlePhase.DEPLOY:  return "배치"
		BattlePhase.ENGAGE:  return "교전"
		BattlePhase.RESOLVE: return "종결"
		_:                   return "알 수 없음"


## Reset turn state (for testing / new battle).
func reset_turn_state() -> void:
	if shell_mode:
		print("[TurnManager] shell_mode=ON — reset_turn_state suppressed")
		return
	current_turn = 0
	current_faction = player_faction
	is_player_turn = true
	current_phase = BattlePhase.RECON
	turn_started.emit(player_faction)
	turn_count_changed.emit(current_turn)
