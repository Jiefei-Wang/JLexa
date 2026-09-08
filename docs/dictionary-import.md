# Dictionary Manager

Home → Quick Tools → **Dictionary Manager** lists ECDICT, JLexa Core, and
imported dictionaries. Checkboxes enable/disable lookup and suggestions.
Imported entries are shown first, with their dictionary name; existing enabled
built-in definitions are retained. Imported dictionaries can be deleted without
changing the original source file. Built-ins can be disabled, but not deleted.

**Import** uses Android's file picker. A private temporary copy is parsed in a
worker isolate, then indexed transactionally in a separate private SQLite
database. Failed imports leave the catalog and prior dictionaries unchanged.
Temporary copies are removed when the operation finishes. Lookups, suggestions,
and enabled states survive restart. Changes refresh an already open query.

Supported formats:

- **MDX 1.x / 2.x**: uncompressed or zlib blocks; UTF-8 and encodings supported by
  `dict_reader`. Encrypted=2 key metadata is supported; encrypted record content,
  MDX 3, and LZO compression are rejected. `@@@LINK=` aliases are resolved inside
  their originating dictionary with cycle/depth protection.
- **StarDict ZIP**: exactly one dictionary with matching `.ifo`, `.idx` or
  `.idx.gz`, `.dict` or `.dict.dz`, and optional `.syn`. Both 32- and 64-bit offsets
  are supported. Text fields and aliases are indexed; binary resources are not.
- **UTF-8 TXT / TSV**: one entry per line, `word@definition` (Eudic's documented
  source format) or `word<TAB>definition`. Literal `\n` and HTML `<br>` can express
  definition line breaks. Blank lines are ignored; malformed entries reject the
  entire import.

HTML definitions are converted to plain text. Scripts, CSS, links, and external
media are not executed or loaded. MDD resources and proprietary `.eudic` files
are not supported. The supported-formats dialog documents these limits.
The importer limits source/expanded data to 256 MB, one million entries, and
1 MB per definition. MDX block sizes/checksums and StarDict offsets/counts are
validated before the dictionary is made available.

Format references:

- [Eudic source text and MDX support](https://www.eudic.net/v4/en/home/EudicBuilder)
- [StarDict file format](https://github.com/huzheng001/stardict-3/blob/master/dict/doc/StarDictFileFormat)
- [dict_reader implementation and supported variants](https://github.com/mumu-lhl/dict_reader)

The small MDX metadata decode routine is adapted from `dict_reader` under its
MIT license. Its notice is included in `docs/licenses/dict_reader-MIT.txt` and
the application's Flutter license registry.
