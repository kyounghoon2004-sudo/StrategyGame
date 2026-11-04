# Rules V2 (Demon Slayer 헥스 전략) — 인수인계

Bolt/Nemotron/RL 트랙(`handoff.md`)과 **완전히 별개**다. 이 문서는 Rules V2 작업만 다룬다. 2026-11-01 작성.
ROOT = `D:\Game development\Demon slayer\StrategyGame`

## 상태
M1(EDITOR_M1)은 사용자가 "적당히 완료"로 판정했다. **M2 데이터/규칙 검증까지 완료**(아래 M2 구현 절). 아무것도 커밋하지 않았다.

## 설계 문서
- 규칙·결정 기록 전체: [RULES_V2_SPEC.md](RULES_V2_SPEC.md) (5라운드까지, 날짜별)
- 아이콘 PNG 규격·교체법: [assets/ui/v2_icons/README.md](assets/ui/v2_icons/README.md)
- 아이콘 생성용 콜드 프롬프트: [V2_ICON_COLD_PROMPT.md](V2_ICON_COLD_PROMPT.md)

## 지도 데이터
- 사용자가 에디터에서 만든 M1~M5 원본: `D:\StrategyGame_Transfer\maps\`
  - M1 `map_river_roads_20261028.json`
  - M2 `map_m2_gate_fort_polished_20261029.json`
  - M3 `map_1793259718_132100896.json`, M4 `map_1793262735_49462960.json`, M5 `map_1793266255_19431872.json`
- 지도 에디터/에셋 전반 인수인계: `D:\StrategyGame_Transfer\handoff.md`, 에디터 사용법 [tools/dev_visual_lab/MAP_EDITOR.md](tools/dev_visual_lab/MAP_EDITOR.md)
- 전장 JSON(에디터 가져오기 결과): [data/battlefields/editor_v1/](data/battlefields/editor_v1/) — `m1.json`(V2 완성), `m2~m5.json`(지형 껍데기뿐: 유닛·V2 설정 없음)
- 카탈로그 등록: [scripts/battlefields/tutorial_battlefield_catalog.gd](scripts/battlefields/tutorial_battlefield_catalog.gd) (`EDITOR_M1`~`M5`)
- 구운 3D 씬: [data/baked_maps/](data/baked_maps/) — `EDITOR_M1.scn`(약 70 MB)만 있음, 저장소에 넣을지 미정
- 3D 에셋 원본: `assets/map_composition_v0/source_glb/`, 런타임 킷 `D:\StrategyGame_Transfer\runtime_outputs\`

## 코드
- 규칙/보급: [rules_v2.gd](scripts/rules_v2/rules_v2.gd), [supply_v2.gd](scripts/rules_v2/supply_v2.gd)
- 표시: [v2_artifact_layer.gd](scripts/rules_v2/v2_artifact_layer.gd)(아이콘·기지 모델·hover), [v2_fort_layer.gd](scripts/rules_v2/v2_fort_layer.gd)(목책·게이지·휴식), [v2_overlay.gd](scripts/rules_v2/v2_overlay.gd), [v2_action_panel.gd](scripts/rules_v2/v2_action_panel.gd)
- 연결부: [step3_unit_manager.gd](scripts/step3/step3_unit_manager.gd), [step2r_battlefield_shell.gd](scripts/step2r/step2r_battlefield_shell.gd), [civ_battlefield_view.gd](scripts/visual/civ3d/civ_battlefield_view.gd), [combat_calculator.gd](scripts/combat/combat_calculator.gd), [step3_config.gd](scripts/core/step3_config.gd), [presentation_orientation.gd](scripts/core/presentation_orientation.gd)
- V2는 지도별 옵트인: `scenario.rules_version="v2"` + `scenario.rules_v2.supply{...}` (m1.json 참고)

## 도구 (tools/rules_v2/)
- 데이터 생성: [gen_m1_gameplay.py](tools/rules_v2/gen_m1_gameplay.py) (M1 하드코딩, M2용 일반화 필요)
- 씬 굽기: [bake_editor_map.gd](tools/rules_v2/bake_editor_map.gd)
- 아이콘 자르기: [cut_icon_sheet.py](tools/rules_v2/cut_icon_sheet.py)
- 테스트: [test_rules_v2.gd](tools/rules_v2/test_rules_v2.gd), [test_village_walk.gd](tools/rules_v2/test_village_walk.gd), [test_fog_artifacts.gd](tools/rules_v2/test_fog_artifacts.gd), [live_click_test.gd](tools/rules_v2/live_click_test.gd), [run_m1_headless.gd](tools/rules_v2/run_m1_headless.gd)
- 스크린샷: [shot_m1.gd](tools/rules_v2/shot_m1.gd) 외 `shot_*.gd`, 결과물 [tools/rules_v2/shots/](tools/rules_v2/shots/)

## 실행
- Godot 4.2.2: `C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe`
- 게임: `--path "D:/Game development/Demon slayer/StrategyGame" res://scenes/step2r_battlefield_shell.tscn -- --battlefield=EDITOR_M1` (PowerShell에서는 경로를 한 문자열로)
- 헤드리스 테스트: `godot --headless --path . --script res://tools/rules_v2/test_rules_v2.gd`

## M2 시작 시 알아둘 것
- M2 지도: `fort/stronghold` E(4,1) 하나, 마을 오른쪽 아래 E(9..11, 6..9), 강 없음. 역할(공격/수비), 부대, HQ 위치는 사용자에게 물어야 한다.
- 에디터 좌표 E → 게임 좌표 G(q,r)=E(−q,−r) (180° 회전).
- 미완: 빨강 AI의 약탈·승진·요새화, python_sim 불일치, 수치는 1차 튜닝.

## M2 구현 (2026-11-01)
- 확정: **중립 요새 쟁탈전**(점령=승리, 30라운드), 파랑은 마을에서 시작, 빨강은 산맥 너머 북쪽에서 남하(조우전 아님). 궁병 1기씩 첫 등장, 마을 구조물은 회관 1칸, 요새 450 HP, 언덕 삭제, 보급은 M1과 동일, 3D 씬은 로컬만 굽고 git 제외.
- 방향: 6방향을 실제 카메라 투영으로 채점 → **k=3(180°, G=-E)이 유일하게 마을이 아래 + 산맥이 가로**. M1 파이프라인 그대로 재사용. 요새가 산맥 띠의 틈에 정확히 들어간다.
- 데이터: `data/battlefields/editor_v1/m2.json` (회전 저장, 유닛 8v8, 요새 G(-4,-1) 중립 450, 회관 G(-10,-7) 300). 생성기 [tools/rules_v2/gen_m2_gameplay.py](tools/rules_v2/gen_m2_gameplay.py).
- 씬: `data/baked_maps/EDITOR_M2.scn` (35 MB, 로컬 생성, gitignore). 베이크는 `SG_VISUAL_OUTPUT_ROOT=D:/StrategyGame_Transfer/runtime_outputs` 필요 + `--skip-hills`(언덕 모델 제외).
- 테스트: `check_m2.gd` 17개 / `test_m2_fort.gd` 9개 통과 (중립 요새 양측 공격 가능, 450 HP에 95 피해 → 5방, 점령 시 소유권 플립).
- **주의**: 셸을 헤드리스로 띄우는 테스트(`check_m2`의 초기 버전)는 EDITOR_M2에서 씬 로드 후 멈춘다(스크립트 오류 없음). 규칙 검증은 Step3UnitManager 레벨에서 한다.
- **미해결(밸런스)**: 요새는 지금 관문이 아니다. 요새+주변 6칸을 막아도 마을→북쪽 거리가 587칸에서 0 변화, 요새가 필요한 칸은 73칸(북동 끝)뿐. 관문으로 만들려면 산 12~16칸 diff + 원본 맵 수정이 함께 필요.
- **미해결(거리)**: 사용자 선택은 "원거리 18헥스+"였지만 북쪽 필드에서 확보된 최대치는 빨강 HQ→요새 15(파랑 12). 더 멀리 보내려면 서쪽 숲/경계로 밀어야 한다.

### HQ 클릭 표현 (2026-11-01, V2 맵 전체)
- HQ 선택 시 사기 Δ 히트맵(치유 반경 +10 초록 → normal 0 페이드 → 경계 앰버 링) + **주변 탈색/감광**(셰이더 1패스, desat 0.85 / dim 0.30). 적은 실루엣으로 남는다.
- 반경은 맵의 `rules_v2.supply` near/normal을 그대로 재사용. 별도 사기 반경 변수 없음.
- 구현: [v2_overlay.gd](scripts/rules_v2/v2_overlay.gd) → [v2_hq_focus.gd](scripts/rules_v2/v2_hq_focus.gd) + [v2_hq_focus.gdshader](scripts/rules_v2/v2_hq_focus.gdshader), CanvasLayer **6**(보드·배지 5 위, HUD 30/40 아래).
- **삽질 기록**: `uniform vec2 : source_color`는 컴파일 실패(vec3/vec4 전용). 셰이더가 깨지면 화면이 단색으로 덮여 스크린샷이 30KB가 된다.
- 보급선: `fixed_paths()`가 첫 기지 건설을 기다리지 않는다. 변두리 기지가 `edge_link` 안이면 즉시 HQ와 연결(M1 실측 8/5헥스, 둘 다 즉시 연결). 두께는 거리 기반 **기지에서 10px → 5헥스에서 3px → 1.2px 바닥**.
- 테스트: `test_hq_hud.gd`(10개), `test_village_walk.gd`의 옛 "건설 전 선 없음" 단언 갱신.
- 캡처: `shot_hq_focus.gd` → `tools/rules_v2/shots/EDITOR_M1_hq_focus*.png`.
- **작업 규칙**: 앞으로 보고/작업 시 스크린샷을 항상 첨부한다(사용자 지시 2026-11-01).

### 밴드 투영 정정 (2026-11-01, 플레이 테스트 후)
- 2D 캔버스 좌표로 그리면 **3D 원근 카메라**와 어긋난다(줌하면 심해짐). 화면공간 선형 기저도 마찬가지.
- 최종: [v2_hq_focus.gd](scripts/rules_v2/v2_hq_focus.gd) `_draw_bands()`가 **헥스 정점 6개를 각각** `cam.unproject_position`으로 투영. 줌/회전 무관하게 보드와 일치.
- 블러: `CanvasLayer -1` 한 패스(2px, 9탭, desat 0.35). 배지(5)·보급선·밴드·HUD는 그 위라 선명. 리드로우는 카메라 시그니처가 바뀔 때만.
- 사용자 취향 확정: 블러 **약하게**, 경계선 **1px 반투명(α0.60)**, 중간 구간 **앰버 유지**.

## 강행군(초과 이동력) 폐기 (2026-11-03)
V2 지도에서만 폐기. 기본 이동력이 전체 예산, 범위 밖 클릭은 무반응, 이동력이 남으면 인접 한 칸은 항상 진입 가능. 게임 전체 적용 시 바꿀 곳 목록은 [RULES_V2_SPEC.md](RULES_V2_SPEC.md) 맨 아래 절. 테스트 [test_move_cap.gd](tools/rules_v2/test_move_cap.gd).

## M1 완료 및 스냅샷 (2026-11-04)
M1은 사용자가 "기능적으로 완성"으로 판정. 최적화/디버깅용 스냅샷: `D:\Game development\Demon slayer\StrategyGame_M1_snapshot\` (README.md, MANIFEST.txt 참고).
요점: 안에는 V2 코드·변경된 공유 파일·M1 데이터·구운 씬·아이콘·도구가 같은 상대 경로로 들어 있고, `_original_HEAD/`에 수정 전 원본이 있어 diff가 된다. 아무것도 git에 커밋하지 않았다.
