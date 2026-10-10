#!/usr/bin/env python3
"""Builds the Obsidian asset board: one note per asset (+ thumbnail) and Board.base.

Usage: tools/asset_board.py [--no-shots] [--vault DIR]
Needs the game running in the zoo (`tools/pz run zoo`) unless --no-shots and a catalog exists.
Never overwrites `approved`, `status` or the "## My notes" section of an existing note."""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONSOLE = os.environ.get("PZ_CONSOLE", "/tmp/pz-console")
DEFAULT_VAULT = os.path.expanduser("~/Obsidian/Projects/PlanetaryZigma/Assets")
VAULT_ROOT = os.path.expanduser("~/Obsidian")
SHOT_SETTLE = 1.6


def console(*lines):
    with open(CONSOLE, "a") as file:
        for line in lines:
            file.write(line + "\n")


def read_catalog():
    path = CONSOLE + ".catalog"
    if os.path.exists(path):
        os.remove(path)
    console("!catalog")
    for _ in range(40):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            break
        time.sleep(0.1)
    else:
        sys.exit("no catalog: is the game running? (tools/pz run zoo)")
    records, current = [], {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            if current:
                records.append(current)
            current = {}
            continue
        key, _, value = line.partition(": ")
        current[key] = value
    if current:
        records.append(current)
    return records


def screenshot(target):
    """Window screenshot cropped to the centre, where the zoo frames its subject."""
    raw = target + ".raw.png"
    subprocess.run([os.path.join(ROOT, "tools", "pz"), "shot", raw, "1"], check=True, capture_output=True)
    from PIL import Image
    image = Image.open(raw)
    width, height = image.size
    side = int(min(width, height) * 0.8)
    left, top = (width - side) // 2, int((height - side) * 0.55)
    image.crop((left, top, left + side, top + side)).resize((384, 384)).save(target)
    os.remove(raw)


def take_thumbs(records, thumbs, shots):
    if shots:
        sparse = [r["thumb"][len("biome:"):] for r in records if r.get("id") == "biome-dust"]
        console("photo")
        if sparse:
            console("radius " + sparse[0])
        time.sleep(SHOT_SETTLE + 2)
    for record in records:
        source = record.get("thumb", "none")
        target = os.path.join(thumbs, record["id"] + ".png")
        if source.startswith("icon:"):
            icon = os.path.join(ROOT, "assets", source[len("icon:"):])
            if os.path.exists(icon):
                shutil.copyfile(icon, target)
                record["thumb_file"] = target
            continue
        if not shots:
            if os.path.exists(target):
                record["thumb_file"] = target
            continue
        if source.startswith("zoo:"):
            kind = source[len("zoo:"):]
            console("kind " + kind, "focus")
        elif source.startswith("biome:"):
            console("radius " + source[len("biome:"):], "kind teleporter", "focus")
            time.sleep(3)
            screenshot(target)
            record["thumb_file"] = target
            console("radius " + (sparse[0] if sparse else "150"))
            time.sleep(3)
            continue
        else:
            continue
        time.sleep(SHOT_SETTLE)
        screenshot(target)
        record["thumb_file"] = target
    if shots:
        console("photo", "radius 150")


def misc_records():
    """Open asset requests from TASKS.md and unticked player-facing text from lucas-approval.md."""
    records = []
    tasks = open(os.path.join(ROOT, "TASKS.md"), encoding="utf-8").read()
    section = tasks.split("## Needs asset from Lucas", 1)[1].split("\n## ", 1)[0]
    for line in section.splitlines():
        if line.startswith("- "):
            records.append({"name": line[2:].strip(), "category": "misc", "description": "Asset request (TASKS.md)"})
    for line in tasks.splitlines():
        if line.startswith("- [ ] "):
            name = line[6:].split(" — ", 1)[0].strip()
            records.append({"name": name, "category": "misc", "description": line[6:].strip()[:400]})
    for line in open(os.path.join(ROOT, "docs", "lucas-approval.md"), encoding="utf-8"):
        if line.startswith("- [ ] "):
            records.append({"name": line[6:].strip(), "category": "text", "description": "Player-facing text (docs/lucas-approval.md)"})
    for record in records:
        slug = re.sub(r"[^a-z0-9]+", "-", record["name"].lower()).strip("-")[:48]
        record["id"] = record["category"] + "-" + slug
    return records


def yaml_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def existing_state(path):
    state = {"approved": "false", "status": "todo", "notes": "\n"}
    if not os.path.exists(path):
        return state
    text = open(path, encoding="utf-8").read()
    for key in ("approved", "status"):
        match = re.search(r"^" + key + r": (.*)$", text, re.M)
        if match:
            state[key] = match.group(1).strip()
    if "## My notes" in text:
        state["notes"] = text.split("## My notes", 1)[1]
    return state


def write_note(notes, record):
    path = os.path.join(notes, record["id"] + ".md")
    state = existing_state(path)
    thumb = ""
    if record.get("thumb_file"):
        thumb = "[[" + os.path.relpath(record["thumb_file"], VAULT_ROOT) + "]]"
    lines = ["---"]
    lines.append("name: " + yaml_string(record.get("name", record["id"])))
    lines.append("category: " + record.get("category", "misc"))
    lines.append("approved: " + state["approved"])
    lines.append("status: " + state["status"])
    lines.append("thumb: " + yaml_string(thumb))
    for key in ("description", "stats", "abilities", "needs"):
        if record.get(key):
            lines.append(key + ": " + yaml_string(record[key]))
    lines.append("---")
    if thumb:
        lines.append("!" + thumb)
    lines.append("")
    lines.append("## My notes" + state["notes"].rstrip("\n") + "\n" if state["notes"].strip() else "## My notes\n")
    with open(path, "w", encoding="utf-8") as file:
        file.write("\n".join(lines))


BOARD = """filters:
  and:
    - file.inFolder("Projects/PlanetaryZigma/Assets/notes")
properties:
  note.name:
    displayName: Name
  note.category:
    displayName: Category
  note.approved:
    displayName: Approved
  note.status:
    displayName: Status
  note.description:
    displayName: Description
  note.stats:
    displayName: Stats
  note.abilities:
    displayName: Abilities
  note.needs:
    displayName: Needs
views:
  - type: cards
    name: To approve
    filters:
      and:
        - approved != true
    groupBy:
      property: category
      direction: ASC
    order:
      - name
      - approved
      - status
      - description
      - stats
      - abilities
      - needs
    image: note.thumb
    imageAspectRatio: 1
    cardSize: 260
  - type: cards
    name: All by category
    groupBy:
      property: category
      direction: ASC
    order:
      - name
      - approved
      - status
      - description
      - stats
      - abilities
      - needs
    image: note.thumb
    imageAspectRatio: 1
    cardSize: 260
  - type: cards
    name: Approved
    filters:
      and:
        - approved == true
    groupBy:
      property: category
      direction: ASC
    order:
      - name
      - description
    image: note.thumb
    imageAspectRatio: 1
    cardSize: 200
  - type: table
    name: Ship gate (everything not approved)
    filters:
      and:
        - approved != true
    order:
      - name
      - category
      - status
      - needs
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-shots", action="store_true")
    parser.add_argument("--vault", default=DEFAULT_VAULT)
    args = parser.parse_args()
    notes = os.path.join(args.vault, "notes")
    thumbs = os.path.join(args.vault, "thumbs")
    os.makedirs(notes, exist_ok=True)
    os.makedirs(thumbs, exist_ok=True)
    records = read_catalog()
    take_thumbs(records, thumbs, not args.no_shots)
    records += misc_records()
    for record in records:
        write_note(notes, record)
    with open(os.path.join(args.vault, "Board.base"), "w", encoding="utf-8") as file:
        file.write(BOARD)
    print(f"{len(records)} notes in {notes}")


if __name__ == "__main__":
    main()
