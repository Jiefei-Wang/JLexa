import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/dictionary/dictionary_ai_parser.dart';
import '../../core/dictionary/dictionary_models.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/vocabulary/vocabulary_models.dart';
import '../../core/vocabulary/vocabulary_repository.dart';

class DictionaryController extends ChangeNotifier {
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final AiService aiService;
  final FlutterTts _tts = FlutterTts();

  int _queryGeneration = 0;
  int _searchGeneration = 0;
  int _aiGeneration = 0;
  bool _isSaving = false;

  String _currentQuery = '';
  DictionaryEntry? _currentEntry;
  bool _isSaved = false;
  bool _isLoading = false;
  List<String> _suggestions = [];
  int _selectedTab = 0; // 0: Dictionary, 1: AI Answer

  DictionaryAiAnswer? _aiAnswer;
  String? _aiErrorMessage;
  String _aiRawStreamingText = '';
  bool _isAiGenerating = false;
  AiGenerationHandle? _activeAiHandle;
  bool _isDisposed = false;

  String get currentQuery => _currentQuery;
  DictionaryEntry? get currentEntry => _currentEntry;
  bool get isSaved => _isSaved;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  List<String> get suggestions => _suggestions;
  int get selectedTab => _selectedTab;
  DictionaryAiAnswer? get aiAnswer => _aiAnswer;
  String? get aiErrorMessage => _aiErrorMessage;
  String get aiRawStreamingText => _aiRawStreamingText;
  bool get isAiGenerating => _isAiGenerating;

  DictionaryController({
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    required this.aiService,
    String initialWord = 'resilient',
  }) {
    _initTts();
    search(initialWord);
  }

  void _initTts() {
    try {
      _tts.setLanguage('en-US');
      _tts.setSpeechRate(0.45);
    } catch (_) {}
  }

  void setSelectedTab(int index) {
    if (_selectedTab != index) {
      if (_isAiGenerating) {
        _aiRawStreamingText = '';
      }
      ++_aiGeneration;
      _activeAiHandle?.cancel();
      _activeAiHandle = null;
      _isAiGenerating = false;
    }
    _selectedTab = index;
    final query = _currentEntry?.word ?? _currentQuery;
    if (_selectedTab == 1 && _aiAnswer == null && query.isNotEmpty) {
      _fetchAiAnswer();
    }
    notifyListeners();
  }

  Future<void> onQueryChanged(String query) async {
    if (query.trim().isEmpty) {
      await search('');
      ++_queryGeneration;
      _suggestions = [];
      notifyListeners();
      return;
    }

    final gen = ++_queryGeneration;
    final results = await dictionaryRepo.searchSuggestions(query.trim());
    if (gen != _queryGeneration || _isDisposed) return;

    _suggestions = results;
    notifyListeners();
  }

  Future<void> search(String word) async {
    final clean = word.trim().replaceAll(RegExp(r'\s+'), ' ');

    ++_queryGeneration; // Invalidate any pending suggestion queries
    final gen = ++_searchGeneration;
    ++_aiGeneration; // Invalidate any running AI requests
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    _isLoading = true;
    _currentQuery = clean;
    _currentEntry = null;
    _isSaved = false;
    _suggestions = [];
    _aiAnswer = null;
    _aiErrorMessage = null;
    _aiRawStreamingText = '';
    _isAiGenerating = false;
    notifyListeners();

    if (clean.isEmpty) {
      _isLoading = false;
      notifyListeners();
      return;
    }

    final entry = await dictionaryRepo.lookupWord(clean);
    if (gen != _searchGeneration || _isDisposed) return;

    bool saved = false;
    if (entry != null) {
      saved = await vocabularyRepo.isWordSaved(entry.word);
    } else {
      saved = await vocabularyRepo.isWordSaved(clean);
    }
    if (gen != _searchGeneration || _isDisposed) return;

    _currentEntry = entry;
    _isSaved = saved;
    _isLoading = false;
    notifyListeners();

    if (_selectedTab == 1) _fetchAiAnswer();
  }

  Future<void> speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> toggleSaveToVocabulary() async {
    final targetWord = _currentEntry?.word ?? _currentQuery;
    if (targetWord.isEmpty || _isSaving || _isLoading || _isDisposed) return;
    final searchGeneration = _searchGeneration;
    _isSaving = true;
    notifyListeners();

    try {
      if (_isSaved) {
        final existing = await vocabularyRepo.getWord(targetWord);
        if (existing != null) {
          await vocabularyRepo.deleteWord(existing.id);
          if (!_isDisposed && searchGeneration == _searchGeneration) {
            _isSaved = false;
          }
        }
      } else {
        String defSnap = '';
        String transSnap = '';
        String pos = _currentEntry?.partOfSpeech ?? '';

        if (_currentEntry != null) {
          defSnap = _currentEntry!.definitions.isNotEmpty
              ? _currentEntry!.definitions.first
              : '';
          transSnap = _currentEntry!.chineseDefinitions.isNotEmpty
              ? _currentEntry!.chineseDefinitions.first
              : '';
        }

        if (defSnap.isEmpty && transSnap.isEmpty && _aiAnswer != null) {
          final ans = _aiAnswer!;
          if (ans is DictionaryWordAnswer) {
            defSnap = ans.senses
                .map((s) => '${s.partOfSpeech} ${s.meaning}'.trim())
                .join('\n');
            transSnap = ans.senses.map((s) => s.meaning).join('；');
            if (pos.isEmpty && ans.senses.isNotEmpty) {
              pos = ans.senses.first.partOfSpeech;
            }
          } else if (ans is DictionaryPhraseAnswer) {
            defSnap = ans.explanation;
            transSnap = ans.explanation;
            if (pos.isEmpty) pos = 'phrase';
          }
        }

        if (defSnap.isEmpty && transSnap.isEmpty) {
          defSnap = targetWord;
        }

        final newWord = VocabularyWord(
          id: const Uuid().v4(),
          word: targetWord,
          phonetic: _currentEntry?.phonetic ?? '',
          partOfSpeech: pos,
          definitionSnapshot: defSnap,
          translationSnapshot: transSnap,
          source: 'Dictionary',
          sourceSentence: _currentEntry?.examples.isNotEmpty == true
              ? _currentEntry!.examples.first.english
              : null,
          dateAdded: DateTime.now(),
        );
        await vocabularyRepo.saveWord(newWord);
        if (!_isDisposed && searchGeneration == _searchGeneration) {
          _isSaved = true;
        }
      }
    } finally {
      if (!_isDisposed) {
        _isSaving = false;
        notifyListeners();
      }
    }
  }

  Future<void> _fetchAiAnswer() async {
    if (_isLoading || _isDisposed) return;
    final targetWord = _currentEntry?.word ?? _currentQuery;
    if (targetWord.isEmpty) return;

    final gen = ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    if (!aiService.llmEngine.isLoaded) {
      _aiAnswer = null;
      _aiErrorMessage = 'Load a local AI model in Settings to use AI Answer.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiAnswer = null;
    _aiErrorMessage = null;
    _aiRawStreamingText = '';
    notifyListeners();

    try {
      final handle = aiService.startDictionaryAiAnswer(
        targetWord,
        dictionaryContext: _currentEntry == null
            ? null
            : [
                ..._currentEntry!.chineseDefinitions.take(4),
              ].join('\n'),
      );
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiGeneration || _isDisposed) break;
        _aiRawStreamingText += chunk;
        notifyListeners();
      }

      if (gen == _aiGeneration && !_isDisposed) {
        _aiAnswer = DictionaryAiParser.parse(
          _aiRawStreamingText,
          query: targetWord,
        );
        _aiErrorMessage = null;
      }
    } on AiCancelledException {
      if (gen == _aiGeneration && !_isDisposed) {
        _aiRawStreamingText = '';
        _aiAnswer = null;
        _aiErrorMessage = null;
      }
    } catch (e) {
      if (gen == _aiGeneration && !_isDisposed) {
        if (e is AiCancelledException ||
            e.toString().contains('cancelled') ||
            e.toString().contains('canceled')) {
          _aiRawStreamingText = '';
          _aiAnswer = null;
          _aiErrorMessage = null;
        } else {
          _aiAnswer = null;
          _aiErrorMessage = 'AI Answer unavailable: $e';
        }
      }
    } finally {
      if (gen == _aiGeneration && !_isDisposed) {
        _isAiGenerating = false;
        _activeAiHandle = null;
        notifyListeners();
      }
    }
  }

  void cancelAiAnswer() {
    ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;
    _isAiGenerating = false;
    _aiRawStreamingText = '';
    notifyListeners();
  }

  Future<void> retryAiAnswer() => _fetchAiAnswer();

  Future<void> askAiAboutWord(String prompt) async {
    if (_isLoading || _isDisposed || _isAiGenerating) return;
    final targetWord = _currentEntry?.word ?? _currentQuery;
    if (targetWord.isEmpty) return;
    final gen = ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    _selectedTab = 1;

    if (!aiService.llmEngine.isLoaded) {
      _aiAnswer = null;
      _aiErrorMessage = 'Load a local AI model in Settings to use AI Answer.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiAnswer = null;
    _aiErrorMessage = null;
    _aiRawStreamingText = '';
    notifyListeners();

    try {
      final msgs = [
        const ChatMessagePayload(
          role: 'system',
          content: PromptBuilder.systemPrefix,
        ),
        ChatMessagePayload(
          role: 'user',
          content:
              'Word or phrase: "$targetWord"\nUser request: $prompt\nProvide a clear, concise educational explanation in Chinese.',
        ),
      ];
      final plainPrompt =
          'Word or phrase: $targetWord\nUser request: $prompt\nProvide a clear, concise educational explanation in Chinese.';

      final handle = aiService.llmEngine.startGeneration(
        plainPrompt,
        settings: aiService.settings,
        chatMessages: msgs,
      );
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiGeneration || _isDisposed) break;
        _aiRawStreamingText += chunk;
        notifyListeners();
      }

      if (gen == _aiGeneration && !_isDisposed) {
        _aiAnswer = DictionaryPhraseAnswer(
          explanation: _aiRawStreamingText.trim(),
        );
        _aiErrorMessage = null;
      }
    } on AiCancelledException {
      if (gen == _aiGeneration && !_isDisposed) {
        _aiRawStreamingText = '';
        _aiAnswer = null;
        _aiErrorMessage = null;
      }
    } catch (e) {
      if (gen == _aiGeneration && !_isDisposed) {
        if (e is AiCancelledException ||
            e.toString().contains('cancelled') ||
            e.toString().contains('canceled')) {
          _aiRawStreamingText = '';
          _aiAnswer = null;
          _aiErrorMessage = null;
        } else {
          _aiAnswer = null;
          _aiErrorMessage = 'AI explanation unavailable: $e';
        }
      }
    } finally {
      if (gen == _aiGeneration && !_isDisposed) {
        _isAiGenerating = false;
        _activeAiHandle = null;
        notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;
    _tts.stop();
    super.dispose();
  }
}
