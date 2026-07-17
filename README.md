# Highlight Interactables (for OpenMW)

**Highlight Interactables** is a fork of **TwentyTwentyObjects** by **maxbickett**
(https://github.com/maxbickett/twentytwentyobjects). All credit for the original
mod, its architecture, and its core functionality goes to the original author.
The original is MIT-licensed; this fork retains that license and the original
LICENSE file.

The changes in this fork were made with AI assistance (Anthropic's Claude),
directed and playtested by the fork maintainer.

> **Internal naming:** script paths (`scripts/TwentyTwentyObjects/`), the Lua
> interface (`I.TwentyTwentyObjects`), and the settings storage key deliberately
> keep the original mod's name. Renaming them would break existing saves and
> stored settings, and keeping them doubles as attribution. Only the
> user-facing name, folder, and `.omwscripts` file are renamed.

## Installation

Add the mod folder as a data path and enable `HighlightInteractables.omwscripts`
as content in the OpenMW launcher (or openmw.cfg). Requires OpenMW 0.49+
(developed and tested on 0.51). Not compatible with vanilla Morrowind or MWSE.
If upgrading from TwentyTwentyObjects, disable/remove the original first —
running both will double-register hotkeys and settings.

## Changes from the original

**New features**
- Soft glow highlight mode: a pulsing radial glow centered on each object
  (Image-widget based, bundled gradient texture), independent of text labels —
  run either or both.
- Glow customization in settings: color (6 presets), size (25–300% in 25%
  steps), opacity (10–100% in 10% steps).
- Glow size derives from each object's physical (world-space) size, so it's a
  stable marker: bigger objects get bigger circles, but distance to the object
  doesn't change the circle.
- When glow and text are both enabled, text labels anchor to the glow instead
  of using the jitter solver.
- Mouse buttons (middle, right, extra 4/5) can be bound as highlight hotkeys.
- "Dead bodies" filter: living NPCs/creatures and corpses filter separately
  (corpses are gathered via cell scan since `nearby.actors` omits them on
  current builds).
- "UI Scale Correction (%)" setting so labels align at non-default OpenMW GUI
  scaling factors.

**Fixes**
- Highlights rescan periodically while active — objects entering view while
  the hotkey is held now get picked up (the original only captured what was
  visible at the moment of the keypress).
- Fixed the bounding-box code path: `getBoundingBox()` returns a `util.box`
  with `center`/`halfSize`/`vertices` — the original checked nonexistent
  `min`/`max`, so real bounding boxes were never used.
- Fixed the `activators` filter being silently stripped by BOTH profile
  serializers (hotkey listener and global script).
- Skip empty-named objects in glow mode (invisible ambient light emitters
  otherwise get phantom highlights).

**Known limitations**
- Glow is a screen-space effect, not a mesh silhouette (no per-object outline
  shader in OpenMW's Lua API).
- In exteriors, corpses in adjacent grid cells within the highlight radius may
  be missed (cell scan covers the player's own cell).
- The original mod's connecting-line rendering does not work on current OpenMW
  builds (engine issue #7848) and was already nonfunctional before this fork.

## Full usage documentation

Profiles, quick-start presets, performance settings, and troubleshooting are
documented in the original mod's README, preserved as
[README-original.md](README-original.md). Note that the "thin connecting
lines" it describes do not render on current OpenMW builds (see Known
limitations above).
