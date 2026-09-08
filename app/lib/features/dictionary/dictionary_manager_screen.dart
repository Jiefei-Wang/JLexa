import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/dictionary/dictionary_repository.dart';
import '../../core/dictionary/dictionary_store.dart';

class DictionaryManagerScreen extends StatefulWidget {
  final DictionaryRepository dictionaryRepo;
  const DictionaryManagerScreen({super.key, required this.dictionaryRepo});
  @override
  State<DictionaryManagerScreen> createState() =>
      _DictionaryManagerScreenState();
}

class _DictionaryManagerScreenState extends State<DictionaryManagerScreen> {
  List<ManagedDictionary> _dictionaries = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _action(() async {});
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      final dictionaries = await widget.dictionaryRepo.managedDictionaries();
      if (mounted) setState(() => _dictionaries = dictionaries);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _action(() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) {
      throw const FormatException('Cannot read the selected file.');
    }
    final dictionary = await widget.dictionaryRepo.importDictionary(path);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Imported ${dictionary.name}')));
    }
  });

  Future<void> _delete(ManagedDictionary dictionary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${dictionary.name}?'),
        content: const Text('The original file will be kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _action(
        () => widget.dictionaryRepo.deleteDictionary(dictionary.id),
      );
    }
  }

  void _formats() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supported formats'),
      content: const SingleChildScrollView(
        child: Text(
          'MDX 1.x / 2.x: text definitions (uncompressed or zlib).\n'
          'StarDict: ZIP with matching .ifo, .idx / .idx.gz and .dict / .dict.dz; optional .syn.\n'
          'UTF-8 TXT / TSV: one word and definition per line, separated by @ or a tab.\n\n'
          'Up to 256 MB and 1,000,000 entries. HTML is displayed as text. '
          'MDD media, scripts, MDX LZO, encrypted records and proprietary EUDIC files are not supported.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Dictionary Manager'),
        actions: [
          IconButton(
            tooltip: 'Supported formats',
            onPressed: _formats,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Import'),
                  ),
                  if (_busy) ...[
                    const SizedBox(width: 16),
                    const Expanded(child: LinearProgressIndicator()),
                  ],
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _dictionaries.length,
                itemBuilder: (context, index) {
                  final dictionary = _dictionaries[index];
                  return ListTile(
                    leading: Checkbox(
                      value: dictionary.enabled,
                      onChanged: _busy
                          ? null
                          : (value) => _action(
                              () => widget.dictionaryRepo.setDictionaryEnabled(
                                dictionary.id,
                                value ?? false,
                              ),
                            ),
                    ),
                    title: Text(dictionary.name),
                    subtitle: Text(
                      '${dictionary.format} · ${dictionary.count} entries',
                    ),
                    trailing: dictionary.builtIn
                        ? null
                        : IconButton(
                            tooltip: 'Delete ${dictionary.name}',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _busy ? null : () => _delete(dictionary),
                          ),
                    onTap: _busy
                        ? null
                        : () => _action(
                            () => widget.dictionaryRepo.setDictionaryEnabled(
                              dictionary.id,
                              !dictionary.enabled,
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
