# 오대십국 전략 — Five Dynasties Strategy

> *낙양 탈환 작전* — 고전 한국/중국 전략 명작 감성의 픽셀풍 턴제 헥스 전략 게임.
> 보병·궁병·기병·창병·공성병의 상성, 사기·보급 시스템, SLM 인공지능 참모, 4장 풀 캠페인까지.

---

## 🎮 빠른 시작

### Windows (권장)
프로젝트 루트(`StrategyGame/`)의 **`Play_StrategyGame.bat`** 을 더블클릭하면 게임이 즉시 실행됩니다.

```
D:\Game development\Demon slayer\StrategyGame\Play_StrategyGame.bat
```

배치 파일은 다음 위치에서 Godot 바이너리를 자동 탐색합니다:
1. `%GODOT_BIN%` 환경변수
2. `C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe`
3. `C:\Users\kyoun\AppData\Local\Programs\Godot\godot-editor-win64.exe`
4. `C:\Program Files\Godot\godot.exe`

다른 경로에 설치했다면 `set GODOT_BIN=C:\your\path\godot.exe` 후 실행하세요.

### 콘솔에서 직접 실행
```bash
"/c/Users/kyoun/AppData/Local/Programs/Godot/godot-editor-win64.exe" \
    --path "D:/Game development/Demon slayer/StrategyGame"
```

---

## 📖 게임 소개

### 배경
오대십국 시대(907~960), 대당 왕조의 마지막 황제 **장종** 아래 모인 신하들이 5대 십국 군웅을 제압하고 천하를 통일하는 로그라이트 캠페인. 플레이어는 **장군**이 되어 4장의 전투를 승리로 이끌고, 궁중의 어명을 받들어 낙양 탈환을 완수해야 합니다.

### 게임 흐름
1. **브리핑** — 황제의 칙령이 하달되고, 참모(서유선)의 조언이 표시됩니다.
2. **전투** — 헥스 그리드 위에서 부대를 이동·배치·교전합니다.
3. **결산** — 사상자·포로·전리품·명성 변화가 보고됩니다.
4. **다음 장** — 보급과 사기가 회복/감소하며 다음 미션이 주어집니다.

### 부대 상성 (요약)
| 공격 ↓ / 방어 → | 보병 | 궁병 | 기병 | 창병 | 공성 |
|---|---|---|---|---|---|
| 보병 | 1.00 | 1.20 | 0.85 | 0.85 | — |
| 궁병 | 0.83 | 1.00 | 1.35 | 0.74 | — |
| 기병 | 1.18 | 0.74 | 1.00 | 0.71 | — |
| 창병 | 1.18 | 1.35 | 1.40 | 1.00 | — |

상세: `scripts/combat/combat_calculator.gd` 참조.

---

## 🏗️ 프로젝트 구조

```
StrategyGame/
├── project.godot              # Godot 프로젝트 설정 + Autoload 등록
├── icon.svg                   # 게임 아이콘
├── generate_sfx.py            # 프로그래머틱 SFX 생성기 (numpy + wave)
├── generate_assets_v3.py      # 픽셀 아트/타일 생성기
├── Play_StrategyGame.bat      # 원클릭 실행 런처
├── README.md                  # 기존 문서
├── README_FINAL.md            # ← 현재 문서 (최종)
├── assets/
│   ├── audio/                 # ★ SFX WAV (12개, ~1.1 MB)
│   ├── sprites/               # 유닛 스프라이트 (아군 청색 / 적군 적색)
│   ├── tiles/                 # 헥스 타일 텍스처
│   └── ui/                    # UI 아이콘
├── scenes/
│   ├── title_screen.tscn      # ★ 타이틀 화면 (신규)
│   ├── main.tscn              # 메인 게임 씬
│   ├── battle_map.tscn        # 헥스 전투 맵
│   ├── campaign_map.tscn      # 캠페인 맵
│   └── ui/                    # HUD, 인터뷰 패널, 결과 패널
├── scripts/
│   ├── core/
│   │   ├── audio_manager.gd   # ★ 오디오 싱글톤 (Autoload)
│   │   ├── battle_map.gd      # 전투 루프 + ★ 쥬스(셰이크/배너/플로팅)
│   │   ├── turn_manager.gd    # 턴/페이즈 상태 머신 (Autoload)
│   │   ├── hex_grid.gd
│   │   ├── hex_cell.gd
│   │   ├── hex_utils.gd
│   │   ├── camera_controller.gd
│   │   ├── unit_renderer.gd
│   │   └── main.gd
│   ├── combat/                # 전투 계산·사기·이동·유닛
│   ├── ui/                    # HUD, 인터뷰, 결과, ★ 타이틀
│   ├── campaign/              # 캠페인 매니저 + 게임 디렉터
│   └── ai/                    # SLM 클라이언트 + 폴백 룰 기반 AI
└── data/
    └── unit_types/*.tres      # 보병/궁병/기병/창병/공성병/징집병/정찰병 정의
```

---

## 🔊 SFX 카탈로그 (12종, 모두 프로그래머틱 합성)

| 파일 | 의도 | 길이 | 생성 원리 |
|---|---|---|---|
| `sfx_march.wav` | 행군 북소리 | 1.54 s | 70/140 Hz 정현파 + 노이즈 임팩트 × 4회 |
| `sfx_sword_clash.wav` | 칼 부딪힘 | 0.55 s | 고역 통과 노이즈 + 2.2/3.3/4.4 kHz 금속 공명 |
| `sfx_arrow_volley.wav` | 화살 일제 사격 | 0.90 s | 펄스 변조 노이즈 + 3.5→4.5 kHz sweep whine |
| `sfx_spear_brace.wav` | 창벽 방진 | 0.90 s | 짤깠 임팩트 × 4 + 220 Hz 공명 |
| `sfx_siege_ram.wav` | 성벽 충각 | 1.20 s | 50 Hz 사인 + 저역 통과 노이즈 |
| `sfx_morale_break.wav` | 패주 징 | 1.40 s | 사이렌 글리산도 + 비명 노이즈 |
| `sfx_decree_gong.wav` | 궁중 징 | 2.40 s | 120 Hz 펑더멘털 + 6 인하모닉 + 긴 리버브 |
| `sfx_victory_fanfare.wav` | 승전 팡파르 | 5.39 s | C/E/G/C 라르조 트럼펫 멜로디 + 징 |
| `sfx_defeat_funeral.wav` | 패전 비장 | 8.02 s | E♭ 단조 행진 + 큰북 |
| `sfx_ui_select.wav` | UI 선택 | 0.04 s | 880 Hz 펄스 |
| `sfx_ui_hover.wav` | UI 호버 | 0.03 s | 660 Hz 사인 |
| `sfx_turn_change.wav` | 턴 체인지 | 0.08 s | C5+E5 2화음 |

### SFX 재생성
```bash
python generate_sfx.py
python generate_sfx.py --out custom/path --loud    # +3 dB 부스트
```
의존성: Python 3.11+, numpy 2.x. scipy 불필요 (순수 numpy 합성).

---

## ✨ 쥬스(Juice) — Sprint 4 추가

### 1. 카메라 셰이크
- **연출**: 6단계 다방향 트윈 (X/Y 자유)
- **트리거**: 큰 피해 (≥ 25명) / 패주 / 승패
- **강도**: `0.4 ~ 1.6` 사이 피해량 비례

### 2. 플로팅 데미지 텍스트
- **크기 배율**: 1.0× (기본) → 1.25× (10명↑) → 1.6× (25명↑)
- **색상**: 적 피해 `#FFEC8C`(황금), 아군 피해 `#FF8C8C`(붉은)
- **모션**: 트윈 위로 떠오르며 페이드 아웃
- **외곽선**: 2 px 검정 외곽선 (가독성 ↑)

### 3. 화면 상단 슬라이드 배너
- **등장**: 화면 밖 (y=-120) → 화면 안 (y=+80, 0.32 s BACK_OUT)
- **유지**: 1.5 s
- **퇴장**: 화면 밖 (0.42 s BACK_IN)
- **트리거**:
  - 턴 카운터 변화 (`제 N턴`)
  - 적 턴 시작 (`적의 턴`)
  - 황제 어명 (`칙 령`)
  - 전투 승 (`대 승`)
  - 전투 패 (`패 퇴`)

### 4. SFX 자동 트리거 매핑
| 게임 이벤트 | 트리거 SFX | 쥬스 |
|---|---|---|
| `cavalry` 공격 | `sword_clash` | 카메라 흔들 (큰 피해 시) |
| `spearmen` 공격 | `spear_brace` | ↑ |
| `archers` 공격 | `arrow_volley` | ↑ |
| `siege` 공격 | `siege_ram` | ↑ |
| `infantry` 공격 | `sword_clash` | ↑ |
| 부대 이동 시작 | `march` | — |
| 패주 발생 | `morale_break` | 강한 셰이크 |
| 어명 하달 | `decree_gong` | 배너 슬라이드 |
| 승리 | `decree_gong` → `victory_fanfare` | 배너 + 강한 셰이크 |
| 패배 | `defeat_funeral` | 배너 + 강한 셰이크 |
| 턴 카운터 증가 | `turn_change` | 배너 슬라이드 |
| UI 호버 | `ui_hover` | — |
| UI 클릭 | `ui_select` | — |

---

## ⚙️ SLM 인공지능 설정 (선택)

`타이틀 화면 → SLM 인공지능 설정` 에서 Ollama 호스트 URL 과 모델 이름을 변경할 수 있습니다.
설정은 `user://slm_settings.cfg` 에 저장되며 다음 게임 실행 시 자동 로드됩니다.

**기본값**: `http://localhost:11434` / `qwen2:7b`

Ollama 가 실행 중이지 않으면 게임은 자동으로 룰 기반 폴백 AI 로 동작합니다 (네트워크 오류에도 게임 진행에 지장 없음).

---

## 🎮 조작

| 키 / 입력 | 동작 |
|---|---|
| 좌클릭 (아군 유닛) | 유닛 선택 / 이동 / 공격 |
| 우클릭 | 카메라 컨텍스트 메뉴 |
| WASD / 화살표 | 카메라 이동 |
| 마우스 휠 | 줌 인/아웃 |
| `Enter` / 턴 종료 버튼 | 적 턴으로 진행 |
| `F5` | 강제 승리 (디버그) |
| `F6` | 강제 패배 (디버그) |
| `ESC` | SLM 패널 닫기 |

---

## 📊 부록: 파일 통계 (Sprint 4 #10)

```
새로 만든 파일:
  generate_sfx.py                                  19 KB
  scripts/core/audio_manager.gd                    12 KB
  scripts/ui/title_screen.gd                        8 KB
  scenes/title_screen.tscn                         10 KB
  Play_StrategyGame.bat                             2 KB
  assets/audio/*.wav (12종)                     ~1090 KB

수정한 파일:
  project.godot                            (Autoload + main_scene)
  scripts/core/battle_map.gd               (사운드/쥬스 후크)
  scripts/campaign/game_director.gd        (어명 사운드/배너)
```

---

## 📜 라이선스 / 의존성

- **Godot Engine**: MIT (Godot Engine project)
- **numpy**: BSD-3-Clause
- **wave / struct**: Python stdlib

본 프로젝트의 모든 게임 콘텐츠(코드, 픽셀 아트, 오디오 합성 함수)는 프로젝트 작성자의 저작물입니다.

---

*오대십국 전략 v0.4.0 — Polish & Release · 2026*