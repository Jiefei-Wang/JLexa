import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:blockchain_utils/crypto/crypto/hash/hash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/dictionary/dictionary_import.dart';

List<int> _number(int value, int width, {Endian endian = Endian.big}) {
  final data = ByteData(width);
  switch (width) {
    case 1:
      data.setUint8(0, value);
    case 2:
      data.setUint16(0, value, endian);
    case 4:
      data.setUint32(0, value, endian);
    case 8:
      data.setUint64(0, value, endian);
  }
  return data.buffer.asUint8List();
}

List<int> _zip(Map<String, List<int>> parts) {
  final archive = Archive();
  for (final entry in parts.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

Map<String, List<int>> _star({
  int bits = 32,
  bool compressed = false,
  bool synonyms = true,
  Map<String, String> meta = const {},
  List<int>? index,
  List<int>? definition,
}) {
  final data = definition ?? utf8.encode('<b>A fruit</b>');
  final idx =
      index ??
      [
        ...utf8.encode('apple'),
        0,
        ..._number(0, bits ~/ 8),
        ..._number(data.length, 4),
      ];
  final metadata = {
    'version': bits == 64 ? '3.0.0' : '2.4.2',
    'wordcount': '1',
    'bookname': 'Test <b>Dictionary</b>',
    'idxoffsetbits': '$bits',
    'idxfilesize': '${idx.length}',
    'sametypesequence': 'h',
    if (synonyms) 'synwordcount': '1',
    ...meta,
  };
  return {
    'folder/test.ifo': utf8.encode(
      "StarDict's dict ifo file\n${metadata.entries.map((e) => '${e.key}=${e.value}').join('\n')}\n",
    ),
    'folder/test${compressed ? '.idx.gz' : '.idx'}': compressed
        ? gzip.encode(idx)
        : idx,
    'folder/test${compressed ? '.dict.dz' : '.dict'}': compressed
        ? _dictzip(data)
        : data,
    if (synonyms)
      'folder/test.syn': [...utf8.encode('apples'), 0, ..._number(0, 4)],
  };
}

// One-chunk dictzip stream: ordinary gzip with the RA random-access extra field.
List<int> _dictzip(List<int> data) {
  final gz = gzip.encode(data);
  final compressedLength = gz.length - 18;
  final extra = [
    82,
    65,
    ..._number(8, 2, endian: Endian.little),
    ..._number(1, 2, endian: Endian.little),
    ..._number(58315, 2, endian: Endian.little),
    ..._number(1, 2, endian: Endian.little),
    ..._number(compressedLength, 2, endian: Endian.little),
  ];
  return [
    ...gz.sublist(0, 3),
    4,
    ...gz.sublist(4, 10),
    ..._number(extra.length, 2, endian: Endian.little),
    ...extra,
    ...gz.sublist(10),
  ];
}

int _adler(List<int> data) {
  var a = 1;
  var b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

List<int> _mdxBlock(List<int> data, {int method = 2}) => [
  method,
  0,
  0,
  0,
  ..._number(_adler(data), 4),
  ...method == 0 ? data : zlib.encode(data),
];

// Self-authored MDX with one key block and one record block.
List<int> _mdx({
  String version = '2.0',
  String encryption = '0',
  int count = 2,
  int method = 2,
  String firstWord = 'Alpha',
  String secondWord = 'Beta',
}) {
  final v2 = double.parse(version) >= 2;
  final width = v2 ? 8 : 4;
  final headerText =
      '<Dictionary GeneratedByEngineVersion="$version" RequiredEngineVersion="$version" Encoding="UTF-8" Encrypted="$encryption" Title="QA MDX"/>\u0000';
  final header = headerText.codeUnits
      .expand((n) => _number(n, 2, endian: Endian.little))
      .toList();
  final firstRecord = utf8.encode('<p>First definition</p>\u0000');
  final records = [...firstRecord, ...utf8.encode('@@@LINK=$firstWord\u0000')];
  final firstKey = utf8.encode(firstWord);
  final secondKey = utf8.encode(secondWord);
  final keyRaw = [
    ..._number(0, width),
    ...firstKey,
    0,
    ..._number(firstRecord.length, width),
    ...secondKey,
    0,
  ];
  final keyBlock = _mdxBlock(keyRaw, method: method);
  final infoRaw = [
    ..._number(2, width),
    ..._number(firstKey.length, v2 ? 2 : 1),
    ...firstKey,
    if (v2) 0,
    ..._number(secondKey.length, v2 ? 2 : 1),
    ...secondKey,
    if (v2) 0,
    ..._number(keyBlock.length, width),
    ..._number(keyRaw.length, width),
  ];
  final infoBlock = v2 ? _mdxBlock(infoRaw) : infoRaw;
  if (encryption == '2') {
    final digest = RIPEMD128.hash([...infoBlock.sublist(4, 8), 149, 54, 0, 0]);
    var previous = 0x36;
    for (var offset = 8; offset < infoBlock.length; offset++) {
      final i = offset - 8;
      final raw =
          infoBlock[offset] ^ previous ^ (i & 0xff) ^ digest[i % digest.length];
      infoBlock[offset] = ((raw >> 4) | (raw << 4)) & 0xff;
      previous = infoBlock[offset];
    }
  }
  final keyHeader = [
    ..._number(1, width),
    ..._number(count, width),
    if (v2) ..._number(infoRaw.length, width),
    ..._number(infoBlock.length, width),
    ..._number(keyBlock.length, width),
  ];
  final recordBlock = _mdxBlock(records, method: method);
  return [
    ..._number(header.length, 4),
    ...header,
    ..._number(_adler(header), 4, endian: Endian.little),
    ...keyHeader,
    if (v2) ..._number(_adler(keyHeader), 4),
    ...infoBlock,
    ...keyBlock,
    ..._number(1, width),
    ..._number(count, width),
    ..._number(width * 2, width),
    ..._number(recordBlock.length, width),
    ..._number(recordBlock.length, width),
    ..._number(records.length, width),
    ...recordBlock,
  ];
}

void main() {
  late Directory temp;
  var serial = 0;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp(
      'jlexa_dictionary_import_',
    ),
  );
  tearDown(() async => temp.delete(recursive: true));

  Future<(Map<String, Object>, List<List<dynamic>>)> read(
    String extension,
    List<int> bytes,
  ) async {
    final source = File('${temp.path}/sample${serial++}.$extension');
    await source.writeAsBytes(bytes);
    final destination = '${source.path}.jsonl';
    final info = await prepareDictionaryImport(source.path, destination);
    final rows = (await File(
      destination,
    ).readAsLines()).map((s) => jsonDecode(s) as List<dynamic>).toList();
    return (info, rows);
  }

  test(
    'HTML strips executable/resource content and preserves readable boundaries',
    () {
      expect(
        dictionaryPlainText(
          '<p>one &amp; two</p><div>three<br>four</div><script>bad()</script><style>bad</style><iframe>bad</iframe><object>bad</object>',
        ),
        'one & two\nthree\nfour',
      );
    },
  );

  test(
    'UTF-8 TSV preserves unicode, BOM, escaped newlines and redirects',
    () async {
      final (info, rows) = await read(
        'tsv',
        utf8.encode(
          '\ufeff apple\t<p>苹果</p>\\nfruit\n\nAlias\t@@@LINK=Apple\n',
        ),
      );
      expect(info['format'], 'TSV');
      expect(info['count'], 2);
      expect(rows, [
        ['apple', '苹果\n\nfruit', null],
        ['Alias', '@@@LINK=Apple', 'apple'],
      ]);
    },
  );

  test(
    'Eudic-style TXT uses first @ separator and allows @ in definition',
    () async {
      final (info, rows) = await read(
        'txt',
        utf8.encode('email@Contact a@b.test\nterm\t<b>meaning</b>\n'),
      );
      expect(info['format'], 'Text');
      expect(rows, [
        ['email', 'Contact a@b.test', null],
        ['term', 'meaning', null],
      ]);
    },
  );

  for (final text in [
    'missing separator',
    '@missing word',
    'word\t',
    'word\t<img src="missing.png">',
    '\n\n',
  ]) {
    test('rejects malformed or empty text ${text.length}', () async {
      await expectLater(read('txt', utf8.encode(text)), throwsFormatException);
    });
  }

  test('rejects invalid UTF-8 and overlong entries', () async {
    await expectLater(read('tsv', [97, 9, 255]), throwsFormatException);
    await expectLater(
      read('txt', utf8.encode('${'a' * 513}@meaning')),
      throwsFormatException,
    );
    await expectLater(
      read('txt', utf8.encode('term@${'x' * (1024 * 1024 + 1)}')),
      throwsFormatException,
    );
  });

  test(
    'rejects source larger than import limit before reading content',
    () async {
      final source = File('${temp.path}/oversized.tsv');
      final handle = await source.open(mode: FileMode.write);
      await handle.truncate(dictionaryImportLimit + 1);
      await handle.close();
      await expectLater(
        prepareDictionaryImport(source.path, '${temp.path}/out'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('256 MB'),
          ),
        ),
      );
      expect(File('${temp.path}/out').existsSync(), false);
    },
  );

  for (final bits in [32, 64]) {
    for (final compressed in [false, true]) {
      test(
        'StarDict $bits-bit ${compressed ? 'gzip index and dictzip' : 'plain'} with synonyms',
        () async {
          final (info, rows) = await read(
            'zip',
            _zip(_star(bits: bits, compressed: compressed)),
          );
          expect(info, {
            'name': 'Test Dictionary',
            'format': 'StarDict',
            'count': 2,
          });
          expect(rows, [
            ['apple', 'A fruit', null],
            ['apples', '@@@LINK=apple', 'apple'],
          ]);
        },
      );
    }
  }

  test(
    'StarDict explicit field types combine plain text and HTML and skip binary',
    () async {
      final parts = _star(
        synonyms: false,
        meta: {'sametypesequence': ''},
        definition: [
          109,
          ...utf8.encode('plain <literal>'),
          0,
          104,
          ...utf8.encode('<b>bold</b>'),
          0,
          87,
          ..._number(3, 4),
          1,
          2,
          3,
        ],
      );
      final (_, rows) = await read('zip', _zip(parts));
      expect(rows.single[1], 'plain <literal>\nbold');
    },
  );

  for (final metadata in [
    {'wordcount': '2'},
    {'idxfilesize': '1'},
    {'idxoffsetbits': '16'},
    {'version': '9.0'},
    {'synwordcount': '2'},
    {'sametypesequence': 'hh'},
  ]) {
    test('StarDict rejects corrupt metadata $metadata', () async {
      await expectLater(
        read('zip', _zip(_star(meta: metadata))),
        throwsFormatException,
      );
    });
  }

  test('StarDict rejects truncated indexes and out-of-range offsets', () async {
    for (final index in [
      utf8.encode('unterminated'),
      [...utf8.encode('apple'), 0, 1],
      [...utf8.encode('apple'), 0, ..._number(999, 4), ..._number(10, 4)],
    ]) {
      await expectLater(
        read('zip', _zip(_star(index: index))),
        throwsFormatException,
      );
    }
  });

  test('StarDict rejects corrupt synonyms and missing components', () async {
    for (final syn in [
      [97, 0, 1],
      [97, 0, ..._number(5, 4)],
    ]) {
      final parts = _star()..['folder/test.syn'] = syn;
      await expectLater(read('zip', _zip(parts)), throwsFormatException);
    }
    for (final missing in [
      'folder/test.ifo',
      'folder/test.idx',
      'folder/test.dict',
    ]) {
      final parts = _star()..remove(missing);
      await expectLater(read('zip', _zip(parts)), throwsFormatException);
    }
  });

  test('StarDict rejects missing declared synonym file', () async {
    final parts = _star()..remove('folder/test.syn');
    await expectLater(read('zip', _zip(parts)), throwsFormatException);
  });

  test('StarDict refuses multiple dictionaries and truncated ZIP', () async {
    final parts = _star()
      ..['other.ifo'] = utf8.encode("StarDict's dict ifo file");
    await expectLater(read('zip', _zip(parts)), throwsFormatException);
    await expectLater(read('zip', [80, 75, 3]), throwsFormatException);
  });

  for (final method in [0, 2]) {
    test(
      'MDX v2 ${method == 0 ? 'plain' : 'zlib'} imports real binary key/record blocks',
      () async {
        final (info, rows) = await read('mdx', _mdx(method: method));
        expect(info, {'name': 'QA MDX', 'format': 'MDX', 'count': 2});
        expect(rows, [
          ['Alpha', 'First definition', null],
          ['Beta', '@@@LINK=Alpha', 'alpha'],
        ]);
      },
    );
  }

  test('MDX rejects unsupported version, encryption and compression', () async {
    await expectLater(read('mdx', _mdx(version: '3.0')), throwsFormatException);
    await expectLater(
      read('mdx', _mdx(encryption: '1')),
      throwsFormatException,
    );
    await expectLater(read('mdx', _mdx(method: 1)), throwsFormatException);
    await expectLater(
      read('mdx', _mdx().sublist(0, 120)),
      throwsFormatException,
    );
  });

  test('MDX rejects inconsistent declared counts', () async {
    await expectLater(read('mdx', _mdx(count: 3)), throwsFormatException);
  });

  test('MDX v2 supports common Encrypted=2 key metadata scrambling', () async {
    final (_, rows) = await read('mdx', _mdx(encryption: '2'));
    expect(rows.first, ['Alpha', 'First definition', null]);
    expect(rows.last, ['Beta', '@@@LINK=Alpha', 'alpha']);
  });

  test(
    'MDX rejects unbounded or truncated headers before reader allocation',
    () async {
      for (final size in [0, 1, 1024 * 1024 + 1, 0xffffffff, 500]) {
        await expectLater(
          read('mdx', [..._number(size, 4), 0, 0, 0, 0]),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('MDX header'),
            ),
          ),
        );
      }
      await expectLater(read('mdx', [0, 0, 0]), throwsFormatException);
    },
  );

  test('MDX rejects oversized declared blocks and entry counts', () async {
    final fixture = Uint8List.fromList(_mdx());
    final view = ByteData.sublistView(fixture);
    final keyHeader = view.getUint32(0) + 8;
    view.setUint64(keyHeader + 16, dictionaryImportLimit + 1);
    await expectLater(read('mdx', fixture), throwsFormatException);
    await expectLater(read('mdx', _mdx(count: 1000001)), throwsFormatException);
  });

  test('MDX checks actual inflation size and checksum', () async {
    final fixture = Uint8List.fromList(_mdx());
    final view = ByteData.sublistView(fixture);
    final keyHeader = view.getUint32(0) + 8;
    final infoRawSize = view.getUint64(keyHeader + 16);
    view.setUint64(keyHeader + 16, infoRawSize - 1);
    await expectLater(read('mdx', fixture), throwsFormatException);
    final checksumFixture = Uint8List.fromList(_mdx());
    checksumFixture[keyHeader + 44 + 4] ^= 1;
    await expectLater(read('mdx', checksumFixture), throwsFormatException);
  });

  test('MDX v1.2 uses 32-bit sections and uncompressed key metadata', () async {
    final (_, rows) = await read('mdx', _mdx(version: '1.2'));
    expect(rows.first, ['Alpha', 'First definition', null]);
  });

  test('unsupported dictionary formats fail explicitly', () async {
    for (final extension in ['eudic', 'mdd', 'ifo', 'pdf']) {
      await expectLater(
        read(extension, [1]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Supported:'),
          ),
        ),
      );
    }
  });
}
