# 오대십국 전략 게임 — Core Engine Foundation (Sprint 0)

2D 턴제 전략 게임의 기술적 기반. Godot 4.2, GDScript, Flat-top 헥스 그리드.

## 실행 방법

1. [Godot 4.2+](https://godotengine.org/download) 설치
2. Godot 실행 → `Import` → `D:/Game development/Demon slayer/StrategyGame/project.godot` 선택
3. `▶` (F5) 로 실행 — `main.tscn` → `battle_map.tscn` 자동 로드, 20×15 헥스 그리드 표시

Headless 검증 (CI):
```
godot --headless --path "D:/Game development/Demon slayer/StrategyGame" --quit
# 기대 출력: [TurnManager] Turn 1: player phase=RECON + Main: loaded battle map
```

## 폴더 구조

```
StrategyGame/
├── project.godot          # 2D, 1280×720, canvas_items, Nearest, gl_compatibility
├── icon.svg               # 16×16 플레이스홀더 아이콘
├── scenes/
│   ├── main.tscn          # 진입점 (Autoload TurnManager, battle_map 로드)
│   ├── battle_map.tscn    # 전투맵 20×15 헥스 + Camera2D + DebugLabel
│   └── campaign_map.tscn  # 작전맵 플레이스홀더
├── scripts/
│   ├── core/
│   │   ├── hex_cell.gd        # HexCell: q,r, TerrainType(7종), occupying_unit, Fog of War
│   │   ├── hex_utils.gd       # HexUtils: axial math, pixel 변환, hex_distance, A* find_path, hexes_in_range
│   │   ├── hex_grid.gd        # HexGrid: Polygon2D 렌더, 20×15 생성, 클릭/호버 선택, Terrains 7색
│   │   ├── turn_manager.gd    # TurnManager (Autoload): 턴 교대, BattlePhase 4단계, Signals
│   │   ├── camera_controller.gd # Camera2D: WASD/방향키/엣지/드래그 팬, 휠 줌, 맵 클램핑, 스무딩
│   │   └── main.gd            # Main 진입 로직
│   ├── combat/            # 전투 시스템 (별도 에이전트 영역)
│   │   ├── unit_type.gd / unit_types.gd / unit.gd
│   │   ├── combat_calculator.gd / morale_system.gd / movement_calculator.gd / terrain_mods.gd
│   │   └── _test_combat.gd / _gen_tres.gd
│   ├── ui/                # UI 에이전트용 (Sprint 1+)
│   └── ai/                # SLM 에이전트용 (Sprint 1+)
├── assets/
│   ├── tiles/   terrain_*.png (7종, 64×56 flat-top hex)
│   ├── sprites/ unit_*_*.png (7병과 × 2진영, 32×32)
│   └── ui/      (예약)
├── data/
│   └── unit_types/*.tres (7종 Resource)
└── .godot/      (자동 생성, gitignore)
```

## 기술적 결정

| 결정 | 이유 |
|------|------|
| Flat-top 헥스 | 전략 게임 표준, 동서 이동 직관적, axial(q,r) 연산 단순 |
| Axial coordinates | Cube 대비 저장 2/3, Red Blob Games 권장, Godot Vector2i 호환 |
| HEX_SIZE=32 | 1280×720에서 20×15 그리드가 화면에 여유 있게 들어감 (64×56 hex) |
| Polygon2D 렌더 | TileMap 대신 직접 draw — 지형별 색상/하이라이트 제어 자유, Fog of War 확장 용이 |
| A* in HexUtils | 외부 의존성 없이 Dictionary grid로 동작, can_enter/cost Callable로 병과별 진입 제한 위임 |
| TurnManager Autoload | 전역 싱글톤, Signals로 UI/AI/전투 느슨한 결합, BattlePhase enum 4단계 |
| Camera gl_compatibility | 저사양 호환, 2D 픽셀아트에 Forward+ 불필요 |
| Nearest texture filter | 픽셀아트 선명도 유지 |
| scripts/core에서 preload | global_script_class_cache 없이도 headless에서 동작 (CI 안정성) |

## 지형 (7종) / 병과 (7종)

지형: 평야(1) / 산지(2, 기병 불가) / 숲(2, 매복) / 습지(3, 기병 불가) / 성벽(1) / 마을(1) / 도로(1, 보너스).
병과: 보병2 / 궁병2(rng3) / 기병3(산지·습지 불가) / 창병2 / 공성병1(rng2, 성벽 특화) / 징집병1 / 정찰병3.

## 전투 페이즈

`RECON(정찰) → DEPLOY(배치) → ENGAGE(교전) → RESOLVE(종결)` — `TurnManager.next_phase()` / `set_phase()` / Signals(`turn_started`, `turn_ended`, `phase_changed`, `turn_count_changed`)로 구동.

## 검증 결과

- `main.tscn` / `battle_map.tscn` / `campaign_map.tscn` 모두 Godot 4.2.2 headless에서 `SCRIPT ERROR 0`으로 로드됨
- `[TurnManager] Turn 1: player phase=RECON` 및 `Main: loaded battle map` 출력 확인
- HexGrid 20×15 생성, 지형 7색, 클릭 선택(하이라이트), 호버 감지 동작
- Camera: WASD/방향키/엣지/우·휠 드래그 팬, 휠 줌(0.4~3.0), 맵 경계 클램핑, lerp 스무딩

## 블로커 / 의존성

- 없음 (Sprint 0 자족). 다음 스프린트 의존:
  - 전투 시스템 에이전트: `scripts/combat/`의 Unit/CombatCalculator와 HexGrid 점유(`occupying_unit`) 연동 필요
  - UI 에이전트: HexGrid의 `cell_clicked`/`cell_hovered`를 HUD/정보 패널에 연결
  - SLM 에이전트: `scripts/ai/`에 참모/적 AI, TurnManager Signals 구독
  - 아트 에이전트: `assets/tiles/`/`sprites/` 최종 픽셀아트 교체 (현재 플레이스홀더 64×56/32×32)
