# azure-latch-scripts

Standalone Luau scripts for Azure Latch, loaded with a one-line `loadstring`.

## metavision-dimmer.lua

Tames Nel Isagi's T special (Metavision). It keeps the ball path beam and hides
the glare: particle emitters are zeroed (`Rate = 0`, `Lifetime = 0`,
`Transparency = 1`), puzzle beams and pieces are faded, and a ColorCorrection is
added on top of the image so the brightness drop survives the effect's own
per-frame lighting writes.

Panel: DIMMER / VFX CUT / PUZZLES / BEAM / WASH / DARK / BOTH ISAGI / UNLOAD.
Console API: `_G.MetaDim.Report()`, `_G.MetaDim.Set(vfx, beam, wash, dark, puzzles)`,
`_G.MetaDim.Unload()`.

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/adJKMDADAD/meta-vision-dimmer/main/metavision-dimmer.lua"))()
```

Fallback host used before the repo existed:

```lua
loadstring(game:HttpGet("https://files.catbox.moe/e4hmki.lua"))()
```

## Updating

Edit `metavision-dimmer.lua`, commit, push. The raw url above always serves the
`main` branch, so the loader string never changes.
