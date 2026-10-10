"""Deepest block nesting per Zig function. Usage: tools/nesting.py [min_depth] [files...]
Prints `depth file:line fn_name`, deepest first. Depth 1 = the function body."""
import re
import subprocess
import sys

FN = re.compile(r"^\s*(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+(\w+)")


def strip(line):
    out, quote, escaped = [], False, False
    for index, char in enumerate(line):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = False
            continue
        if line.startswith("//", index):
            break
        if char == '"':
            quote = True
            continue
        if char == "'" and index + 2 < len(line) and line[index + 2] == "'":
            continue
        out.append(char)
    return "".join(out)


def scan(path):
    results, stack = [], []
    with open(path, encoding="utf-8", errors="replace") as file:
        for number, raw in enumerate(file, 1):
            match = FN.match(raw)
            line = strip(raw)
            if match:
                stack.append({"name": match.group(1), "line": number, "depth": 0, "max": 0})
            for char in line:
                if not stack:
                    break
                top = stack[-1]
                if char == "{":
                    top["depth"] += 1
                    top["max"] = max(top["max"], top["depth"])
                elif char == "}":
                    top["depth"] -= 1
                    if top["depth"] == 0 and top["max"] > 0:
                        results.append((top["max"], path, top["line"], top["name"]))
                        stack.pop()
    return results


def main():
    args = sys.argv[1:]
    min_depth = int(args.pop(0)) if args and args[0].isdigit() else 5
    files = args or subprocess.run(
        ["git", "ls-files", "*.zig"], capture_output=True, text=True, check=True
    ).stdout.split()
    files = [f for f in files if "zig-pkg" not in f]
    rows = [row for f in files for row in scan(f) if row[0] >= min_depth]
    for depth, path, line, name in sorted(rows, reverse=True):
        print(f"{depth} {path}:{line} {name}")


if __name__ == "__main__":
    main()
