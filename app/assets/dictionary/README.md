# Bundled learner dictionary

57,961 entries selected from [ECDICT](https://github.com/skywind3000/ECDICT),
commit `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`, under the included MIT license.
Selection: an entry has BNC/FRQ corpus frequency, an exam tag, or Oxford core status,
and a nonempty Chinese translation. This is a learner subset, not the full ECDICT.
Original definitions, translations and phonetics are retained; literal newline
escapes are decoded and frequency-weighted POS labels are simplified.

Rebuild using `python scripts/build_dictionary.py path/to/ecdict.csv`.
Source CSV SHA-256: `1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf`.
Generated database SHA-256: `34115fc72e62145fad031f861c6c221833b576b42b4c666360d511b731ae3972`.

The database is immutable and versioned separately from personal lessons and vocabulary.
Existing curated entries take precedence to retain their examples and synonyms.
