# StrategyGame: master 에이전트용 시각 작업 인수인계

이 문서부터 읽고 현재 저장소 상태와 실제 파일을 확인한 뒤 작업하라. 첨부 대화의 완료 주장보다 Git 커밋·실제 매니페스트·실제 렌더 결과를 우선한다.

## 임무

GitHub `design`에 올라간 DEV 시각 작업을 `master`의 작업과 충돌 없이 가져오고, 기존 기준 월드와 확대 경관 후보를 모두 실행 가능하게 정리하라. 대상은 4종 성곽, 7종 확대 건물, 25종 3겹 이상 산괴, 기존 자연 지면·강·도로·유닛이다. 최신 후보를 실제 게임에서 보고 인수하라. 기존 기준 월드를 삭제하거나 후보를 승인된 기본 전장으로 간주하지 마라.

현재 사용자는 GitHub 업로드와 이 콜드프롬프트 준비를 요청했다. 이 문서는 다음 작업을 위한 인계다. 산괴를 실제 전장에 강제로 배치하거나 튜토리얼·밸런스를 바꿀 권한으로 해석하지 마라.

## 저장소와 확정된 원격 상태

- GitHub: https://github.com/kyounghoon2004-sudo/StrategyGame
- 시각 제작 코드: `design`의 **`a845e8b4481ff36b60088158c6ddcc7df8d758d9`**.
- 제목: `Scenery scale candidate world: scaled original castles (4 variants), single-storey buildings, 25 3+-band massifs`.
- 2026-10-27 인계 시 `git ls-remote`로 위 커밋이 `refs/heads/design`에 존재함을 확인했다. 인계 문서가 추가된 이후에는 `origin/design`의 최신 커밋도 확인한다.
- 그때 원격 master: `238c7d12f106c68c72a1175bfe0663e9557d7e92`. 현재 HEAD를 고정하거나 이 커밋으로 되돌리라는 뜻이 아니다.
- 원본 로컬 게임: `C:\Users\User\gamedevelopment\StrategyGame`.
- 제작 작업 폴더: `C:\Users\User\Documents\Codex\2026-10-18\strategygame-godot-4-2-2-repo`.
- Godot: **4.2.2-stable Forward+**. 최신 Godot 문서/API를 그대로 적용하지 마라.

먼저 `git status`, 현재 브랜치, 원격, 대상 master 작업 트리를 읽는다. 사용 중인 체크아웃을 reset/clean/강제 checkout하지 않는다. 기존 master용 작업 트리가 있으면 사용하고, 별도 체크아웃이 필요하면 관리되는 worktree를 사용한다. 타인의 미커밋 변경을 덮어쓰지 않는다.

## 무엇이 GitHub에 있고 무엇이 없는가

`a845e8b`는 코드·설정 커밋이다. Godot DEV 기반을 포함해 **56개 파일**을 추가/수정했다. 대표 파일:

- `tools/dev_visual_lab/scaled_scenery_world.gd`
- `tools/dev_visual_lab/scaled_scenery_capture.gd`
- `tools/dev_visual_lab/unit_world.gd`, `unit_lod_manager.gd`, `unit_lod_formation.gd`
- `tools/dev_visual_lab/scenery_roads.gd`, 자연 지면/강/마을/산맥 기반 스크립트들
- `scripts/ui/dev_asset_library_entry.gd`, `dev_map_collection_panel.gd`
- `Play_StrategyGame.bat`
- `tools/dev_visual_lab/scenery_scale_massif/`의 생성기 코드 스냅샷과 최종 매니페스트

**GLB·텍스처·렌더·로컬 데이터는 Git에 포함되지 않는다.** 저장소는 `assets/`, `artifacts/`, `evidence/` 등을 무시하는 코드 전용 정책이다. 새 clone만으로 현재 월드가 실행된다고 보고하지 마라.

동일 PC의 파생 산출물:
`C:\Users\User\Documents\Codex\2026-10-18\strategygame-godot-4-2-2-repo\outputs\scenery-scale-massif`

- `castle4/exports/`: 성 4종×3 LOD = **12 GLB**.
- `buildings/exports/`: 건물 7종×3 LOD = **21개 정식 GLB**. 폴더에는 별도 `test_small_house.glb`도 있으므로 전체 22개를 정식 애셋으로 오인하지 않는다. 인벤토리는 정식 `building_*_lod*.glb`만 기록한다.
- `massif25/exports/`: 산괴 25종×3 LOD = **75 GLB**.
- `massif25/rocks/`: **25 JSON**의 바위 배치.
- `renders/`: Before/After, 성곽·마을·산괴 및 성 4종 비교 이미지.
- `castle4/manifest.json`, `buildings/manifest.json`, `massif25/catalog.json`, 루트 설정·성능 자료.

인계 폴더의 `LOCAL_ASSET_INVENTORY.json`에 실제 108 GLB와 25 바위 JSON의 경로·크기·SHA-256을 기록했다. 이 목록은 업로드 영수증이 아니라 **로컬 파일 인벤토리**다. 파일이 필요한 PC에 실제로 존재하는지 확인하라. 원본 게임 `assets/`와 기존 full-map/산맥/건물/유닛 파생물도 별도로 필요하다.

다른 PC라면 기존 애셋 전달 경로나 재생성에 필요한 원본을 먼저 확보하라. `StrategyGame_assets_2026-10-17.zip`을 Git에 올리거나 `.gitignore`를 우회하지 마라. 이 작업에서 GitHub Release/LFS/외부 파일 공유를 새로 만들지는 않았다.

## 현재 구현과 완료 범위

1. **성곽 4종**: 원본 `06-major-stronghold` + 닫힌 육각 외곽 `02-stone-earth-defensive-wall` + 정면 `03-layered-gatehouse`. 성 안에 마을 집/초가집/목조 망루를 추가한 이전 구성을 쓰지 않는다. 본성 약 22.6~24.8, 성문 12.5~13.9, 벽 9.4~10.7이며 최종 수치는 해당 매니페스트를 따른다. 단일 헥스 안의 바닥 접점과 문 방향을 보존한다. 오래된 REGENERATE/README의 다른 수치는 역사적 설명일 수 있다.
2. **건물 7종**: 기존 단층 실루엣을 확대했다. 마을 회관 15.0, 문 14.0, 일반 집/창고/작업장 8.2~9.5, 농장 창고 6.8. 농작물·논둑·수로·바닥 전체를 확대하지 않는다.
3. **다층 산괴 25종**: 직선/C/S/Y/불규칙 5형태×5규모. 3헥스 폭으로 확장된 footprint와 앞 보조/중앙 주능선/뒤 산괴 3개 이상 대역, 높이 약 45~60. **현재는 원본 R40 동쪽 `x=2350`의 별도 5×5 전시 구역에 배치되어 있다.** `M`으로 이동한다. 기존 본맵의 모든 산맥이 이미 이것으로 교체되었다고 말하지 마라.
4. **기준 월드 유지**: `unit_world.gd`는 기존 애셋 라이브러리다. 메뉴의 `확대 경관 (후보)`는 `scaled_scenery_world.gd`를 별도로 연다.
5. **유닛**: 일반 높이 파라미터 9.6, HQ 12.0, 7병종/56부대/392슬롯, 시드 고정 흩어진 배치. 숫자 12.0을 말·기수·무기까지 포함한 실제 전체 AABB 높이라고 해석하지 않는다. 근경 원본 형상/중경 경량+15Hz/원경 정적 부대 메시, 화면 밖 처리 최적화를 유지한다.
6. **가시성 수정**: 부대 전체 3D 경계를 투영한다. 진입 100px, 퇴장 180px, 퇴장 지연 350ms. 중심점 하나가 화면 밖에 나갔다고 부대를 숨기는 옛 코드로 되돌리지 않는다.

## master로 가져오는 방법

현재 master 작업을 보존한 대상 체크아웃에서 진행한다:

```text
git fetch origin design master
git show --stat a845e8b4481ff36b60088158c6ddcc7df8d758d9
git cherry-pick a845e8b4481ff36b60088158c6ddcc7df8d758d9
```

이미 해당 커밋을 포함한 경우 중복 cherry-pick하지 않는다. 자동 충돌 해결이나 강제 덮어쓰기는 하지 마라. `dev_map_collection_panel.gd` 충돌 시 기존 메뉴들과 `OpenAssetLibraryMap`, `OpenScaledSceneryMap`을 함께 보존한다. 기준 맵의 `MAP_SCRIPT`와 후보 `SCALED_MAP_SCRIPT`를 구분하라.

**`origin/design` 전체를 무조건 merge하지 마라.** 그 이전 기록에는 다른 담당자의 보드·튜토리얼·미션 작업이 있다. `a845e8b`의 diff를 시각 작업 단위로 검토한다. master에 빠진 의존성이 있으면 필요한 시각 의존성만 파악해 가져오고, 미션/판정/레벨 파일을 편의상 덮어쓰지 않는다. 불필요하게 master의 HEAD를 오래된 design 기준으로 바꾸지 않는다.

이 문서 및 로컬 인벤토리는 그 이후 design에 추가된 인계 문서 커밋에 있다. 구현 커밋과 혼동하지 마라. 문서를 master에 보관할 때는 해당 문서 파일만 함께 가져오면 된다.

## Three.js 재생성과 경로 함정

실제로 설치·사용된 제작 스튜디오:
`C:\Users\User\Documents\Codex\2026-10-18\strategygame-godot-4-2-2-repo\outputs\threejs-hex-terrain-kit\studio`

이곳의 package/lock에 Three.js `0.186.1`, Vite `8.3.4`가 고정되어 있다. 기존 설치를 사용한다. 임의 업그레이드/유료 서비스/모델 재생성을 하지 않는다.

실제 스튜디오 루트에서:

```text
node scripts/build-scaled-scenery.mjs
node scripts/build-massif25.mjs
```

**중요:** Git의 `tools/dev_visual_lab/scenery_scale_massif/`는 생성기 스냅샷이며, 그대로 `node scripts/...`를 실행할 수 있는 독립 npm 프로젝트가 아니다. 스냅샷의 스크립트는 `../src/scenery-scale/`, `../src/mountain-massif/` 구조를 기대하고, 산괴 생성기는 `src/generator.js` 및 `src/mountain-assets/source-profiles.js`도 참조한다. 실제 스튜디오에는 이 파일들과 원본 참조/이전 키트가 있다. 로컬에서는 그 검증된 스튜디오를 사용하라. 다른 PC에서는 먼저 디렉터리 구조·의존성·원본 입력·하드코딩된 출력 경로를 복원/설정하고 나서 실행해야 한다. 코드 복사만으로 재생성이 검증되었다고 주장하지 마라.

캐슬/건물은 실제 게임 R=18 규격의 출력이며, 산괴 authoring R=24는 월드에서 0.75를 적용한다. 일괄 0.75를 중복 적용하지 마라. 개별 매니페스트와 어댑터 변환을 직접 확인한다.

## 실제 실행

동일 PC에서 현재 저장소를 쓰는 예시:

```powershell
$env:SG_FULL_MAP_OUT = 'C:\Users\User\Documents\Codex\2026-10-18\strategygame-godot-4-2-2-repo\outputs\full-map-lab'
& "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.2.2-stable_win64.exe" --path 'C:\Users\User\gamedevelopment\StrategyGame' --script res://tools/dev_visual_lab/scaled_scenery_world.gd -- --all-lod0
```

다른 master worktree에서는 `--path`를 그 체크아웃의 절대 경로로 바꾼다. `SG_FULL_MAP_OUT`은 기존 로컬 데이터 위치이며 worktree 내부의 res 경로가 아니다.

조작: 휠 줌, WASD 이동, 우클릭 회전, Home 전체 보기, `M` 산괴 전시 구역. 사용자가 조작할 수 있는 창을 열고, 스크린샷 전용 실행을 최종 결과로 대신하지 않는다.

검증은 필요한 만큼만 한다: 파생물 경로/해시 확인, Godot 4.2.2 로드, 성·HQ·마을 비교, 문과 도로 접속, `M` 전시의 25종/LOD 전환. 변경·오류 없이 긴 캡처/성능 반복을 하지 않는다. 기존 성능 JSON은 특정 디버그 환경의 자료이며 릴리스 또는 전투 FPS 보장이 아니다.

## 다음 통합 시 주의

- 기본 라이브러리 승격 또는 실제 전장 적용은 이후 명시된 범위에 맞춰 수행한다. 현재 후보와 기존 기준을 모두 보존하는 것이 기본이다.
- 3헥스 폭 산괴를 본맵에 넣으려면 footprint가 들어갈 위치와 소유권을 확인해야 한다. 기존 평원·강·마을을 묵시적으로 산으로 바꾸지 않는다. 전시 성공과 본맵 교체 완료는 다르다.
- 산기슭 지면색·법선·공유 경계, LOD 실루엣, 바위 MultiMesh 착지 높이를 유지한다. 원본 AI GLB 3중 복제로 비용을 세 배 늘리지 않는다.
- `scaled_scenery_world.gd`의 문 좌표·도로 재연결·마당 부품 분리 로직을 이해한 뒤 통합한다. 큰 루트 전체를 확대하여 바닥판까지 키우지 않는다.
- master 인수 후 완료 보고에는 실제 커밋, 실행한 경로, 로컬 애셋 의존성, 아직 안 한 부분을 정확히 구분한다.

## 금지 범위

튜토리얼 M1~M5는 수정/테스트 실행 금지, 특히 M1/M5 보존. 다른 담당자의 레벨·밸런스 작업을 건드리지 마라. 다음은 읽기 참조 외 수정 금지:

- `scripts/gx_missions/mission_rules.gd`
- `scripts/gx_missions/mission_play_mount.gd`
- `scripts/gx_missions/mission_config.gd`
- `gx_missions_config.json`
- `tools/synth_adv_v1/**`, `tools/cmd_rl/**`, `scripts/cloud_pipeline/**`

다른 사람이 시작한 Godot를 종료하지 않는다. `assets/`, `.godot/`, node_modules, 원본 ZIP, `muse_order_1.md`, 인증 정보나 모델 가중치를 커밋하지 않는다. 인계받았다는 이유만으로 master를 원격에 직접 푸시하거나 강제 푸시하지 않는다. 요청된 통합 결과는 검토 가능한 커밋/차이로 남기고, 이후 원격 반영은 해당 세션의 사용자 권한을 따른다.
