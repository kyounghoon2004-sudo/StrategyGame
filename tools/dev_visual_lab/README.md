# DEV unit asset lab

Additive visual review tools. No battlefield scene, mission mount, rules, level data, combat command, or existing asset is edited.
The project autoloads still initialize when Godot starts; this is not an autoload-free game export.

Run from the repository with Godot 4.2.2:

    Godot_v4.2.2-stable_win64.exe --path . --script res://tools/dev_visual_lab/unit_lab.gd

Left/Right or dropdown: choose 9 existing unit configurations. Space: original attack path.
F: near/far camera. M: marching for CIV3D units. H: hit for CIV3D units. Esc: close the lab.
The default selection is CIV3D infantry. No tutorial is opened or modified.

For evidence, set SG_DEV_LAB_OUT to a dedicated absolute output directory and add `-- --capture`.
Capture produces 27 PNGs and a runtime JSON receipt. It invokes each existing attack API,
checks bone-pose changes, and records whether the formation root stayed at its anchor.
The near/far toggle changes only the camera: it intentionally does not reproduce the battlefield's animation LOD.
The neutral floor is a comparison stage, not the game's terrain or an art redesign.

Static inventory:

    python tools/dev_visual_lab/inventory.py --out <output-directory>

Godot import inspection:

    Godot_v4.2.2-stable_win64_console.exe --headless --path . --script res://tools/dev_visual_lab/inspect_imports.gd

Only the existing Godot-imported resources are instantiated; original FBX files are inventoried, not reimported or retargeted.
GLB triangle counts refer to unique source mesh definitions, not a rendered frame, shadows, LOD selection, or all instances.
Runtime primitive counters include the stage, shadow passes and other rendering work and are not equivalent to source triangle counts.
Short frame samples are uncontrolled observations, not a claim about battlefield FPS or a hardware bottleneck.
Current residual warnings: imported horse/dog owner inconsistency; project JEV autoload worker boot failure.


## Environment audit lab

`environment_inventory.py --out <absolute directory>` inventories existing environment files and writes `catalogue.json` plus a hash baseline if one does not exist. It excludes unit, audio, UI directories; environment review sheets are retained as references. It does not modify source assets.

Set SG_ENV_LAB_OUT to that output directory, then run:

    Godot_v4.2.2-stable_win64.exe --path . --script res://tools/dev_visual_lab/environment_lab.gd

Left/Right or dropdown selects every existing model, mesh fragment and 2D/reference image, plus 31 builder compositions. F toggles the camera. Esc closes the lab.
Add `-- --capture` to capture all entries. The viewport is 640x480, shadows are off, vertex-color preparation matches the existing library. 3D bounds are normalized for comparison; original AABBs are recorded. 2D images are displayed via an alpha-content AtlasTexture region; source pixels are not edited. All output goes only to SG_ENV_LAB_OUT.

`-- --capture-raster` refreshes only image previews and writes a separate raster receipt; it does not replace the full receipt. `-- --smoke` tests startup/shutdown without a full capture. These are diagnostic switches.
This stage does not load a battlefield, activate mission logic, run map generators, clear scenery caches, retarget animation, generate or normalize assets, or publish packages.
Project autoloads still initialize. A residual ObjectDB shutdown warning was observed; no runtime asset load failures occurred in the full inventory.
