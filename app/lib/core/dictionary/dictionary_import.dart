import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:blockchain_utils/crypto/crypto/hash/hash.dart';
import 'package:dict_reader/dict_reader.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:path/path.dart' as p;

const dictionaryImportLimit = 256 * 1024 * 1024;

/// HTML is converted to text; dictionary scripts and remote resources never run.
String dictionaryPlainText(String value) {
  final document = parseFragment(value);
  document
      .querySelectorAll('script,style,iframe,object')
      .forEach((e) => e.remove());
  for (final element in document.querySelectorAll('br,p,div,li,tr,section')) {
    element.append(Text('\n'));
  }
  return (document.text ?? '')
      .replaceAll('\u0000', '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Runs in a worker isolate. Writes bounded JSON lines instead of transferring
/// an entire dictionary through the UI isolate's heap.
Future<Map<String, Object>> prepareDictionaryImport(
  String source,
  String destination,
) async {
  final file = File(source);
  if (await file.length() > dictionaryImportLimit) {
    throw const FormatException('Dictionary exceeds the 256 MB import limit.');
  }
  final extension = p.extension(source).toLowerCase();
  var name = p.basenameWithoutExtension(source);
  var format = extension.substring(extension.isEmpty ? 0 : 1).toUpperCase();
  final output = await File(destination).open(mode: FileMode.write);
  var count = 0;
  var total = 0;
  Future<void> add(String word, String definition, {bool html = true}) async {
    word = word.trim();
    definition = definition.trim();
    if (word.isEmpty || word.length > 512 || definition.isEmpty) {
      throw const FormatException(
        'Dictionary contains an empty or invalid entry.',
      );
    }
    final redirect = definition.startsWith('@@@LINK=')
        ? definition.substring(8).trim().toLowerCase()
        : null;
    final text = redirect == null && html
        ? dictionaryPlainText(definition)
        : definition;
    if (text.isEmpty) return; // Resource-only MDX records have no text to show.
    if (++count > 1000000 || text.length > 1024 * 1024) {
      throw const FormatException(
        'Dictionary entry count or size is too large.',
      );
    }
    final bytes = utf8.encode('${jsonEncode([word, text, redirect])}\n');
    total += bytes.length;
    if (total > dictionaryImportLimit) {
      throw const FormatException('Expanded dictionary exceeds 256 MB.');
    }
    await output.writeFrom(bytes);
  }

  try {
    if (extension == '.mdx') {
      // dict_reader allocates its header buffer from the file's first integer.
      // Bound it before asking the dependency to read any header content.
      final headerInput = await file.open();
      try {
        final prefix = await headerInput.read(4);
        final fileSize = await headerInput.length();
        if (prefix.length != 4) {
          throw const FormatException('Truncated MDX header.');
        }
        final headerSize = ByteData.sublistView(prefix).getUint32(0);
        if (headerSize < 2 ||
            headerSize > 1024 * 1024 ||
            headerSize > fileSize - 8) {
          throw const FormatException('Invalid or oversized MDX header.');
        }
      } finally {
        await headerInput.close();
      }
      final reader = DictReader(source);
      try {
        // Reject unsupported versions before reading any key/record blocks.
        await reader.initDict(readKeys: false, readRecordBlockInfo: false);
        final version = double.tryParse(
          reader.header['GeneratedByEngineVersion'] ?? '',
        );
        final encrypted = reader.header['Encrypted'] ?? '0';
        if (version == null ||
            !version.isFinite ||
            version < 1 ||
            version >= 3 ||
            !['0', 'No', '2'].contains(encrypted)) {
          throw const FormatException(
            'Unsupported MDX version or encryption. Use MDX 1.x/2.x with unencrypted records.',
          );
        }
        await _validateMdx(file, reader.header, version);
        await reader.initDict(readHeader: false);
        if (reader.numEntries > 1000000) {
          throw const FormatException(
            'Dictionary has more than 1,000,000 entries.',
          );
        }
        name = dictionaryPlainText(reader.header['Title'] ?? name);
        await for (final entry in reader.readWithMdxData()) {
          await add(entry.keyText, entry.data);
        }
      } finally {
        await reader.close();
      }
    } else if (extension == '.zip') {
      format = 'StarDict';
      final archive = ZipDecoder().decodeBytes(
        await file.readAsBytes(),
        verify: true,
      );
      var expanded = 0;
      final files = <String, ArchiveFile>{};
      for (final entry in archive.files.where((e) => e.isFile)) {
        expanded += entry.size;
        if (expanded > dictionaryImportLimit || files.containsKey(entry.name)) {
          throw const FormatException(
            'ZIP is too large or contains duplicate files.',
          );
        }
        files[entry.name] = entry;
      }
      final infos = files.keys.where((n) => n.endsWith('.ifo')).toList();
      if (infos.length != 1) {
        throw const FormatException(
          'Select a ZIP containing one StarDict dictionary (.ifo, .idx, .dict).',
        );
      }
      final info = utf8.decode(files[infos.single]!.content);
      if (!info.startsWith("StarDict's dict ifo file")) {
        throw const FormatException('Invalid StarDict .ifo header.');
      }
      final meta = <String, String>{};
      for (final line in const LineSplitter().convert(info)) {
        final at = line.indexOf('=');
        if (at > 0) meta[line.substring(0, at)] = line.substring(at + 1).trim();
      }
      if (!['2.4.2', '3.0.0'].contains(meta['version'])) {
        throw const FormatException('Unsupported StarDict version.');
      }
      final base = infos.single.substring(0, infos.single.length - 4);
      Uint8List component(String suffix, [String? compressed]) {
        final raw = files['$base$suffix'];
        if (raw != null) return Uint8List.fromList(raw.content);
        final zipped = files['$base$compressed'];
        if (compressed != null && zipped != null) {
          // Bound gzip inflation while decoding, including dictzip members.
          final sink = _BoundedBytes();
          final decoder = gzip.decoder.startChunkedConversion(sink);
          decoder.add(zipped.content);
          decoder.close();
          return sink.bytes.takeBytes();
        }
        throw FormatException('StarDict is missing $suffix.');
      }

      final index = component('.idx', '.idx.gz');
      final data = component('.dict', '.dict.dz');
      final bits = meta['idxoffsetbits'] ?? '32';
      if (!['32', '64'].contains(bits) ||
          int.tryParse(meta['idxfilesize'] ?? '') != index.length) {
        throw const FormatException(
          'Invalid StarDict index size or offset width.',
        );
      }
      final offsetWidth = bits == '64' ? 8 : 4;
      final indexView = ByteData.sublistView(index);
      final entries = <(String, int, int)>[];
      var cursor = 0;
      while (cursor < index.length) {
        final end = index.indexOf(0, cursor);
        if (end < 0 || end + 1 + offsetWidth + 4 > index.length) {
          throw const FormatException('Truncated StarDict index.');
        }
        final word = utf8.decode(index.sublist(cursor, end));
        cursor = end + 1;
        final offset = offsetWidth == 8
            ? indexView.getUint64(cursor)
            : indexView.getUint32(cursor);
        cursor += offsetWidth;
        final length = indexView.getUint32(cursor);
        cursor += 4;
        if (offset < 0 || offset + length > data.length) {
          throw const FormatException(
            'StarDict entry points outside the dictionary.',
          );
        }
        entries.add((word, offset, length));
        if (entries.length > 1000000) {
          throw const FormatException('Too many dictionary entries.');
        }
        final definition = _starDefinition(
          Uint8List.sublistView(data, offset, offset + length),
          meta['sametypesequence'],
        );
        if (definition.isNotEmpty) await add(word, definition, html: false);
      }
      if (int.tryParse(meta['wordcount'] ?? '') != entries.length) {
        throw const FormatException(
          'StarDict word count does not match its index.',
        );
      }
      final synonyms = files['$base.syn'];
      if (synonyms == null &&
          (int.tryParse(meta['synwordcount'] ?? '0') ?? -1) != 0) {
        throw const FormatException(
          'StarDict is missing its declared .syn file.',
        );
      }
      if (synonyms != null) {
        final syn = Uint8List.fromList(synonyms.content);
        final view = ByteData.sublistView(syn);
        cursor = 0;
        var synCount = 0;
        while (cursor < syn.length) {
          final end = syn.indexOf(0, cursor);
          if (end < 0 || end + 5 > syn.length) {
            throw const FormatException('Invalid StarDict synonyms.');
          }
          final word = utf8.decode(syn.sublist(cursor, end));
          final target = view.getUint32(end + 1);
          if (target >= entries.length) {
            throw const FormatException('Invalid StarDict synonym target.');
          }
          await add(word, '@@@LINK=${entries[target].$1}');
          cursor = end + 5;
          synCount++;
        }
        if (int.tryParse(meta['synwordcount'] ?? '') != synCount) {
          throw const FormatException('StarDict synonym count mismatch.');
        }
      }
      name = dictionaryPlainText(meta['bookname'] ?? name);
    } else if (['.txt', '.tsv'].contains(extension)) {
      format = extension == '.tsv' ? 'TSV' : 'Text';
      var lineNumber = 0;
      await for (var line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        lineNumber++;
        if (lineNumber == 1) line = line.replaceFirst('\ufeff', '');
        if (line.trim().isEmpty) continue;
        final tab = line.indexOf('\t');
        final separator = tab >= 0 ? tab : line.indexOf('@');
        if (separator < 1) {
          throw FormatException(
            'Line $lineNumber: expected word<TAB>definition or word@definition.',
          );
        }
        await add(
          line.substring(0, separator),
          line.substring(separator + 1).replaceAll(r'\n', '\n'),
        );
      }
    } else {
      throw const FormatException(
        'Supported: MDX, StarDict ZIP, UTF-8 TXT and TSV. MDD resources and proprietary EUDIC files are not supported.',
      );
    }
    if (count == 0) {
      throw const FormatException(
        'Dictionary contains no readable definitions.',
      );
    }
    return {
      'name': name.isEmpty ? p.basename(source) : name,
      'format': format,
      'count': count,
    };
  } catch (error) {
    if (error is FormatException) rethrow;
    throw FormatException(
      'Cannot read this dictionary. It may be corrupt or use unsupported compression (MDX LZO is not supported). $error',
    );
  } finally {
    await output.close();
  }
}

String _starDefinition(Uint8List bytes, String? sequence) {
  final result = <String>[];
  var cursor = 0;
  var field = 0;
  while (cursor < bytes.length) {
    final type = sequence == null || sequence.isEmpty
        ? String.fromCharCode(bytes[cursor++])
        : sequence[field++];
    final last =
        sequence != null && sequence.isNotEmpty && field == sequence.length;
    final textType = RegExp(r'^[a-z]$').hasMatch(type);
    int end;
    if (last) {
      end = bytes.length;
    } else if (textType) {
      end = bytes.indexOf(0, cursor);
      if (end < 0) throw const FormatException('Unterminated StarDict field.');
    } else if (RegExp(r'^[A-Z]$').hasMatch(type)) {
      if (cursor + 4 > bytes.length) {
        throw const FormatException('Truncated StarDict field.');
      }
      final size = ByteData.sublistView(bytes).getUint32(cursor);
      cursor += 4;
      end = cursor + size;
    } else {
      throw const FormatException('Invalid StarDict field type.');
    }
    if (end > bytes.length) {
      throw const FormatException('Truncated StarDict definition.');
    }
    if (textType && type != 'r') {
      final value = utf8.decode(bytes.sublist(cursor, end));
      result.add(
        ['h', 'x', 'g', 'k'].contains(type)
            ? dictionaryPlainText(value)
            : value,
      );
    }
    cursor = end + (!last && textType ? 1 : 0);
  }
  if (sequence != null && sequence.isNotEmpty && field != sequence.length) {
    throw const FormatException('Missing StarDict fields.');
  }
  return result.join('\n').trim();
}

class _BoundedBytes implements Sink<List<int>> {
  final int limit;
  _BoundedBytes({this.limit = dictionaryImportLimit});
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('Expanded dictionary exceeds 256 MB.');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

/// Preflight every compressed block before dict_reader decodes it, because its
/// decoder does not impose output limits or validate declared block sizes.
Future<void> _validateMdx(
  File file,
  Map<String, String> header,
  double version,
) async {
  final input = await file.open();
  final size = await input.length();
  final width = version >= 2 ? 8 : 4;
  var expanded = 0;
  Future<Uint8List> read(int count) async {
    if (count < 0 ||
        count > dictionaryImportLimit ||
        await input.position() + count > size) {
      throw const FormatException('Truncated or oversized MDX block.');
    }
    final bytes = await input.read(count);
    if (bytes.length != count) {
      throw const FormatException('Truncated MDX block.');
    }
    return bytes;
  }

  int number(Uint8List bytes, int offset, [int? byteWidth]) {
    final w = byteWidth ?? width;
    if (offset < 0 || offset + w > bytes.length) {
      throw const FormatException('Truncated MDX metadata.');
    }
    final view = ByteData.sublistView(bytes);
    final value = w == 8
        ? view.getUint64(offset)
        : w == 4
        ? view.getUint32(offset)
        : w == 2
        ? view.getUint16(offset)
        : bytes[offset];
    if (value < 0) throw const FormatException('Invalid MDX size.');
    return value;
  }

  Uint8List decode(Uint8List block, int expected) {
    if (block.length < 8 || expected < 0 || expected > dictionaryImportLimit) {
      throw const FormatException('Invalid MDX block size.');
    }
    Uint8List data;
    if (block[0] == 0) {
      data = Uint8List.sublistView(block, 8);
    } else if (block[0] == 2) {
      final sink = _BoundedBytes(limit: expected);
      final decoder = zlib.decoder.startChunkedConversion(sink);
      decoder.add(Uint8List.sublistView(block, 8));
      decoder.close();
      data = sink.bytes.takeBytes();
    } else {
      throw const FormatException(
        'Unsupported MDX compression. LZO is not supported.',
      );
    }
    expanded += data.length;
    if (data.length != expected || expanded > dictionaryImportLimit) {
      throw const FormatException('Invalid or oversized expanded MDX block.');
    }
    var a = 1;
    var b = 0;
    for (final byte in data) {
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    if (((b << 16) | a) != number(block, 4, 4)) {
      throw const FormatException('MDX block checksum mismatch.');
    }
    return data;
  }

  try {
    final headerSize = number(await read(4), 0, 4);
    if (headerSize > 1024 * 1024) {
      throw const FormatException('MDX header exceeds 1 MB.');
    }
    await read(headerSize + 4);
    final keyHeader = await read(
      width * (version >= 2 ? 5 : 4) + (version >= 2 ? 4 : 0),
    );
    final keyBlocks = number(keyHeader, 0);
    final entries = number(keyHeader, width);
    final infoSize = number(keyHeader, width * (version >= 2 ? 3 : 2));
    final keysSize = number(keyHeader, width * (version >= 2 ? 4 : 3));
    if (entries < 1 ||
        entries > 1000000 ||
        keyBlocks < 1 ||
        keyBlocks > entries) {
      throw const FormatException('Invalid MDX entry or block count.');
    }
    final rawInfo = await read(infoSize);
    if (header['Encrypted'] == '2') {
      if (version < 2 || rawInfo.length < 8) {
        throw const FormatException('Invalid encrypted MDX key metadata.');
      }
      _unscrambleMdxMetadata(rawInfo);
    }
    final info = version >= 2
        ? decode(rawInfo, number(keyHeader, width * 2))
        : rawInfo;
    final blockSizes = <(int, int, int)>[];
    var cursor = 0;
    var declaredEntries = 0;
    var declaredKeyBytes = 0;
    final textWidth =
        (header['Encoding'] ?? '')
            .toUpperCase()
            .replaceAll('-', '')
            .startsWith('UTF16')
        ? 2
        : 1;
    final lengthWidth = version >= 2 ? 2 : 1;
    for (var block = 0; block < keyBlocks; block++) {
      final count = number(info, cursor);
      cursor += width;
      for (var edge = 0; edge < 2; edge++) {
        final length = number(info, cursor, lengthWidth);
        cursor += lengthWidth + (length + (version >= 2 ? 1 : 0)) * textWidth;
      }
      final compressed = number(info, cursor);
      final decompressed = number(info, cursor + width);
      cursor += width * 2;
      declaredEntries += count;
      declaredKeyBytes += compressed;
      blockSizes.add((compressed, decompressed, count));
    }
    if (cursor != info.length ||
        declaredEntries != entries ||
        declaredKeyBytes != keysSize) {
      throw const FormatException('MDX key metadata count or size mismatch.');
    }
    for (final block in blockSizes) {
      final data = decode(await read(block.$1), block.$2);
      var at = 0;
      var actualEntries = 0;
      while (at < data.length) {
        at += width;
        if (at >= data.length) {
          throw const FormatException('Truncated MDX key.');
        }
        while (at + textWidth <= data.length &&
            (data[at] != 0 || (textWidth == 2 && data[at + 1] != 0))) {
          at += textWidth;
        }
        if (at + textWidth > data.length) {
          throw const FormatException('Unterminated MDX key.');
        }
        at += textWidth;
        actualEntries++;
      }
      if (actualEntries != block.$3) {
        throw const FormatException('MDX key count mismatch.');
      }
    }
    final recordHeader = await read(width * 4);
    final recordBlocks = number(recordHeader, 0);
    final recordEntries = number(recordHeader, width);
    final recordInfoSize = number(recordHeader, width * 2);
    final recordSize = number(recordHeader, width * 3);
    if (recordBlocks < 1 ||
        recordBlocks > 1000000 ||
        recordEntries != entries ||
        recordInfoSize != recordBlocks * width * 2) {
      throw const FormatException('Invalid MDX record metadata.');
    }
    final recordInfo = await read(recordInfoSize);
    var actualSize = 0;
    for (var block = 0; block < recordBlocks; block++) {
      final compressed = number(recordInfo, block * width * 2);
      final decompressed = number(recordInfo, block * width * 2 + width);
      decode(await read(compressed), decompressed);
      actualSize += compressed;
    }
    if (actualSize != recordSize || await input.position() != size) {
      throw const FormatException('MDX record size mismatch.');
    }
  } finally {
    await input.close();
  }
}

// MDict metadata scrambling, matching dict_reader (MIT, copyright 2024
// Mumulhl). Full notice is in docs/licenses/dict_reader-MIT.txt.
void _unscrambleMdxMetadata(Uint8List block) {
  final digest = RIPEMD128.hash([...block.sublist(4, 8), 149, 54, 0, 0]);
  var previous = 0x36;
  for (var offset = 8; offset < block.length; offset++) {
    final index = offset - 8;
    final encoded = block[offset];
    final swapped = ((encoded >> 4) | (encoded << 4)) & 0xff;
    block[offset] =
        swapped ^ previous ^ (index & 0xff) ^ digest[index % digest.length];
    previous = encoded;
  }
}
