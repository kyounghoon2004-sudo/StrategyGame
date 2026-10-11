# 아트 디렉션 가이드 — 오대십국 전략 게임 (Five Dynasties Strategy)
**버전:** Sprint 0 #3 — 2026-08-31  
**엔진:** Godot 4.2 (Forward Plus / gl_compatibility)  
**스타일:** 미니멀 2D 픽셀아트 — Advance Wars / GBA Fire Emblem 계열, 가독성 최우선

---

## 1. 핵심 원칙 (확정)

| 우선순위 | 원칙 | 설명 |
|---|---|---|
| 1 | **가독성 Readability** | 전략 줌(0.5~1.0x)에서 병과·지형·진영이 0.3초 내 식별 |
| 2 | 심미성 Aesthetics | 절제된 색수, 깔끔한 실루엣, 과장 없는 디테일 |
| 3 | 절제된 디테일 | 48px 타일 안 3~4색으로 완결, 노이즈 금지 |

- **탑다운 직교 투영**: 그림자는 남동쪽 1px, 하이라이트는 북서쪽 1px
- **아웃라인 규칙**: 모든 스프라이트 1px 다크 아웃라인 `#141418`, 타일은 `#2B2B2B` 계열
- **픽셀 퍼펙트**: 회전/스케일 없는 정수 좌표 배치, Filter = Nearest

---

## 2. 컬러 팔레트 (Hex 코드)

### 2.1 진영 색상 — 즉시 식별이 최우선

| 용도 | Hex | 설명 |
|---|---|---|
| **아군 Primary Blue** | `#2F80ED` | 채도 높은 청색, 메인 갑옷/망토 |
| 아군 Shadow | `#1B4C8A` | 음영, 다리/헬멧 그림자 |
| 아군 Highlight | `#7AB0FF` | 하이라이트 1px, 북서쪽 엣지 |
| 아군 Dark | `#0F2A52` | 벨트/깊은 음영 |
| 아군 Outline | `#0A1E3A` | 텍스트/아이콘 외곽 |
| **적군 Primary Red** | `#EB5757` | 채도 높은 적색, 같은 명도에서 Blue와 구분 |
| 적군 Shadow | `#8B2525` | 음영 |
| 적군 Highlight | `#FF8A80` | 하이라이트 |
| 적군 Dark | `#5A1A1A` | 깊은 음영 |
| 적군 Outline | `#3D0F0F` | 외곽 |

> **접근성:** Blue `#2F80ED` (L=52) vs Red `#EB5757` (L=58) — 명도 유사, 색상 대비로 구분. 색각 이상자를 위해 **실루엣**으로도 구분되게 설계 (아래 2.3 참조).

### 2.2 지형 팔레트

| 지형 | Base | Light | Dark | Outline | 용도 |
|---|---|---|---|---|---|
| **평야 Plains** | `#8BC67A` | `#A8D98A` | `#6BA055` | `#3B4D2F` | 기본 잔디, 가장 밝고 채도 낮음 |
| **산지 Mountains** | `#C9C5B8` | `#E6E2D6` | `#6B6862` | `#3D3B38` | 암회색 바위 + 흰 설관 `#F2F2F2` |
| **숲 Forest** | `#7FB069` | `#5FAF5A` | `#2F5D32` | `#1E3A22` | 어두운 캐노피, 줄기 `#5D4037` |
| **습지 Swamp** | `#8A9A7B` | `#A8B89A` | `#4E3D2C` | `#3A4032` | 탁한 갈녹색, 물 `#6B7C8A` |
| **요새 Fortress** | `#B8BEC2` | `#D6DBDF` | `#7A848C` | `#2C2E30` | 석조, 지붕 `#4A4A4A`, 문 `#3E3A33` |
| **마을 Village** | `#8BC67A`* | `#E8DCC8` (벽) | `#5A5E62`/`#7A3B2E` (지붕) | `#3A2E28` | *바탕은 Plains 동일, 건물로 구분 |
| **도로 Road** | `#C2A47A` | `#D7BF9A` | `#8D7355` | `#5A4A32` | 황토/돌길, 포석 `#A99E93` |

### 2.3 공통 보조 팔레트

| 색상 | Hex | 용도 |
|---|---|---|
| 피부 Skin | `#F2C9A0` | 얼굴 |
| 피부 Shadow | `#D4A77A` | 턱/코 그림자 |
| 금속 Metal | `#C0C8D0` | 검/창날 |
| 금속 Light | `#E8EEF2` | 날 하이라이트 |
| 금속 Dark | `#8A9098` | 날 음영 |
| 목재 Wood | `#8B5A2B` | 방패/자루 |
| 목재 Dark | `#5D3A1A` | 그림자 |
| 금 Gold | `#D4A843` | 벨트/장식 |
| 선택 Selection | `#FFD54F` / `#FFF176` | 선택 헥스 외곽 |
| 이동 Move Range | `rgba(47,128,237,0.31)` | 반투명 청색 오버레이 |
| 공격 Attack Range | `rgba(235,87,87,0.29)` | 반투명 적색 오버레이 |
| 안개 Fog | `rgba(30,30,40,0.67)` | Fog of War |

---

## 3. 타일 규격

### 3.1 헥스 타일 — Flat-top

```
해상도: 48px (W) x 42px (H) — 32x28 대안 시 동일 비율 스케일 (1.5x)
형태: Flat-top (상/하단 평평)
정점 (시계방향, 좌표 원점 좌상단):
  (12,0) — (36,0) — (48,21) — (36,42) — (12,42) — (0,21)
내부 여백: 상단 1px 하이라이트 라인 (#B8E0A8 등), 하단 1px 그림자 밴드
파일: PNG-32, 투명 배경, 헥스 외부 완전 투명 (alpha 0)
명명: terrain_<type>.png (소문자+언더바)
```

**타일링 수학 (Flat-top, 홀수 열 오프셋):**
```gdscript
const TILE_W = 48
const TILE_H = 42
# 헥스 중심 간격
const HEX_COL_STEP = TILE_W * 0.75  # 36px
const HEX_ROW_STEP = TILE_H         # 42px

func hex_to_pixel(q: int, r: int) -> Vector2:
    # q=열, r=행 (offset coords, odd-q)
    var x = q * HEX_COL_STEP
    var y = r * HEX_ROW_STEP + (q % 2) * (TILE_H * 0.5)
    return Vector2(x, y)

# 인접 6방향 (odd-q)
const DIRS_EVEN = [Vector2(1,0), Vector2(0,-1), Vector2(-1,-1), Vector2(-1,0), Vector2(-1,1), Vector2(0,1)]
const DIRS_ODD  = [Vector2(1,0), Vector2(1,-1), Vector2(0,-1), Vector2(-1,0), Vector2(0,1), Vector2(1,1)]
```

**타일별 시각 특징 (줌 가독성 체크):**

| 타일 | 핵심 실루엣 | 28px 축소 시 식별 포인트 |
|---|---|---|
| `terrain_plains.png` | 연녹색 평면 + 드문 1px 짙은 점 | 가장 밝음 — 기준 배경 |
| `terrain_mountains.png` | 중앙 삼각 능선 + 흰 설관, 좌우 2봉 | 회색+흰 점 — 고도감 |
| `terrain_forest.png` | 3개 원형 캐노피(짙은 녹) + 갈색 줄기 | 어두운 녹 덩어리 3개 |
| `terrain_swamp.png` | 갈색 진흙 웅덩이 + 청회색 물 + 수직 갈대 1px | 탁한 녹 + 물 반점 |
| `terrain_fortress.png` | 회색 성벽 + crenellation + 아치 문 + 깃발 | 회색 사각 + 성벽 톱니 |
| `terrain_village.png` | 3채 기와집(회색/적갈 지붕) + 담장 | 지붕 삼각형 3개 |
| `terrain_road.png` | 황토색 십자 도로(수평+수직) + 포석 점선 | 십자 황토 라인 |

### 3.2 Godot TileMap 설정

```
TileSet > Tile Size: 48 x 42
TileSet > Tile Shape: Hexagon
TileSet > Tile Layout: Stacked (flat-top은 Stacked)
TileSet > Tile Offset Axis: Horizontal
Texture Origin: (24, 21) — 헥스 중심
Import > Filter: Nearest (중요! Linear 금지)
Import > Mipmaps: Off
겹침 방지: 타일 간 간격 0, YSort 비활성
```

---

## 4. 병과 스프라이트 규격

### 4.1 공통

```
캔버스: 24 x 24 px, 투명 배경, 중심 정렬
실제 점유: 16~20px (헥스 중앙 여백 2~4px 확보)
아웃라인: 1px #141418
그림자: 타원 10x3 px, alpha 70, y=20
파일: unit_<type>_<faction>.png — type 소문자 단수, faction blue/red
```

### 4.2 병과별 실루엣 키 (가독성 핵심)

| 병과 | 파일 | 실루엣 키 | 크기/위치 | 색 외 구분 |
|---|---|---|---|---|
| **보병 Infantry** | `unit_infantry_blue/red.png` | 좌측 대형 방패(수직 9px) + 우측 은색 검 수직 | 방패 4x9 좌, 검 2x13 우 | 방패 유무 |
| **궁병 Archer** | `unit_archer_blue/red.png` | 우측 활(곡선) + 등 화살통(3개 화살) + 활시위 흰선 | 활 높이 12px 우측 | 활 곡선 |
| **기병 Cavalry** | `unit_cavalry_blue/red.png` | 말(갈색 14x6) + 기수 + 전방 돌출 랜스/깃발 | 전체 18x18, 말 포함 | 말 실루엣 유일 |
| **창병 Spearman** | `unit_spearman_blue/red.png` | **헥스 상단을 뚫는 장창**(세로 전체 22px) + 원형 방패 | 창 1px 수직 전체 | 가장 긴 수직선 |
| **공성병 Siege** | `unit_siege_blue/red.png` | 투석기 A프레임 + 바퀴 2개 + 돌 | 폭 16px, 높이 14px | 기계 실루엣 유일 |
| **징집병 Conscript** | `unit_conscript_blue/red.png` | 밀짚모자(넓은 챙) + 갈퀴(3갈래) + 황토색 누더기 | 챙 폭 8px | 모자 챙 넓음 |
| **정찰병 Scout** | `unit_scout_blue/red.png` | 망토(뒤로 펄럭임) + 후드 + 단검 | 망토 폭 10px | 망토/후드 |

**진영 구분 이중화:**
1. **색상**: 갑옷/망토 Primary가 Blue `#2F80ED` vs Red `#EB5757`
2. **실루엣 보조**: 동일 병과라도 Blue는 하이라이트가 좌상단, Red도 동일 — 색맹 환경에서도 무기 형태·방패·말 등으로 구분 가능

### 4.3 오프셋/앵커

```
Sprite2D > Centered: true
Sprite2D > Offset: (0, -2) — 헥스 중심보다 2px 위 (발이 중심에 닿게)
Z-Index: y 좌표 기반 (TileMap y + sprite y) 또는 YSort 노드 사용
Scale: 1.0 고정 (스케일 시 Nearest 유지, 정수 배수만)
```

---

## 5. UI 요소 규격

| 파일 | 크기 | 용도 | 색상/알파 |
|---|---|---|---|
| `ui_selection.png` | 48x42 | 선택된 헥스 강조 | 외곽 `#FFD54F` 3px + 코너 점 |
| `ui_move_range.png` | 48x42 | 이동 가능 범위 | 채움 `rgba(47,128,237,80)` |
| `ui_attack_range.png` | 48x42 | 공격 가능 범위 | 채움 `rgba(235,87,87,75)` + 십자 |
| `ui_fog.png` | 48x42 | Fog of War | 채움 `rgba(30,30,40,170)` + 빗금 |
| `ui_hex_grid.png` | 48x42 | 에디터 그리드 | 외곽 `rgba(255,255,255,60)` |
| `ui_panel.png` | 96x64 | 9-slice 패널 | 배경 `#2A2620`, 테두리 `#D4A843` |
| `ui_button.png` | 64x20 | 버튼 기본 | 배경 `#464137`, 테두리 `#D4A843` |
| `ui_button_hover.png` | 64x20 | 버튼 호버 | 밝은 배경 + 외곽 글로우 |

**UI 사용 예시 (GDScript):**
```gdscript
# 헥스 위에 오버레이
var overlay = Sprite2D.new()
overlay.texture = load("res://assets/ui/ui_move_range.png")
overlay.centered = true
overlay.position = hex_to_pixel(q, r)
add_child(overlay)
```

---

## 6. Godot 4 임포트 가이드 (필수)

### 6.1 프로젝트 설정 (이미 적용됨)

`project.godot` 확인:
```ini
[rendering]
textures/canvas_textures/default_texture_filter=0  # 0=Nearest
```

### 6.2 개별 텍스처 임포트

각 PNG 선택 → Import 탭:

| 설정 | 값 | 이유 |
|---|---|---|
| **Filter** | **Off (Nearest)** | 픽셀 크리습 유지, 블러 방지 |
| Mipmaps | Off | 2D 픽셀아트에 불필요, 메모리 절약 |
| Repeat | Disabled | 타일은 개별 배치 |
| Fix Alpha Border | On | 헥스 가장자리 하얀선 방지 |

> **중요:** Import 후 **Reimport** 클릭. Filter가 Linear로 남아있으면 0.5x 줌에서 픽셀 뭉개짐 발생.

### 6.3 TileSet 생성 절차

1. `TileSet` 리소스 생성 → `Tile Size 48x42`, `Tile Shape Hexagon`, `Tile Layout Stacked`
2. 각 `terrain_*.png`를 타일로 추가, **Texture Origin** `(24,21)`
3. `Terrain` 레이어가 필요하면 `TileSet > Terrains`에 지형 타입 등록
4. `ui_*` 오버레이는 별도 `CanvasLayer`에 `Sprite2D`로 관리 (TileMap과 분리)

### 6.4 스프라이트 설정

```
Sprite2D > Texture Filter: Nearest (Inherit면 프로젝트 기본값 따름)
Sprite2D > Texture Repeat: Disabled
```

**해상도 대응:**
- 뷰포트 1280x720, 타일 48x42 → 가로 약 26타일, 세로 약 17타일 표시
- 카메라 줌은 정수 배수 권장 (1.0, 2.0) — 1.5 배수 시 픽셀 왜곡 가능

---

## 7. 파일 목록 (Sprint 0 #3 산출물)

```
StrategyGame/
├── assets/
│   ├── tiles/ (7종, 48x42, PNG-32)
│   │   ├── terrain_plains.png
│   │   ├── terrain_mountains.png
│   │   ├── terrain_forest.png
│   │   ├── terrain_swamp.png
│   │   ├── terrain_fortress.png
│   │   ├── terrain_village.png
│   │   └── terrain_road.png
│   ├── sprites/ (14종, 24x24, PNG-32)
│   │   ├── unit_infantry_blue.png      ● 방패+검
│   │   ├── unit_infantry_red.png
│   │   ├── unit_archer_blue.png        ● 활+화살통
│   │   ├── unit_archer_red.png
│   │   ├── unit_cavalry_blue.png       ● 말+기수+랜스
│   │   ├── unit_cavalry_red.png
│   │   ├── unit_spearman_blue.png      ● 장창 전체 높이
│   │   ├── unit_spearman_red.png
│   │   ├── unit_siege_blue.png         ● 투석기
│   │   ├── unit_siege_red.png
│   │   ├── unit_conscript_blue.png     ● 밀짚모자+갈퀴
│   │   ├── unit_conscript_red.png
│   │   ├── unit_scout_blue.png         ● 망토+후드+단검
│   │   └── unit_scout_red.png
│   └── ui/ (8종)
│       ├── ui_selection.png    (48x42)
│       ├── ui_move_range.png   (48x42)
│       ├── ui_attack_range.png (48x42)
│       ├── ui_fog.png          (48x42)
│       ├── ui_hex_grid.png     (48x42)
│       ├── ui_panel.png        (96x64)
│       ├── ui_button.png       (64x20)
│       └── ui_button_hover.png (64x20)
├── docs/
│   └── art_guide.md  ← 본 문서
└── generate_assets_v3.py  # 재생성 스크립트 (Pillow)
```

**생성 스크립트 재실행:**
```bash
python "D:\Game development\Demon slayer\StrategyGame\generate_assets_v3.py"
# 의존성: pip install Pillow
```

---

## 8. 확장 가이드

- **새 지형 추가 시:** `generate_assets_v3.py`의 `TERRAINS`에 함수 추가, 동일 `HEX_POINTS`와 `1px 아웃라인` 준수
- **새 병과 추가 시:** `SPRITES`에 함수 추가, **실루엣 우선** — 색만 다른 복제 금지, 무기/모자/탈것으로 구분
- **고해상도 대응:** 48x42 → 72x63 (1.5x)은 정수 스케일 아니므로 **96x84 (2x)** 로 업스케일 권장, Nearest 유지
- **계절 변형:** 팔레트의 Base만 교체 (예: 겨울 Plains `#E8E8E8`), 구조는 유지해 가독성 보존

---

*본 가이드는 Advance Wars/GBA FE의 “작고 단단한 픽셀” 철학을 따르며, 48px 안에서 3색으로 완결되는 것을 목표로 한다. 디테일은 “알아보는 데 필요한 최소”만 넣는다.*
