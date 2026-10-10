# 0012 — Model manifests + zoo workbench

**What.** An entity kind's presentation (model path, offset, loop clips, action clips, look nodes, overlay root) is a `graphics.ModelRow`. `assets/manifest/<kind>.zon` holds that row when it exists; if there's no file, the row comes from the Zig spec (`ModelRow.fromSpec`). `Models.update` watches the file and the .glb the same way, and when either changes it re-resolves the `Rig` (now including `offset`). The zoo scene (main menu → Zoo, `PZ_AUTOSTART=zoo`) shows one kind on a turntable and lists its slots and the model's clips. Clicking a clip writes the .zon file, and the watcher applies it on the next frame. The UI never touches `Models` directly.

**Why.** Model metadata used to need a Zig rebuild. Now Lucas or the friend can edit it mid-run without a compiler. The vault's `entity-architecture.md` ModelRow / models.zon trigger has fired.

**Alternatives.** The zoo could edit `Models` in memory and save separately. Rejected: that gives two paths to the same state. Going through the file means one door.

**Connections.** Gameplay numbers stay in the Zig rows. Not built yet: tint (needs a per-draw color in DrawList + shaders), sounds per event (sounds are still keyed by skill in the client), icons, item models, and window drag-drop. The console drives the zoo too: `pz cmd "kind tubloid" "slot walk" "clip Run"`.
