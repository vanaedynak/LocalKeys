"""Builds the Android keyboard's word lists (assets/lm_*.txt) from FrequencyWords.

Source: https://github.com/hermitdave/FrequencyWords (content/2018/<lang>/<lang>_50k.txt),
word frequencies from OpenSubtitles, CC BY-SA 4.0. Usage:
    python build_lm.py <dir with en_50k.txt, ru_50k.txt, uk_50k.txt> <assets dir>
Output: first line = alphabet; then "word count" lines in alphabet order (binary-searchable).
"""
import os
import sys

ALPHABETS = {
    "en": "abcdefghijklmnopqrstuvwxyz",
    "ru": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя",
}
TOP = 30000

src, dst = sys.argv[1], sys.argv[2]
for lang, abc in ALPHABETS.items():
    rank = {c: i for i, c in enumerate(abc)}
    merged = {}
    with open(os.path.join(src, f"{lang}_50k.txt"), encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            w, n = parts[0].lower(), int(parts[1])
            if not 1 <= len(w) <= 24 or any(c not in rank for c in w):
                continue
            merged[w] = merged.get(w, 0) + n
            if len(merged) >= TOP:
                break
    out = sorted(merged.items(), key=lambda e: [rank[c] for c in e[0]])
    with open(os.path.join(dst, f"lm_{lang}.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(abc + "\n")
        for w, n in out:
            f.write(f"{w} {n}\n")
    print(lang, len(out))
