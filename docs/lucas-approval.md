# Lucas approval — player-facing text not written by Lucas

Everything here was named or written by Claude. Tick it when you accept it, or overwrite the text in the code
and tick it. Rule (CLAUDE.md): any new player-facing name/description from Claude gets a line here.

## Survivors (`shared/src/Survivor.zig`)
- [ ] **Commando** — "Fast gunner. Bullets, a shotgun burst, a dash and a grenade."
- [ ] **Brawler** — "Tough melee fighter. Wide swings, a ground slam, a leap and a war cry that heals allies."
- [ ] **Marksman** — "Fragile sniper. Piercing rail shots, a grenade, a long blink and an artillery strike."
- [ ] Survivor stats and ability loadouts (health/damage/speed/cooldowns per survivor)
- [ ] Scatter balance: was 10 pellets x 100%, now 6 x 70% base damage (your example). Shoot and Punch now also use their damage multiplier (both 100%, so unchanged)

## Abilities (`shared/src/skill_info.zig`)
- [ ] Double Tap (shoot) — "Fire a fast bullet."
- [ ] Scatter (spread_shot) — "Fire a shotgun burst in a cone."
- [ ] Tactical Dive (dash) — "Dash forward along the ground."
- [ ] Equipment (use_equipment) — "Use your equipment item."
- [ ] Cube Shot (shoot_cube) — "Fire a slow heavy cube."
- [ ] Punch (melee) — "Hit the enemy in front of you."
- [ ] Leap (arc_jump) — "Jump in a high arc."
- [ ] Plant (plant) — "Root in place."
- [ ] Heal (heal) — "Restore health to nearby allies."
- [ ] Charge (charge) — "Wind up, then rush forward."
- [ ] Detonate (explode) — "Explode, damaging everything nearby."
- [ ] Cleave (melee_cone) — "Wide swing that hits everything in front of you."
- [ ] Ground Slam (ground_slam) — "Slam the ground, damaging enemies around you."
- [ ] Frag Grenade (grenade) — "Throw a grenade that explodes on impact."
- [ ] Railgun (railgun) — "Piercing shot that hits every enemy in a line."
- [ ] Blink (blink) — "Teleport a long way in the direction you look."
- [ ] War Cry (heal_pulse) — "Heal yourself and allies around you."
- [ ] Artillery (artillery) — "Call down a strike where you aim."

## Items (`shared/src/Item.zig`, name = the declaration name)
- [ ] leech_seed (common) — "heal 1 per hit, +1 per stack"
- [ ] coin_pouch (common) — "+1 gold per kill, +1 per stack"
- [ ] crowbar (common) — "+75% damage to enemies above 90% health, +75% per stack"
- [ ] boots (common) — "+14% movement speed"
- [ ] bandage (common) — "25% chance to heal 4 when hurt, +4 per stack"
- [ ] gasoline (uncommon) — "kills explode for 150% damage, bigger blast per stack"
- [ ] thorn_vest (uncommon) — "return 50% of damage taken to the attacker, +50% per stack"
- [ ] vampire_fang (uncommon) — "heal 8 on kill, +8 per stack"
- [ ] ghor_tome (uncommon) — "20% chance on kill to drop 15 gold, +15 per stack"
- [ ] leech_fang (uncommon) — "heal 5% of damage dealt, +5% per stack"
- [ ] brilliant_hammer (legendary) — "every hit explodes for 60% damage, bigger blast per stack"
- [ ] berserker_core (legendary) — "+50% damage, +30% attack speed"
- [ ] glass_heart (lunar) — "+60% damage, -25% max health"
- [ ] blood_pact (lunar) — "+30% damage, +2 regen, -20 max health"
- [ ] heal_spray (equipment) — "heal everyone near you for half their health"
- [ ] blast_wave (equipment) — "blast every enemy within 15 for 500% damage"
- [ ] freezer — your item, text changed: "freeze time for 20s" → "freeze every enemy for 3s"
- [ ] Tiers assigned to your old items (rocket/scope/rabbitsfoot/icicle = uncommon, lightning = boss)

## Monsters (`shared/src/entity/enemies.zig`)
- [ ] spitter (ranged kiter), wisp (orbiting flyer), mite (swarm, packs of 5), bomber (walks up and explodes)
- [ ] grass_tank behavior changed to a charger

## Elites (`shared/src/Elite.zig`)
- [ ] Blazing, Glacial, Overloading (names, colors, what they grant)

## Biomes (`shared/src/Biome.zig`)
- [ ] Coral Shelf (your old look, new name), Verdant Hills, Frost Spires, Dust Basin

## Difficulty (`shared/src/difficulty.zig`)
- [ ] Drizzle — "For new players. Difficulty rises slowly."
- [ ] Rainstorm — "The way the game is meant to be played."
- [ ] Monsoon — "For veterans. Difficulty rises fast."

## UI text
- [ ] Lobby: "SELECT SURVIVOR", "ABILITIES", "PLAYERS", "DIFFICULTY (host picks)", "READY (click to cancel)", "Leave", "Base Damage", ability line format "Primary - 0.3s - 100% base damage"
- [ ] HUD objective lines ("Find the teleporter", "Charge the teleporter N%", "Defeat the boss", "Enter the teleporter")
- [ ] Options tab "Audio", slider "Master Volume"
- [ ] Keybind label "Ping"; ping marker text "v <player>: <target>" / "here"
- [ ] Main menu button "Zoo" (dev tool — keep visible in release?)
