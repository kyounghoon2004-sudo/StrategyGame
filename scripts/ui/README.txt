# UI 모듈 — Sprint 1/2 #5 Tactical UI / Interview Mode
# 구현 완료: 2026-08-31

## 파일 목록
- scripts/ui/interview_panel.gd + scenes/ui/interview_panel.tscn  # 참모 인터뷰 모드
- scripts/ui/battle_hud.gd + scenes/ui/battle_hud.tscn           # 헥스 전장 HUD
- scripts/ui/mission_result_panel.gd + scenes/ui/mission_result_panel.tscn  # 칙령/전과 보고
- scripts/ui/ui_preview.gd + scenes/ui/ui_preview.tscn           # 통합 데모 씬
- assets/ui/ui_theme.tres                                        # 전역 UI 테마 (StyleBoxFlat + SystemFont)
- assets/ui/ui_*_9patch.png                                      # 9-patch 텍스처 (에디터 시각 품질용, headless는 Flat 대체)

## 사용법 — 코드에서
```gdscript
# 인터뷰
var ip: InterviewPanel = preload("res://scenes/ui/interview_panel.tscn").instantiate()
add_child(ip)
ip.setup_interview("제갈량", "군사 · 병조참의", portrait_tex,
    "전황 브리핑 텍스트...", [
        {"id": &"advance", "text": "전군 전진", "tooltip": "보급 -2일"},
        {"id": &"siege", "text": "포위", "tooltip": "공성병 필수"},
    ])
ip.option_selected.connect(func(id): print("선택: ", id); ip.hide_interview())

# HUD — HexGrid와 바인딩
var hud: BattleHUD = preload("res://scenes/ui/battle_hud.tscn").instantiate()
add_child(hud)
hud.bind_hex_grid($BattleMap/HexGrid)  # cell_clicked 자동 연결
hud.update_supply(12.0)
hud.update_troops(3200, 2800)
hud.update_morale(68.0)
hud.show_unit(unit, q, r)  # Unit 또는 Dictionary
hud.action_requested.connect(func(aid, u): print(aid, u))

# 칙령/전과
var mr: MissionResultPanel = preload("res://scenes/ui/mission_result_panel.tscn").instantiate()
add_child(mr)
mr.show_briefing("칙령", "짐이 명하노니...", "· 목표 A")
mr.show_result({"ally_casualties": 87, "enemy_casualties": 312, "prisoners": 48, "loot": "군량 420석", "fame_delta": 18, "reputation_delta": 12})
```

## 신호
- InterviewPanel.option_selected(option_id: StringName) — 선택지 클릭 시 헥스 맵 가이드라인 연계
- InterviewPanel.dialogue_finished, interview_closed
- BattleHUD.action_requested(action_id: StringName, unit) — 이동 완료/대기/분할/합치/후퇴
- MissionResultPanel.confirmed / dismissed / briefing_confirmed

## 해상도 대응
- 모든 루트 Control은 anchors 0,0,1,1 (canvas stretch keep)
- TopBar 52px 고정, UnitCard bottom-left 앵커, LogPanel bottom-right 앵커
- 1280×720 기본, 1920×1080에서도 비율 유지 (project.godot window/stretch keep)

## 테마
- assets/ui/ui_theme.tres — StyleBoxFlat 기반 (headless/CI 호환), Noto Sans KR 폴백
- 에디터에서 9-patch 텍스처로 교체하려면 Theme의 Button/styles/* 를 StyleBoxTexture로 교체

## 데모
- Godot 에디터에서 scenes/ui/ui_preview.tscn 열기 → ▶ 실행
- 툴바 버튼 또는 F1~F5로 각 UI 호출/토글
- 이벤트 로그에서 시그널 흐름 확인
