# PlanetaryZigma
A multiplayer 3D game set across procedurally generated planets, with gameplay heavily inspired by [Risk of Rain 2](https://store.steampowered.com/app/632360/Risk_of_Rain_2/). Each stage takes place on a unique planet filled with enemies, chests, and a boss that must be defeated before the teleporter can be charged and the players can progress to the next stage.

## Latest gameplay: [https://youtu.be/dQSKI70bBEo?t=8653](https://youtu.be/dQSKI70bBEo?t=8653)

### **[Steam Page](https://store.steampowered.com/app/3167780/Planetary_Zigma/)**
### *[Discord](https://discord.gg/7t4tNTqad)*


Planetary Zigma uses [Zig](https://ziglang.org/), [Vulkan](https://www.vulkan.org/), [Box3D](https://box2d.org/documentation3d/) and the [Steamworks SDK](https://partner.steamgames.com/).

# These are people who have helped multiple times, and deserves a shoutout. (dm if I forgot anyone)

[Harlad](https://github.com/HaraldWik): Custom windowing and *trying* to maintain code quality. 

Etakarinaee: Keeping Zig cod up-to-date.

[Dunnewortel(HTRMC)](https://github.com/HTRMC): Optimizng Code, and amazing ideas.

[ttchef](https://github.com/ttchef) & [Webbe](https://github.com/webbelito): brainstorming ideas.

[Hans](https://github.com/hansielneff): Inspired me to do my own engine.

[audiotrope](https://github.com/audiotrope) & [Damon](https://github.com/Ddemon26): Models, concepts and assets.

[Enty](https://github.com/Entytaiment25), Foo, [Webbe](https://github.com/webbelito): Backers <3



# Development

## Push Rules
1. Must compile.
2. Run.
3. Hot Reload.

## Requirements for building from source
[Zig 0.16.0](https://ziglang.org/download/)
[Vulkan 1.3](https://www.vulkan.org/)

## Dependencies for building.

*Debian/Ubuntu*
```
sudo apt install libvulkan1 vulkan-tools vulkan-validationlayers
```

*Arch*
```
sudo pacman -S --needed vulkan-icd-loader vulkan-tools vulkan-validation-layers
```
