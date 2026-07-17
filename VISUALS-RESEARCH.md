# Highlight Interactables — visuals research (generated 2026-07-17)

Four-agent research run: tracking diagnosis (local code), OMWFX feasibility (official docs), alternative techniques, synthesis.

---

Diagnosis complete. Full report follows.

---

# Marker tracking lag — diagnosis report
**Mod:** `P:/Morrowind Modding CoWork/highlight-interactables/scripts/TwentyTwentyObjects/`
**Symptom:** glows/labels trail and stutter relative to objects during camera or object movement.

## 1. Where screen positions are computed, and how often

The only projection entry point is `projection.worldToScreen()` — **`projection.lua:70`** is the sole `camera.worldToViewportVector` call in the mod. It is reached from:

| Caller | Path | File:line |
|---|---|---|
| Rescan gather phase | per candidate | `player_native.lua:232` |
| Glow geometry (8 bbox corners projected per object) | `projection.getOutlineBox` | `projection.lua:247` (fallback: `278-280`) |
| Glow per-tick update | `updateLabels` isOutline branch | `player_native.lua:610` |
| Anchored text per-tick update | `updateLabels` isAnchored branch | `player_native.lua:578` |
| Jitter-text per-tick update | `updateLabels` else branch | `player_native.lua:644-645` |

**Cadence: positions are NOT updated every frame.** Everything runs from `onUpdate` (`player_native.lua:814-846`, registered at `:868`), and `updateLabels` is gated behind an accumulator:

- `CONFIG.UPDATE_INTERVAL = 0.033` — `player_native.lua:28` (comment: "30fps label updates")
- Gate: `player_native.lua:827-831` — `updateLabels` runs only when the accumulator reaches 33 ms, then resets to 0.

At 60 fps this fires every **2nd** frame; at 120 fps every **4th** frame. Between ticks, every widget's screen position is frozen while the camera keeps moving.

## 2. Caching / throttling inventory

- **Position updates:** throttled to ~30 Hz (`player_native.lua:28, 827-831`). No interpolation between ticks.
- **Full rescan:** `CONFIG.SCAN_INTERVAL = 0.25` (`player_native.lua:29`); every 0.25 s `scanAndCreateLabels` runs (`player_native.lua:838-845`), which first calls `clearAllLabels()` (`:211`) — **all widgets destroyed and re-`ui.create`d 4×/sec**, plus per-object occlusion raycasts and 8-corner projections in the same frame.
- **Occlusion:** cached per "frame", but `occlusion.newFrame()` is only called on rescan (`player_native.lua:841`, `occlusion.lua:18-21, 83-99`) — occlusion state is effectively 4 Hz.
- **Screen size:** cached in `projection.lua:11`, refreshed on scan (`player_native.lua:189`); no `onViewportResized` handler.
- Hidden per-call cost: `worldToScreen` does a `storage.get('general')` **on every single call** (`projection.lua:73-74`) — a C-boundary engine-storage read per projected point (≈240/tick for 30 glows).

## 3. Glow vs. text cadence

**Same cadence — both ~30 Hz.** Glows (`player_native.lua:606-641`), anchored text (`:575-604`), and jitter text (`:642-688`) all update inside the same throttled `updateLabels` call. There is no mismatch between glow and text; they lag together.

## 4. `element:update()` usage

Per-widget, not batched (the API has no batch primitive except the very slow `ui.updateAll()`):

- Glow: one `el:update()` per glow per tick — `labelRenderer_native.lua:226`.
- Anchored text: one per tick — `player_native.lua:604`.
- Jitter mode only: text labels get `:update()` **twice** per tick (`:683` and `:702`), and connecting lines are **destroyed and re-created via `ui.create` every tick** instead of repositioned (`player_native.lua:707-723`).

~60 `element:update()` calls per tick for 30 glow+text markers is cheap; the churn problems are the jitter-mode lines and the 4 Hz full recreate.

## 5. UI Scale Correction's role

`worldToViewportVector` and `ui.screenSize()` return raw window pixels; the engine's `[GUI] scaling factor` is unreadable from Lua, so the mod exposes a manual `guiScale` setting. Every projected position is divided by it at **`projection.lua:122-124`** (set from storage at `player_native.lua:200, 859`). If the user's setting doesn't match their actual engine GUI scale, **every marker is offset by a multiplicative factor from the screen origin (top-left)** — error grows toward the bottom-right and shifts as the camera pans, which players describe exactly as "doesn't track the item." Note also a self-inconsistency: `isOnScreen` (`projection.lua:181-187`) compares scaled positions against the **unscaled** screen size.

## Ranked causes of the visible lag

1. **30 Hz position throttle** (`player_native.lua:28, 827-831`). Dominant. Markers are 1–3 rendered frames stale; a moderate mouse pan moves the scene tens of pixels per frame, so glows visibly trail and judder.
2. **Running in `onUpdate` (simulation phase) instead of `onFrame`** (`player_native.lua:868`). `onFrame` is documented as "every real frame, right after input processing… for latency-critical UI." Camera state read in `onUpdate` can be one frame behind the pose actually rendered, adding a constant ≥1-frame trail even if the throttle were removed.
3. **Destroy-everything rescan every 0.25 s** (`player_native.lua:838-845` → `:211`). A 4 Hz frame-time spike (occlusion raycasts + 240 corner projections + ~60 `ui.create`) that reads as periodic hitching/popping layered on top of the lag.
4. **guiScale miscalibration** (`projection.lua:122-124`) — conditional; produces position-dependent constant offset rather than lag, but presents as "not tracking."
5. Minor: per-call storage reads inside `worldToScreen` (`projection.lua:73-74`); occlusion at 4 Hz; jitter-mode double-update + line recreation (text-only mode).

## Minimal fix

**Reproject visible markers every rendered frame in `onFrame`; keep the slow rescan in `onUpdate`.**

In `player_native.lua`:
1. Add `onFrame = function(dt) if currentProfile then outlinePulseTime = outlinePulseTime + dt; updateLabels(dt) end end` to `engineHandlers` (`:866-870`), and delete the `updateAccumulator` gate (`:827-831`) and the pulse increment from `onUpdate` (`:824`). Rescan logic (`:838-845`) stays in `onUpdate` at 0.25 s unchanged.
2. Hoist the debug-settings read out of `worldToScreen` (`projection.lua:73-74`) into a module-local refreshed on scan — this is mandatory before going per-frame, it removes ~14k engine-storage reads/sec at 60 fps.
3. Optional cheap win: in the per-frame path, project only `bbox.center` (1 projection) for the glow center and reuse the scan-time size/diameter (`computeGlowDiameter` already prefers the distance-independent world diagonal, `labelRenderer_native.lua:156-168`), refreshing the full 8-corner box only on scan ticks. Cuts projections from 8/marker to 1/marker with a couple px of error.

**Per-frame cost for ~30 markers (glow + anchored text):** as-is geometry (8 corners/marker) = ~240 `worldToViewportVector` calls + ~60 `element:update()` ≈ **0.7–1.5 ms/frame** — acceptable at 60 fps but noticeable at 120. With optimization (3): ~30–60 projections + 60 updates ≈ **0.3–0.6 ms/frame**. The rescan spike is untouched by this fix; if hitching remains objectionable, the follow-up (not minimal) is to diff the candidate set against `activeLabels` keyed by object and reuse widgets instead of `clearAllLabels()`.

Follow-up candidate beyond scope: cause 3 (widget churn) and the jitter-mode line recreation would benefit from element reuse, but the onFrame change alone should resolve the reported "doesn't track" complaint unless the user's UI Scale Correction is miscalibrated (cause 4 — ask them to verify the setting matches their engine GUI scaling factor).

---

# OpenMW 0.51 Postprocessing Research — Official Docs (openmw.readthedocs.io)

Sources used (latest channel, which tracks the current dev/0.5x API; stable channel was cross-checked and matches on every point below):
- OMWFX reference: https://openmw.readthedocs.io/en/latest/reference/postprocessing/omwfx.html
- Lua package: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_postprocessing.html
- API package table: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/api.html
- Camera package (for Q4 support): https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_camera.html
- Core (GameObject): https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_core.html

The omwfx page defines `OMW_API_VERSION` = 5, "The revision of OpenMW postprocessing API" (macro added in 0.49; undefined in 0.48).

## (1) Depth and normals access — YES, both

Builtin samplers table (omwfx.html, "Builtin Samplers"), verbatim:

| Type | Name | Description |
|---|---|---|
| sampler2D[Array] | `omw_SamplerLastShader` | "Color output of the last shader" |
| sampler2D[Array] | `omw_SamplerLastPass` | "Color output of the last pass" |
| sampler2D[Array] | `omw_SamplerDepth` | "Non-linear normalized depth" |
| sampler2D[Array] | `omw_SamplerNormals` | "Normalized world-space normals [0, 1]" |

Helper functions (verbatim):
- `omw_GetDepth`: "Returns the depth value from a sampler given a uv coordinate. Reverses sampled value when OMW_REVERSE_Z is set."
- `omw_GetLinearDepth`: "Returns the depth in game units for given uv coordinate."
- `omw_GetNormals`: "Returns normalized view-space normals [-1, 1]"

Normals gating: technique property `pass_normals` (boolean) — "Pass normals from the forward passes. If unsupported, OMW_NORMALS will be set to 0". Macro `OMW_NORMALS`: "Whether normals are available as a sampler in the technique". So a shader must set `pass_normals = true;` and guard on `OMW_NORMALS` — availability is not guaranteed, and the docs do not enumerate when it is "unsupported" (no documented list of which geometry writes normals).

## (2) Per-object mask / stencil / ID buffer — ABSENT

No mention anywhere in omwfx.html or the Lua package docs of stencil buffers, object masks, ID buffers, object selection, or per-object shader application. The only samplers exposed are the four above plus user-declared texture samplers (`sampler_2d` etc. from files) and custom render targets (`rt1`/`rt2`/`rt3`, written by the shader's own passes — they contain only what your own passes render, which is fullscreen quads). OMWFX shaders are fullscreen post-process only. **A shader cannot know which pixels belong to a specific object.** This is undocumented/absent — Diablo-style exact per-object silhouette outlines via an ID buffer are not expressible in OMWFX as documented.

## (3) Runtime uniforms settable from player scripts

Package context (api.html table): `postprocessing` — Context: "player" — "Controls post-process shaders." Player scripts only.

Full setter list on the Shader handle (openmw_postprocessing.html, descriptions verbatim, all "Set a non static <T> shader variable."):
- Scalars/vectors: `setBool`, `setFloat`, `setInt`, `setVector2`, `setVector3`, `setVector4`
- Arrays: `setFloatArray`, `setIntArray`, `setVector2Array`, `setVector3Array`, `setVector4Array` — e.g. `Shader:setVector4Array(name, array)` where array "Contains equal number of openmw.util#Vector4 elements as the uniform array."

Also: `postprocessing.load(name)` ("Load a shader and return its handle."), `postprocessing.getChain()` ("Returns the ordered list of active shaders."), `Shader:enable(position)`, `Shader:disable()`, `Shader:isEnabled()`.

Shader-side requirements (omwfx.html, verbatim):
- "If you would like a uniform to be adjustable with Lua API you must set `static = false;`."
- "You can use uniform arrays as well, but they are restricted to the Lua API scripts. These uniform blocks must be defined with the new `size` parameter." Example: `uniform_vec3 uArray { size = 10; }`
- **No maximum array size is documented** (array count is fixed at shader-declaration time via `size`; the Lua table must match that count).
- Technique property `dynamic`: "Whether shader is exposed to Lua. When `dynamic` is set to `true`, the shaders order cannot be manually moved, enabled, or disabled. The shaders state can only be controlled via a Lua script." Related flag `hidden`: "Shader does not show in the HUD. Useful for shaders driven by Lua API."

## (4) Screen-space bbox rects + depth-edge outlines — YES, technically expressible

Every ingredient is documented:
- Lua side: `GameObject:getBoundingBox()` — "The axis aligned bounding box in world coordinates." (openmw_core.html); `camera.worldToViewportVector(worldPos)` — "Get a vector from the world to the viewport for the given point in the world space. (0, 0) is the top left corner of the screen. The z component of the return value holds the distance from the camera to the position, in world space" (openmw_camera.html). Project the 8 bbox corners per frame, min/max to a rect, pack rects as Vector4s (plus expected depth in a parallel float array), push via `Shader:setVector4Array` / `setFloatArray` each frame from a player script.
- Shader side (omwfx.html): declare `uniform_vec4 uRects { size = N; }` with `static = false;` in a `dynamic = true;` technique; sample `omw_SamplerDepth` / `omw_GetLinearDepth` at neighbor texels using the builtin `omw` struct's `resolution`/`rcpResolution` members and `omw_TexCoord`; run a depth-discontinuity (and optionally `omw_SamplerNormals`) edge kernel only for fragments inside one of the N rects, tinting via `omw_GetLastShader()`. Branching/looping over a uniform array in the fragment pass is plain GLSL (`glsl_version` is settable per technique) — nothing in the omwfx doc restricts this.

Caveats (from the docs' own wording): depth is scene-global, so edges from *other* geometry inside the rect will also outline (no way to confirm a pixel belongs to the target object — see Q2); linear depth from `omw_GetLinearDepth` can be compared against the Lua-supplied camera distance (the `worldToViewportVector` z component) to reject occluded/foreground pixels approximately, but that is a heuristic, not an ID test. Normals-assisted edges require `pass_normals = true;` and an `#if OMW_NORMALS` fallback per the quoted docs. One `*.omwfx` file per shader; "#include directives are currently unsupported."

**Bottom line:** depth+normals edge detection restricted to Lua-fed screen rects is fully expressible in documented OMWFX (samplers `omw_SamplerDepth`/`omw_SamplerNormals`, dynamic uniform arrays via `size` + `setVector4Array`); a true per-object mask/ID buffer does not exist in the documented API, so outlines will be rect-scoped approximations, not exact object silhouettes.

---

# OpenMW 0.51 object-highlight techniques — research report

Verified against official docs (openmw.readthedocs.io `en/latest`) and the official 0.51.0 release notes. Caveat: `en/latest` docs track the dev branch, so 0.51-specific availability was cross-checked against the 0.51.0 release notes where possible.

## 1) Light attachment — FEASIBLE, second-best option

**API (official):**
- `world.createObject(recordId, count)` (global context) — "Create a new instance of the given record. After creation the object is in the disabled state." Place with `object:teleport(cell, pos)`; global scripts can set `object.enabled = true` ("Items in containers or inventories can't be disabled"). Cleanup via `object:remove()`. Docs: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_world.html and GameObject in https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_core.html
- `world.createRecord(record)` — supported runtime record types per docs: **Activator, Armor, Book, Clothing, Container, Creature, Door, Enchantment, Ingredient, Light, Miscellaneous, NPC, Potion, Probe, Spell, Static, Weapon** ("Eventually meant to support all records, but the current set of supported types is limited"). Magic effect records are load-context (`LOAD:`) only. 0.51 release notes: container/creature/door/probe/static became runtime-creatable in 0.51; "Records injected via the load context are not serialised into saves" (runtime-created ones are). https://github.com/OpenMW/openmw/releases/tag/openmw-0.51.0
- `types.Light.createRecordDraft(light)` exists ("Creates a LightRecord without adding it to the world database"); LightRecord fields include `model, icon, color, radius, duration, weight, value` and flags `isCarriable, isDynamic, isFire, isFlicker(-Slow), isNegative, isOffByDefault, isPulse(-Slow)`. https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_types.html

So yes: a global script can create one custom invisible light record (or reuse a vanilla meshless ambient-light record — these exist and are invisible in game), spawn instances, teleport them onto items, and remove them later.

**Costs/risks:**
- **Record pollution is permanent**: there is no `world.removeRecord` anywhere in the world package function list — a runtime-created record lives in the save forever. Mitigation: create exactly one reusable light record (idempotently), never per-item.
- **Instance pollution**: spawned lights are real persistent objects; you must `remove()` them on cell change/save/uninstall or they orphan in saves. (This matches your project's "type-guard persisted data" discipline — saves outlive schemas.)
- **Known createRecord bugs (official tracker)**: records created during `onLoad` get incorrect queued generated IDs (https://gitlab.com/OpenMW/openmw/-/issues/7540); createRecord-derived potions lose `onConsume` after save/load (https://gitlab.com/OpenMW/openmw/-/issues/7448). Create records lazily during play, not in `onLoad`.
- **Per-object light limits**: "max lights" is 2–64, default 16, "Maximum lights affecting each object" (unless clustered lighting, a newer dev-branch feature, is enabled) — many simultaneous highlight lights will fight torches/ambient lights. https://openmw.readthedocs.io/en/latest/reference/modding/settings/shaders.html
- Effect is *illumination*, not an outline — nearby floor/walls also brighten. Meshless light objects also appear in `nearby.*` scans (phantom entries for any scanning code, including your own).

## 2) VFX / particle at position — FEASIBLE, best fit for "make items glow"

- **`world.vfx.spawn(model, position, options)`** (global context): "Spawn a VFX at the given location in the world." Options: `loop`, `vfxId`, `scale`, `mwMagicVfx`, `particleTextureOverride`, `useAmbientLight`. **`world.vfx.remove(vfxId)`** removes all VFX with that id (empty string = all non-scripted). https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_world.html
- 0.51 availability confirmed by release notes: "Spawned visual effects that are not attached to an object can be referred to by name, looped, and removed" (the loop/remove keys were added for 0.51 via https://gitlab.com/OpenMW/openmw/-/work_items/8644). https://github.com/OpenMW/openmw/releases/tag/openmw-0.51.0
- Critically, 0.51 fixed: **"Visual effects no longer make objects that use their model non-interactable"** — i.e., you can spawn a VFX *using the item's own model path* (from its record's `.model`) at the item's position (slightly scaled up, `useAmbientLight`, tinted `particleTextureOverride`) as a Diablo-ish glow shell, and the item underneath stays activatable. Pre-0.51 this pattern blocked interaction.
- `animation.addVfx(actor, model, options)` also exists (options: `loop`, `boneName`, `vfxId`, `particleTextureOverride`, `useAmbientLight`, `autoTransform`, `transform`) but is **local-context, self-only**, and documented as "Plays a VFX on the actor" — attaching to a ground item would require `addScript`-ing a CUSTOM-flagged local script onto the item, and non-actor support is undocumented (treat as unverified). https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_animation.html (bindings originated in https://gitlab.com/OpenMW/openmw/-/merge_requests/3257)
- Costs: VFX don't track a moving object (respawn/reposition per update for physics-settled items); persistence of spawned VFX across save/load is undocumented — assume gone on load and respawn in `onLoad`. No save pollution, no record pollution — much cleaner than lights. Model can be a vanilla magic-effect static (`MagicEffect.hitStatic`/`castStatic` ids via `core.magic`) or a shipped custom glow-shell NIF.

## 3) Mesh-based / model swap — NOT VIABLE at runtime

- Records are immutable once in the world database; there is **no API to change an existing record's `model`** (confirmed absent from types/world docs). The only "swap" is: `createRecordDraft` a clone with a different `model` → `world.createRecord` → spawn new instance → remove original. That changes the instance's `recordId` (breaks stacking, quest/ownership checks, other mods' id matching) and permanently pollutes the save with one record per item type — unacceptable for a transient highlight.
- Glow in the Dahrk style is engine-native but not scriptable: OpenMW supports `NiSwitchNode`s named **`NightDaySwitch`** switched by time-of-day/interior state only ("street illumination, glowing windows, etc.") — no Lua binding to flip arbitrary switch nodes per object. https://openmw.readthedocs.io/en/latest/reference/modding/extended.html
- Also ruled out: `openmw.postprocessing` is player-context, full-screen fragment shaders only, with no per-object ID/stencil mask — a true Diablo outline around one object is not expressible there. https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_postprocessing.html, https://openmw.readthedocs.io/en/latest/reference/postprocessing/lua.html

## 4) Prior art (community sources)

- **QuickLoot (OpenMW 0.49)** — https://www.nexusmods.com/morrowind/mods/54950 (Nexus blocks automated fetch; per search summaries it shows a FO4-style *UI window* for the crosshair target — no world-space outline/glow). Community source, unverified in detail.
- **MWSE-QuickLoot** — https://github.com/MortimerMcMire/MWSE-QuickLoot — FO4-style loot window; explicitly MWSE-only, not OpenMW. Community.
- **OpenMW Impact Effects** — https://modding-openmw.com/mods/openmw-impact-effects/ — working prior art for Lua-spawned VFX at world positions (hit impacts). Community.
- **Glow in the Dahrk** — https://modding-openmw.com/mods/glow-in-the-dahrk/ — the mesh/switch-node glow approach; on OpenMW it runs via the engine-native NightDaySwitch support (the NullCascade Lua half is MWSE-only). Community + official extended-features doc above.
- **Fresh Loot** — https://gitlab.com/modding-openmw/fresh-loot — loot-info UI window, 0.49+. Community.
- Survey of the modding-openmw OpenMW-Lua tag (https://modding-openmw.com/mods/tag/openmw-lua/) found **no existing world-space outline/highlight mod** — existing loot-QoL mods all use UI windows/labels (screen-space, `camera.worldToViewportVector`-style), i.e., the approach your mod already uses.

## Bottom line

Ranked for "Diablo-style glow" in 0.51: **(1) `world.vfx.spawn` glow-shell using the item's own model** (clean, removable, no save pollution, 0.51 interactability fix makes it viable), **(2) invisible-light spawning** (real illumination, but save/record pollution and light-limit risks), **(3) UI screen-space markers** (current state of the art in the community), **(4) mesh swap — not possible at runtime**. True screen-space outlines are not achievable with any documented 0.51 API.

---

# Highlight Interactables — visuals recommendation
Scope: OpenMW 0.51, mod at `P:/Morrowind Modding CoWork/highlight-interactables/scripts/TwentyTwentyObjects/`. Synthesized from the tracking diagnosis, OMWFX feasibility report, and alternatives report. All API claims below are sourced from those reports (docs-verified), not memory.

---

## 1. Tracking fix plan (build now)

The lag is not a rendering problem; it is a cadence problem. Markers update at ~30 Hz from the simulation phase while the camera renders at 60–120 Hz.

**Step 1 — Reproject every rendered frame via `onFrame`.**
- `player_native.lua:866-870`: add `onFrame = function(dt) if currentProfile then outlinePulseTime = outlinePulseTime + dt; updateLabels(dt) end end` to `engineHandlers`.
- `player_native.lua:827-831`: delete the `updateAccumulator` gate; `player_native.lua:824`: remove the pulse increment from `onUpdate`.
- Rescan (`player_native.lua:838-845`, 0.25 s) stays in `onUpdate` unchanged.
- Expected result: removes 1–3 frames of staleness plus the ≥1-frame simulation-phase trail. This alone resolves the reported "doesn't track" symptom.

**Step 2 — Hoist the storage read out of `worldToScreen` (mandatory before Step 1 ships).**
- `projection.lua:73-74`: replace the per-call `storage.get('general')` with a module-local refreshed on scan (`player_native.lua:189/200`).
- Expected result: eliminates ~14k engine-storage C-boundary reads/sec at 60 fps that Step 1 would otherwise introduce.

**Step 3 (optional perf) — Center-only projection in the per-frame path.**
- Project only `bbox.center` per frame for glows; reuse scan-time diameter (`computeGlowDiameter` already prefers the distance-independent world diagonal, `labelRenderer_native.lua:156-168`); refresh full 8-corner geometry only on 0.25 s scan ticks.
- Expected result: ~240 projections/frame → ~30–60; per-frame cost drops from ~0.7–1.5 ms to ~0.3–0.6 ms for 30 markers. A few px of glow-size error, invisible in practice.

**Step 4 — guiScale sanity (no code, or small QoL).**
- `projection.lua:122-124` divides by a user-set `guiScale`; a mismatch with the engine's actual GUI scaling produces a position-dependent offset users describe as "not tracking." Verify the setting; also fix the self-inconsistency at `projection.lua:181-187` (`isOnScreen` compares scaled positions against unscaled screen size).

**Follow-up (separate change, only if hitching persists):** replace `clearAllLabels()` (`player_native.lua:211`) with a diff of candidates vs `activeLabels` and widget reuse; kills the 4 Hz destroy/recreate spike (~60 `ui.create` + occlusion raycasts + 240 projections in one frame). Same treatment for jitter-mode line recreation (`player_native.lua:707-723`).

---

## 2. Outline/glow options, ranked

Hard constraint first: **a true Diablo-style per-object silhouette outline is impossible on 0.51.** OMWFX exposes no stencil, object-ID, or mask buffer — a fullscreen shader cannot know which pixels belong to a given object. Every "outline" option below is an approximation.

| # | Option | Feasibility on 0.51 | Visual quality | Perf | Effort | Risks |
|---|--------|---------------------|----------------|------|--------|-------|
| 1 | **VFX glow shell** — `world.vfx.spawn` using the item's own `.model`, scaled up slightly, `useAmbientLight`, tinted | Yes, docs-confirmed. 0.51 specifically fixed "VFX using a model no longer makes the object non-interactable" — this pattern was broken pre-0.51 | High — a glow *of the item's own shape*; closest achievable to "the item glows" | Cheap; engine-side rendering, no per-frame Lua projection | **M** | Tinting via `particleTextureOverride` on arbitrary meshes is unverified — may need a shipped glow-shell NIF or material trick. VFX don't track moving objects (fine for ground loot; reposition on scan tick for physics-settling items). Persistence across save/load undocumented — assume gone, respawn in `onLoad`. No save/record pollution. |
| 2 | **Screen-space orbs/labels (current), fixed per §1** | Yes — already shipped | Medium — markers, not glow; but tight tracking after the fix changes the feel substantially | ~0.3–0.6 ms/frame for 30 markers (with Step 3) | **S** | None new. This is also the community state of the art — no existing OpenMW mod does world-space outlines. |
| 3 | **OMWFX depth/normals edge outline scoped to Lua-fed bbox rects** | Yes, every ingredient documented: `omw_SamplerDepth`/`omw_GetLinearDepth`, `omw_SamplerNormals` (gated on `pass_normals`/`OMW_NORMALS`), `dynamic` technique, `uniform_vec4 uRects { size = N; static = false; }`, per-frame `Shader:setVector4Array` | Medium and scene-dependent — depth edges are scene-global, so clutter inside the rect (shelves, other items, walls) also outlines. Occlusion rejection via linear-depth-vs-camera-distance is a heuristic. Not a silhouette. | Fragment-shader kernel over rect-covered pixels; fine | **L** | Highest effort, most fragile result. Normals not guaranteed available (`OMW_NORMALS` fallback required). No `#include` support. Overlapping rects, screen-edge cases, dozens of rects all need handling. |
| 4 | **Invisible-light attachment** — one runtime Light record, spawned/teleported instances | Yes (`world.createRecord` Light, `types.Light.createRecordDraft`) | Low-medium — illumination, not a highlight; floor/walls brighten too | OK until light limits bite (default max 16 lights/object; fights torches) | **M** | Permanent record pollution (no `world.removeRecord`); instance orphaning in saves if cleanup misses; known `createRecord`-in-`onLoad` ID bug (#7540); phantom entries in `nearby.*` scans including the mod's own. Conflicts directly with the project's persisted-data discipline. |
| 5 | **`animation.addVfx` on the item** | Unverified — local-context, documented for actors only; non-actor support undocumented | — | — | M | Requires `addScript` per item; treat as not viable without a throwaway probe. |
| 6 | **Mesh/model swap, switch-node glow, true silhouette outline** | **No.** Records immutable at runtime; clone-and-respawn changes `recordId` (breaks stacking/quests/other mods) and pollutes saves per item type. `NightDaySwitch` has no Lua binding. No ID/stencil buffer in OMWFX. | — | — | — | Do not attempt. |

---

## 3. Recommended path

**Build now (this week):**
1. Tracking fix §1 Steps 1–3 + guiScale check. Small, isolated, resolves the stated complaint regardless of what happens with glow.
2. Ship the fixed orbs as the baseline — they remain the fallback and the occlusion/scan infrastructure is shared by everything else.

**Prototype next (timeboxed, one item type, one interior cell):**
3. **VFX glow shell (option 1).** It is the only technique that makes *the item itself* appear to glow, and 0.51 is the first version where it works without breaking activation. Prototype must answer three unknowns before committing: (a) does tint/`particleTextureOverride` produce an acceptable glow on ordinary item meshes, or is a custom shell NIF needed; (b) exact save/load behavior of spawned VFX; (c) cost of respawn-on-scan-tick for 30 simultaneous shells. Prior art for the spawn pattern exists (OpenMW Impact Effects).

**Prototype only if the VFX shell fails visually:**
4. OMWFX rect-scoped depth-edge outline (option 3). Accept up front that it is an approximation that degrades in cluttered scenes; the L effort is only justified if option 1's visuals disappoint.

**Drop:**
- Light attachment (option 4) — pollution and light-limit risks outweigh a visual effect that isn't even a highlight.
- `animation.addVfx` on non-actors, mesh swap, switch-node tricks, true silhouettes (options 5–6).
- Do not attempt the widget-reuse rescan rewrite yet; only if hitching remains after Step 1–3 lands.

---

## 4. In-game validation

**Tracking fix:**
- Pan camera fast (mouse flick) with 10+ markers visible at 60 fps and uncapped/120 fps: markers must stay pinned to objects with no visible trail. Before/after comparison at 120 fps is the sharpest test (was every-4th-frame updates).
- Strafe sideways past a table of loot at close range (highest angular velocity case).
- Watch for the residual 4 Hz hitch (0.25 s rescan spike) — note it, decide whether the widget-reuse follow-up is warranted.
- Test at engine GUI scaling 1.0 and a non-1.0 value with matching/mismatching mod `guiScale`: confirm offset appears only on mismatch and grows toward bottom-right (confirms cause-4 model).
- Marker on-screen culling near screen edges after the `isOnScreen` scale fix.

**VFX shell prototype:**
- Item under shell remains activatable (crosshair + activate) — the 0.51 fix, verify it directly.
- Shell aligns with item at various scales/rotations; check a rotated/physics-settled item.
- Tint/glow legibility in a dark interior, a lit interior, and exterior daylight (`useAmbientLight` on/off).
- Save with shells active, reload: confirm whether shells persist or vanish; confirm respawn-on-load path leaves no duplicates.
- 30 shells simultaneously: frame-time delta vs baseline.
- Toggle highlight off: `world.vfx.remove(vfxId)` clears every shell, nothing orphaned after cell change.

**OMWFX prototype (if reached):**
- Outline on an isolated item vs an item on a cluttered shelf (false-edge severity).
- Partially occluded item: depth-heuristic rejection quality.
- Two overlapping rects; rect half off-screen; 20+ rects (uniform array size ceiling chosen at declaration).
- Hardware without normals support: `OMW_NORMALS == 0` fallback renders depth-only edges, no shader error.

