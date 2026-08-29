import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';
import '../../../core/ai/ai_service.dart';
import '../../../core/dictionary/dictionary_models.dart';
import '../../../core/dictionary/dictionary_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/text_normalization.dart';
import '../../../core/vocabulary/vocabulary_models.dart';
import '../../../core/vocabulary/vocabulary_repository.dart';

class WordExplanationSheet extends StatefulWidget {
  final String word;
  final String sentenceText;
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final AiService aiService;

  const WordExplanationSheet({
    super.key,
    required this.word,
    required this.sentenceText,
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    required this.aiService,
  });

  @override
  State<WordExplanationSheet> createState() => _WordExplanationSheetState();
}

class _WordExplanationSheetState extends State<WordExplanationSheet> {
  final FlutterTts _tts = FlutterTts();
  DictionaryEntry? _entry;
  bool _isLoading = true;
  bool _isSaved = false;
  String _aiTranslation = '';

  @override
  void initState() {
    super.initState();
    _loadWordInfo();
  }

  Future<void> _loadWordInfo() async {
    final clean = TextNormalization.normalizeWord(widget.word);
    final entry = await widget.dictionaryRepo.lookupWord(clean);
    final saved = await widget.vocabularyRepo.isWordSaved(clean);

    if (!mounted) return;
    setState(() {
      _entry = entry;
      _isSaved = saved;
      _isLoading = false;
    });

    if (widget.aiService.llmEngine.isLoaded) {
      _fetchAiTranslation(clean);
    }
  }

  Future<void> _fetchAiTranslation(String word) async {
    try {
      await for (final chunk in widget.aiService.translateText(word)) {
        if (mounted) {
          setState(() {
            _aiTranslation += chunk;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _toggleSave() async {
    final clean = TextNormalization.normalizeWord(widget.word);
    if (_isSaved) {
      final existing = await widget.vocabularyRepo.getWord(clean);
      if (existing != null) {
        await widget.vocabularyRepo.deleteWord(existing.id);
        if (mounted) {
          setState(() {
            _isSaved = false;
          });
        }
      }
    } else {
      final newWord = VocabularyWord(
        id: const Uuid().v4(),
        word: clean,
        phonetic: _entry?.phonetic,
        partOfSpeech: _entry?.partOfSpeech,
        definitionSnapshot: _entry?.definitions.isNotEmpty == true ? _entry!.definitions.first : 'Word from audio transcript',
        translationSnapshot: _entry?.chineseDefinitions.isNotEmpty == true ? _entry!.chineseDefinitions.first : _aiTranslation,
        source: 'Audio Transcript',
        sourceSentence: widget.sentenceText,
        dateAdded: DateTime.now(),
      );
      await widget.vocabularyRepo.saveWord(newWord);
      if (mounted) {
        setState(() {
          _isSaved = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cleanWord = TextNormalization.normalizeWord(widget.word);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(cleanWord, style: AppTypography.wordDisplay),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.volume_up, color: AppColors.primary),
                    onPressed: () => _speak(cleanWord),
                  ),
                ],
              ),
              IconButton(
                icon: Icon(
                  _isSaved ? Icons.star : Icons.star_border,
                  color: _isSaved ? Colors.amber : AppColors.textSecondary,
                  size: 28,
                ),
                onPressed: _toggleSave,
                tooltip: 'Save to Vocabulary',
              ),
            ],
          ),

          if (_entry?.phonetic != null && _entry!.phonetic.isNotEmpty)
            Text(_entry!.phonetic, style: AppTypography.phonetic),

          const SizedBox(height: 14),

          if (_isLoading)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
          else if (_entry != null) ...[
            // Offline Definition
            Text(
              _entry!.definitions.isNotEmpty ? _entry!.definitions.first : '',
              style: AppTypography.bodyMedium,
            ),
            if (_entry!.chineseDefinitions.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _entry!.chineseDefinitions.first,
                style: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ] else ...[
            Text('No offline dictionary entry for "$cleanWord".', style: AppTypography.bodySmall),
          ],

          // AI Translation / Explanation snippet if available
          if (_aiTranslation.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.translate, size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_aiTranslation, style: AppTypography.bodySmall.copyWith(color: AppColors.primary))),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _toggleSave,
              icon: Icon(_isSaved ? Icons.check : Icons.add),
              label: Text(_isSaved ? 'Saved in Vocabulary' : 'Save to Vocabulary'),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
