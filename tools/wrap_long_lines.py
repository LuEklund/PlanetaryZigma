"""Insert a trailing comma into the widest call/signature/struct literal of each
line longer than LIMIT so `zig fmt` puts one item per line. Run zig fmt after."""
import sys

LIMIT = 100
KEYWORDS = ("if", "while", "for", "switch", "catch", "orelse", "return", "and", "or")


def code_mask(line):
    mask, quote, escaped = [], None, False
    for index, char in enumerate(line):
        if quote:
            mask.append(False)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char == "/" and line[index:index + 2] == "//":
            mask.extend([False] * (len(line) - index))
            break
        if char in "\"'":
            quote = char
            mask.append(False)
            continue
        mask.append(True)
    return mask


def opener_ok(line, index):
    if line[index] == "{":
        return index > 0 and line[index - 1] == "."
    before = line[:index].rstrip()
    if not before or not (before[-1].isalnum() or before[-1] in "_)]"):
        return False
    word = before.split()[-1] if before.split() else ""
    word = word.lstrip("(!&*.")
    return word not in KEYWORDS


def widest_pair(line):
    mask = code_mask(line)
    stack, best = [], None
    for index, char in enumerate(line):
        if not mask[index]:
            continue
        if char in "({":
            stack.append(index)
        elif char in ")}" and stack:
            start = stack.pop()
            inner = line[start + 1:index].strip()
            if not inner or inner.endswith(",") or not opener_ok(line, start):
                continue
            if best is None or index - start > best[1] - best[0]:
                best = (start, index)
    return best


def wrap(text):
    out = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if len(line) <= LIMIT or stripped.startswith("//") or stripped.startswith("\\\\"):
            out.append(line)
            continue
        pair = widest_pair(line)
        if pair is None:
            out.append(line)
            continue
        start, end = pair
        inner_end = end
        while inner_end > start and line[inner_end - 1] == " ":
            inner_end -= 1
        out.append(line[:inner_end] + "," + line[inner_end:])
    return "\n".join(out)


for path in sys.argv[1:]:
    with open(path) as file:
        text = file.read()
    wrapped = wrap(text)
    if wrapped != text:
        with open(path, "w") as file:
            file.write(wrapped)
