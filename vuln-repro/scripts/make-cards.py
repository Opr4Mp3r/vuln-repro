#!/usr/bin/env python3
"""Render full-screen explanation/result cards for reproduction videos.

Input: a JSON spec (see storyboard.md / recording.md). Output: one PNG per
card plus placement.tsv, which encode-frames.sh --cards consumes to splice
cards into the encoded MP4 (card durations are exact seconds at the 30 fps
output rate, independent of the measured capture fps).

Spec format (cards.json):
{
  "cards": [
    {"id": "title", "kind": "text", "seconds": 6,
     "title": "ExampleSoft ExampleFlt 本地拒绝服务",
     "lines": ["成因：IOCTL 0x222000 索引越界", "组件：ExampleFlt.sys 1.0.0.1", ...],
     "footer": "隔离 VM · 仅用于漏洞复现材料"},
    {"id": "result", "kind": "bsod", "seconds": 8,
     "title": "结果：BugCheck 0x50",
     "lines": ["事件 1001 · RecordId 18267", "故障模块：ExampleFlt.sys"]}
  ],
  "placement": {"pre": ["title"], "post": ["result", "conclusion"]}
}

Result-card discipline: kind=bsod content must come from the MEASURED event
log (BugCheck code, Event 1001 RecordId), never pre-filled expectations.

placement.tsv (tab-separated, '#' comments) is the timeline encode builds:
  card<TAB><png relative to cards dir><TAB><seconds>
  frames<TAB><from><TAB><to>       # inclusive positions in the sorted frame
                                    # list; to=-1 means "last frame"
Default emission: pre cards, frames 0 -1, post cards. Hand-edit to insert
mid-video step cards by splitting the frames range.

Usage:
  make-cards.py --spec cards.json --out-dir cards/ [--font PATH]
"""
import argparse
import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("FAIL: Pillow not installed (python3 -m pip install Pillow)")

# CJK-capable font candidates, Linux distros first (production), macOS for
# local dev. CARDS_FONT / --font overrides everything.
FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",       # Debian fonts-noto-cjk
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",     # RHEL/Fedora
    "/usr/share/fonts/google-noto-sans-cjk-sc/NotoSansCJK-Regular.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",                   # macOS dev
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",              # Latin-only fallback
]

TEXT_BG = (13, 17, 23)
TEXT_TITLE = (240, 246, 252)
TEXT_BODY = (216, 222, 228)
TEXT_FOOTER = (130, 139, 148)
ACCENT = (56, 139, 253)
BSOD_BG = (0, 120, 215)


def find_font(explicit):
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("CARDS_FONT"):
        candidates.insert(0, os.environ["CARDS_FONT"])
    candidates.extend(FONT_CANDIDATES)
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    sys.exit("FAIL: no usable font found (tried %s); pass --font <path-to-ttf/ttc>"
             % ", ".join(p for p in candidates if p))


def load_font(path, size):
    return ImageFont.truetype(path, size)


def wrap(draw, text, font, max_width):
    """Wrap by whitespace words; char-wrap CJK runs that exceed max_width."""
    lines = []
    for word in text.split(" ") or [""]:
        # char-split any token wider than the line (CJK has no spaces)
        while draw.textlength(word, font=font) > max_width and len(word) > 1:
            cut = len(word)
            while cut > 1 and draw.textlength(word[:cut], font=font) > max_width:
                cut -= 1
            lines.append(word[:cut])
            word = word[cut:]
        if not lines or lines[-1] == "":
            lines.append(word)
        elif draw.textlength(lines[-1] + " " + word, font=font) <= max_width:
            lines[-1] += " " + word
        else:
            lines.append(word)
    return lines or [""]


def fit_title(draw, title, font_path, max_width, start_size):
    """Shrink the title until it fits at most 2 wrapped lines."""
    size = start_size
    while size >= 40:
        font = load_font(font_path, size)
        if len(wrap(draw, title, font, max_width)) <= 2:
            return font, size
        size -= 4
    return load_font(font_path, 40), 40


def render_text_card(card, font_path, size):
    img = Image.new("RGB", size, TEXT_BG)
    d = ImageDraw.Draw(img)
    margin = size[0] // 12
    max_w = size[0] - 2 * margin
    y = margin

    title_font, _ = fit_title(d, card["title"], font_path, max_w, size[1] // 13)
    for ln in wrap(d, card["title"], title_font, max_w):
        d.text((margin, y), ln, font=title_font, fill=TEXT_TITLE)
        y += title_font.size + 14
    y += 14
    d.rectangle([margin, y, margin + max_w // 5, y + 6], fill=ACCENT)
    y += 6 + size[1] // 22

    body_font = load_font(font_path, size[1] // 26)
    line_h = body_font.size + size[1] // 38
    for raw in card.get("lines", []):
        for ln in wrap(d, raw, body_font, max_w):
            d.text((margin, y), ln, font=body_font, fill=TEXT_BODY)
            y += line_h
    if y > size[1] - margin // 2:
        print("WARN: card '%s' content overflows %dx%d; shorten lines"
              % (card["id"], *size), file=sys.stderr)

    footer = card.get("footer")
    if footer:
        f_font = load_font(font_path, size[1] // 38)
        w = d.textlength(footer, font=f_font)
        d.text((size[0] - margin - w, size[1] - margin // 1.6), footer,
               font=f_font, fill=TEXT_FOOTER)
    return img


def render_bsod_card(card, font_path, size):
    img = Image.new("RGB", size, BSOD_BG)
    d = ImageDraw.Draw(img)
    margin = size[0] // 10
    max_w = size[0] - 2 * margin
    y = margin

    face_font = load_font(font_path, size[1] // 6)
    d.text((margin - size[0] // 60, y), ":(", font=face_font, fill=(255, 255, 255))
    y += face_font.size + size[1] // 9

    title_font, _ = fit_title(d, card["title"], font_path, max_w, size[1] // 21)
    for ln in wrap(d, card["title"], title_font, max_w):
        d.text((margin, y), ln, font=title_font, fill=(255, 255, 255))
        y += title_font.size + 12
    y += size[1] // 30

    body_font = load_font(font_path, size[1] // 30)
    line_h = body_font.size + size[1] // 45
    for raw in card.get("lines", []):
        for ln in wrap(d, raw, body_font, max_w):
            d.text((margin, y), ln, font=body_font, fill=(230, 238, 246))
            y += line_h
    if y > size[1] - margin // 2:
        print("WARN: card '%s' content overflows %dx%d; shorten lines"
              % (card["id"], *size), file=sys.stderr)
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", required=True, help="cards.json (see module docstring)")
    ap.add_argument("--out-dir", required=True, help="output dir for PNGs + placement.tsv")
    ap.add_argument("--font", help="ttf/ttc path (default: probe CJK candidates)")
    ap.add_argument("--size", default="1920x1080", help="card resolution (default 1920x1080)")
    args = ap.parse_args()

    try:
        w, h = (int(x) for x in args.size.lower().split("x"))
    except ValueError:
        sys.exit("FAIL: --size must be WxH, e.g. 1920x1080")
    size = (w, h)

    with open(args.spec, encoding="utf-8") as f:
        spec = json.load(f)
    cards = spec.get("cards") or []
    if not cards:
        sys.exit("FAIL: spec has no cards")
    placement = spec.get("placement") or {}
    pre = placement.get("pre") or []
    post = placement.get("post") or []
    ids = [c["id"] for c in cards]
    for missing in [i for i in pre + post if i not in ids]:
        sys.exit("FAIL: placement references unknown card id: %s" % missing)

    font_path = find_font(args.font)
    os.makedirs(args.out_dir, exist_ok=True)

    rendered = {}
    for card in cards:
        kind = card.get("kind", "text")
        seconds = float(card.get("seconds", 6))
        if seconds <= 0:
            sys.exit("FAIL: card '%s': seconds must be > 0" % card["id"])
        if kind == "text":
            img = render_text_card(card, font_path, size)
        elif kind == "bsod":
            img = render_bsod_card(card, font_path, size)
        else:
            sys.exit("FAIL: card '%s': kind must be text or bsod" % card["id"])
        out_png = os.path.join(args.out_dir, card["id"] + ".png")
        img.save(out_png)
        rendered[card["id"]] = (card["id"] + ".png", seconds)
        print("wrote %s (%s, %.1fs)" % (out_png, kind, seconds))

    with open(os.path.join(args.out_dir, "placement.tsv"), "w", encoding="utf-8") as f:
        f.write("# timeline for encode-frames.sh --cards (tab-separated)\n")
        f.write("# card <png> <seconds> | frames <from> <to> (inclusive; -1 = last)\n")
        for cid in pre:
            png, sec = rendered[cid]
            f.write("card\t%s\t%.1f\n" % (png, sec))
        f.write("frames\t0\t-1\n")
        for cid in post:
            png, sec = rendered[cid]
            f.write("card\t%s\t%.1f\n" % (png, sec))
    print("wrote %s (pre=%s frames=ALL post=%s; hand-edit for mid-video cards)"
          % (os.path.join(args.out_dir, "placement.tsv"), pre or "-", post or "-"))


if __name__ == "__main__":
    main()
