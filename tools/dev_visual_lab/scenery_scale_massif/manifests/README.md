# StrategyGame — 경관 규모 확대 및 3겹 이상 다층 산맥 (Scenery Scale & Layered Massif)

## 1. 개요 및 설계 결정 (Overview & Architectural Decisions)

본 모듈은 전략 화면(R=18)에서의 경관 가독성과 위계를 극대화하기 위해, 유닛(일반 9.6, HQ 12.0)에 비해 왜소했던 주요 경관(성, 마을, 산맥)의 규모를 대폭 확대하고 3겹 이상의 다층 산맥(Layered Massif)을 Godot 4.2.2 DEV 월드에 통합한 승인 후보입니다.

- **성/요새 4종 변주 (`castle4/`)**:
  - 기존 1종 미니어처 성을 4종의 고유 성곽(Square Grand Stone, Stepped Crag Hill Fort, Circular Motte-and-Bailey, Rectangle Twin Citadel)으로 12개 성 헥스에 분산 배치.
  - 주탑 높이 ~24.5-27.65m(HQ 대비 2.0-2.3배 이상), 외곽 반경 13.87-14.92m로 1헥스(R=18) 내 안착, 지면 접점 `y=0.0` 플러시 안착.
  - 실시간 도로망(`ScaledRoadBuilder`)이 성문 입구 좌표(`gate_local` z=10.5-11.5)에 정확히 접속.
- **마을 및 농작지 건물 7종 확대 (`buildings/`)**:
  - 대청(Communal Hall) 높이 15.0m(XZ 2.1배 확대)로 중심 건물 위계 확립.
  - 마을 문루(Walled Gate) 높이 14.0m(XZ 1.35배)로 확대 및 도로 접속.
  - 주거/공방/창고류 8.2-9.5m로 비례 유지 확대.
  - 대청 외곽 1.2m 이격 및 건물 간 상호 침범 분리 알고리즘을 적용하여 지붕 겹침(clipping) 0건 달성. 안마당 통로(alley >= 6.4m) 및 바닥판/농작지/수로 100% 보존.
- **3겹 이상 다층 산맥 전시장 (`massif25/`)**:
  - 기존 4,921헥스 본도 레이아웃과 25개 산맥은 100% 보존(기존 해시 불변).
  - 본도 동쪽 평원 전시장(Exhibition Zone, X=2350)에 25종 다층 산맥(5형태 × 5규모, LOD0/1/2, 총 75 GLB)을 5x5 그리드로 배치.
  - 각 산맥별 3개 이상의 능선 밴드(전면 지지 능선, 중앙 주능선, 후면 지지 산괴) 및 런타임 바위 MultiMesh 4종 자동 배치.
  - 최하단 기슭(Band 0 / `uv2.x <= 0.12`)만 자연 평원 지면색에 적응 블렌딩(상부 암벽 고유색 보존).

---

## 2. 실행 방법 (How to Launch)

### 1) 후보 월드 독립 실행 (BAT)
```cmd
outputs\scenery-scale-massif\Play_Scaled_Scenery_World.bat
```

### 2) 게임 타이틀 메뉴 진입 (DEV Map Collection)
1. 게임 실행 후 타이틀 화면 진입
2. **DEV · 맵 모음 (Map Collection)** 클릭
3. **확대 경관 (후보)** 버튼 클릭 (`scaled_scenery_world.gd` 실행)

### 3) 기존 승인 월드로 복귀 (Original Approved World)
- BAT 실행: `outputs\unit-import-optimization\Play_Unit_World.bat`
- 메뉴 진입: **DEV · 맵 모음** → **애셋 라이브러리 맵 — 산맥 25종 · 숲 · 마을 · 농작지 · 물길** 클릭

---

## 3. 조작법 (Navigation Controls)

| 키 / 입력 | 동작 |
|---|---|
| **M** | **본도(R40 월드) ↔ 평원 전시장(5x5 산맥) 즉각 전환** |
| **Home** | 현재 활성 구역(월드 또는 전시장) 전체 개관(Overview) 시점으로 이동 |
| **마우스 휠** | 카메라 줌 인 / 줌 아웃 |
| **마우스 우클릭 + 드래그** | 카메라 회전 (Orbit / Yaw) |
| **W, A, S, D** | 카메라 수평 이동 (Pan) |

---

## 4. 성능 비교 (Performance Comparison: Before vs After)

동일 렌더러(Vulkan Forward+, 1600x900 해상도), 동일 전도 개관 카메라(size=2400.0, yaw=0.12, orbit=1.05)에서 300프레임 측정한 결과입니다 (`renders/perf-comparison.json`).

| 측정 항목 | Before (--all-lod0) | After (--all-lod0) | Before (Auto-LOD) | After (Auto-LOD) |
|---|---|---|---|---|
| **프레임 타임 p50** | 50.06 ms | **53.84 ms** (+3.78 ms) | 18.11 ms | **20.89 ms** (+2.78 ms) |
| **프레임 타임 p95** | 64.06 ms | **58.61 ms** (-5.46 ms 개선) | 31.08 ms | **23.04 ms** (-8.05 ms 개선) |
| **평균 드로우콜** | 3,195 | **3,852** (+657) | 2,624 | **3,281** (+657) |
| **평균 프리미티브** | 23,201,256 | **25,477,913** (+9.8%) | 10,631,570 | **10,911,427** (+2.6%) |
| **VRAM 사용량** | 654.8 MB | **819.7 MB** (+165 MB) | 654.8 MB | **819.7 MB** (+165 MB) |

> Auto-LOD 실사용 환경에서 신규 25종 다층 산맥 전시장과 확대 성곽/건물이 상주함에도 불구하고 삼각형 증가는 2.6%에 불과하며, 95% 프레임 안정성은 오히려 향상되었습니다.

---

## 5. 시각적 산출물 목차 (Render Artifacts in `renders/`)

### 1) 동일 구도 Before vs After 비교 (Standard Views)
- `before-unit-castle-hq.png` vs `after-unit-castle-hq.png` (성 + HQ 지휘관 탑뷰)
- `before-unit-village.png` vs `after-unit-village.png` (마을 + 보병 부대 탑뷰)
- `before-forest-mountain-foot.png` vs `after-forest-mountain-foot.png` (숲 + 산기슭 경계)
- `before-range-diagonal.png` vs `after-range-diagonal.png` (2번 사선 산맥)
- `before-range-y-branch.png` vs `after-range-y-branch.png` (17번 Y분기 산맥)
- `before-overall.png` vs `after-overall.png` (전체 4,921헥스 월드 개관)

### 2) 입체 높이 검증 (Oblique Views, ~30-40° Pitch)
- `before-oblique-unit-castle-hq.png` vs `after-oblique-unit-castle-hq.png` (성벽/주탑과 기마 HQ)
- `before-oblique-unit-castle-hq-full.png` vs `after-oblique-unit-castle-hq-full.png` (주탑 꼭대기부터 HQ 기마 지휘관까지 비차폐 나란히 배치)
- `before-oblique-unit-village.png` vs `after-oblique-unit-village.png` (15m 대청, 14m 문루, 주거 지붕 분리)
- `after-castle-4-variants.png` (인게임 라이브 월드 성 4종 2x2 쇼케이스)

### 3) 신규 다층 산맥 전시장 (Exhibition Views)
- `after-exhibition-25-overview.png` (5x5 전시장 25종 산맥 전체 개관)
- `after-exhibition-straight-oblique.png` (직선형 3+ 밴드 다층 능선 입체 근접)
- `after-exhibition-y-branch-oblique.png` (Y분기형 3+ 밴드 삼거리 능선 입체 근접)

---

## 6. 재생성 및 검증 파이프라인 (Regeneration Commands)

1. **Three.js 애셋 재생성 (Node.js)**:
   ```cmd
   cd outputs\threejs-hex-terrain-kit\studio
   npm run build:scaled-scenery
   ```
2. **Godot 검증 및 캡처 자동 실행**:
   ```powershell
   $env:SG_FULL_MAP_OUT = "C:\Users\User\Documents\Codex\2026-10-18\strategygame-godot-4-2-2-repo\outputs\full-map-lab"
   & "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.2.2-stable_win64.exe" --path "C:\Users\User\gamedevelopment\StrategyGame" --script res://tools/dev_visual_lab/scaled_scenery_world.gd -- --all-lod0 --capture-after
   ```
