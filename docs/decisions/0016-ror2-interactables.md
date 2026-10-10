# 0016 — Interactables like RoR2: shrines, barrels, printers

**What.** The scene director (decision 0014) spends interactable credits on weighted cards (`interactable_cards` in `server/src/gameplay/director.zig`):

| card | cost | weight | use |
|---|---|---|---|
| lootbox (chest) | 15 | 24 | pay `25·coeff^1.25`, small-chest item |
| barrel | 1 | 10 | free, `0.4·25·coeff` gold |
| multishop | 20 | 8 | three terminals, each shows a common; buying one (chest price) closes the group (linked by `owner_id`) |
| printer | 25 | 3 | trade one random same-tier item for its (common) item; reusable |
| shrine of chance | 20 | 4 | pay `17·coeff^1.25`; 45% nothing (price ×1.4), else an item and the shrine is spent |
| shrine of combat | 20 | 3 | free; instant director with 100·coeff credits |
| shrine of the mountain | 20 | 3 | free; +1 stack: boss director credits ×(1+stacks), boss drops ×(1+stacks) |

Every use goes through one door, `PlayerController.use` (E key, or `/use` in dev). All of them are plain `Kind` rows (wire change, protocol bumps automatically). Printers send their item in the spawn data.

**Why.** Lucas: mimic RoR2 heavily. These are the RoR2 stage staples that need no new UI. Scrapper needs a pick-one UI, and drones need ally AI, so they wait.

**Placeholders.** Shrines and printers use the pillar model, barrels the unused `chest.glb`. Listed under "Needs asset from Lucas".
