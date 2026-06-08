#!/usr/bin/env python3
"""Build freq.sqlite for the hybrid gloss pipeline (Stage 4).

Source: wordfreq v3.1.1 (https://github.com/rspeer/wordfreq) by Robyn Speer, CC-BY-SA 4.0.
Stores word -> zipf (as centi-zipf INTEGER, i.e. round(zipf*100)) per language, for words at
or above ZIPF_FLOOR. Lookup at runtime is by lemma (lemma langs) or surface (others); both are
ordinary wordfreq surface keys, so one flat table serves both. Words below the floor are absent
=> treated as "rare" => always glossed.

Usage: python3 tools/build_freq_db.py [out.sqlite] [zipf_floor]
"""
import sqlite3, math, os, sys
from wordfreq import get_frequency_dict

LANGS = ["de", "es", "fr", "it", "pt", "ru", "tr", "en", "ja", "zh", "ko"]
OUT   = sys.argv[1] if len(sys.argv) > 1 else "Prompt Playground/Resources/freq.sqlite"
FLOOR = float(sys.argv[2]) if len(sys.argv) > 2 else 3.5

if os.path.exists(OUT):
    os.remove(OUT)
con = sqlite3.connect(OUT)
con.execute("PRAGMA page_size=4096")
con.execute("PRAGMA journal_mode=DELETE")
con.execute("CREATE TABLE freq (lang TEXT, word TEXT, z INTEGER, PRIMARY KEY(lang, word)) WITHOUT ROWID")
total = 0
for lg in LANGS:
    d = get_frequency_dict(lg)
    rows = [(lg, w, round((math.log10(f) + 9) * 100)) for w, f in d.items() if math.log10(f) + 9 >= FLOOR]
    con.executemany("INSERT OR IGNORE INTO freq VALUES (?,?,?)", rows)
    total += len(rows)
    print(f"  {lg}: {len(rows)} rows")
con.commit()
con.execute("VACUUM")
con.commit()
con.close()
print(f"floor zipf>={FLOOR}  total {total} rows  size {os.path.getsize(OUT)/1e6:.2f} MB  -> {OUT}")
