"""Build the bundled ECDICT learner dictionary from the upstream CSV.

Usage: python scripts/build_dictionary.py path/to/ecdict.csv
Source: skywind3000/ECDICT commit bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b
Includes entries with corpus frequency, exam tags, or Oxford core-word status.
"""
import csv
import hashlib
import pathlib
import sqlite3
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(__file__).resolve().parents[1] / 'app/assets/dictionary/ecdict-v1.db'
target.parent.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(target)
db.execute('DROP TABLE IF EXISTS entries')
db.execute('CREATE TABLE entries (word TEXT PRIMARY KEY, phonetic TEXT, definition TEXT, translation TEXT, pos TEXT) WITHOUT ROWID')
with source.open(encoding='utf-8-sig', newline='') as stream:
    for row in csv.DictReader(stream):
        if not (int(row['bnc'] or 0) > 0 or int(row['frq'] or 0) > 0 or row['tag'] or row['oxford'] == '1'):
            continue
        word = row['word'].strip().lower()
        if not word or not row['translation'].strip():
            continue
        pos = ' / '.join(p.split(':')[0] + '.' for p in row['pos'].split('/') if p)
        db.execute('INSERT OR IGNORE INTO entries VALUES (?, ?, ?, ?, ?)', (
            word, row['phonetic'], row['definition'].replace('\\n', '\n'),
            row['translation'].replace('\\n', '\n'), pos))
db.commit()
db.execute('VACUUM')
print('Entries:', db.execute('SELECT COUNT(*) FROM entries').fetchone()[0])
print('Integrity:', db.execute('PRAGMA integrity_check').fetchone()[0])
db.close()
print('CSV SHA-256:', hashlib.sha256(source.read_bytes()).hexdigest())
print('Database SHA-256:', hashlib.sha256(target.read_bytes()).hexdigest())
