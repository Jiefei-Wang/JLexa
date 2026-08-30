import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/dictionary/dictionary_models.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/utils/text_normalization.dart';
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
  int _selectedTab = 0; // 0: Dictionary, 1: AI Translation, 2: AI Explanation

  String _aiTranslationText = '';
  String _aiExplanationText = '';
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
  String get aiTranslationText => _aiTranslationText;
  String get aiExplanationText => _aiExplanationText;
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
      _activeAiHandle?.cancel();
      _activeAiHandle = null;
    }
    _selectedTab = index;
    if (_selectedTab == 1 &&
        _aiTranslationText.isEmpty &&
        _currentEntry != null) {
      _fetchAiTranslation();
    } else if (_selectedTab == 2 &&
        _aiExplanationText.isEmpty &&
        _currentEntry != null) {
      _fetchAiExplanation();
    }
    notifyListeners();
  }

  Future<void> onQueryChanged(String query) async {
    _currentQuery = query;
    if (query.trim().isEmpty) {
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
    final clean = TextNormalization.normalizeWord(word);
    if (clean.isEmpty) return;

    ++_queryGeneration; // Invalidate any pending suggestion queries
    final gen = ++_searchGeneration;
    ++_aiGeneration; // Invalidate any running AI requests
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    _isLoading = true;
    _currentQuery = clean;
    _suggestions = [];
    _aiTranslationText = '';
    _aiExplanationText = '';
    _isAiGenerating = false;
    notifyListeners();

    final entry = await dictionaryRepo.lookupWord(clean);
    if (gen != _searchGeneration || _isDisposed) return;

    bool saved = false;
    if (entry != null) {
      saved = await vocabularyRepo.isWordSaved(entry.word);
    }
    if (gen != _searchGeneration || _isDisposed) return;

    _currentEntry = entry;
    _isSaved = saved;
    _isLoading = false;
    notifyListeners();

    if (_selectedTab == 1) _fetchAiTranslation();
    if (_selectedTab == 2) _fetchAiExplanation();
  }

  Future<void> speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> toggleSaveToVocabulary() async {
    final targetEntry = _currentEntry;
    if (targetEntry == null || _isSaving || _isDisposed) return;
    _isSaving = true;

    try {
      if (_isSaved) {
        final existing = await vocabularyRepo.getWord(targetEntry.word);
        if (existing != null) {
          await vocabularyRepo.deleteWord(existing.id);
          if (_currentEntry?.word == targetEntry.word && !_isDisposed) {
            _isSaved = false;
          }
        }
      } else {
        final newWord = VocabularyWord(
          id: const Uuid().v4(),
          word: targetEntry.word,
          phonetic: targetEntry.phonetic,
          partOfSpeech: targetEntry.partOfSpeech,
          definitionSnapshot: targetEntry.definitions.isNotEmpty
              ? targetEntry.definitions.first
              : '',
          translationSnapshot: targetEntry.chineseDefinitions.isNotEmpty
              ? targetEntry.chineseDefinitions.first
              : '',
          source: 'Dictionary',
          sourceSentence: targetEntry.examples.isNotEmpty
              ? targetEntry.examples.first.english
              : null,
          dateAdded: DateTime.now(),
        );
        await vocabularyRepo.saveWord(newWord);
        if (_currentEntry?.word == targetEntry.word && !_isDisposed) {
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

  Future<void> _fetchAiTranslation() async {
    if (_currentEntry == null) return;
    final targetWord = _currentEntry!.word;
    final gen = ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    if (!aiService.llmEngine.isLoaded) {
      _aiTranslationText =
          'Load a local AI model in Settings to use AI translation.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiTranslationText = '';
    notifyListeners();

    try {
      final handle = aiService.startTranslateText(targetWord);
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiGeneration || _isDisposed) break;
        _aiTranslationText += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (gen == _aiGeneration && !_isDisposed) {
        _aiTranslationText = 'Translation unavailable: $e';
      }
    } finally {
      if (gen == _aiGeneration && !_isDisposed) {
        _isAiGenerating = false;
        _activeAiHandle = null;
        notifyListeners();
      }
    }
  }

  Future<void> _fetchAiExplanation() async {
    if (_currentEntry == null) return;
    final targetWord = _currentEntry!.word;
    final gen = ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    if (!aiService.llmEngine.isLoaded) {
      _aiExplanationText =
          'Load a local AI model in Settings to use AI explanation.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiExplanationText = '';
    notifyListeners();

    try {
      final handle = aiService.startExplainWord(targetWord);
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiGeneration || _isDisposed) break;
        _aiExplanationText += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (gen == _aiGeneration && !_isDisposed) {
        _aiExplanationText = 'Explanation unavailable: $e';
      }
    } finally {
      if (gen == _aiGeneration && !_isDisposed) {
        _isAiGenerating = false;
        _activeAiHandle = null;
        notifyListeners();
      }
    }
  }

  Future<void> askAiAboutWord(String prompt) async {
    if (_currentEntry == null) return;
    final targetWord = _currentEntry!.word;
    final gen = ++_aiGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    if (!aiService.llmEngine.isLoaded) {
      _aiExplanationText =
          'Load a local AI model in Settings to use AI explanation.';
      _selectedTab = 2;
      notifyListeners();
      return;
    }

    _selectedTab = 2;
    _isAiGenerating = true;
    _aiExplanationText = 'Querying local model: "$prompt"...\n\n';
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
              'Word: "$targetWord"\nRequest: $prompt\nProvide a clear, concise educational explanation.',
        ),
      ];
      final plainPrompt =
          'Word: $targetWord\nRequest: $prompt\nProvide a clear, concise educational explanation.';

      final handle = aiService.llmEngine.startGeneration(
        plainPrompt,
        settings: aiService.settings,
        chatMessages: msgs,
      );
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiGeneration || _isDisposed) break;
        _aiExplanationText += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (gen == _aiGeneration && !_isDisposed) {
        _aiExplanationText = 'AI explanation unavailable: $e';
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
    _activeAiHandle?.cancel();
    _activeAiHandle = null;
    _tts.stop();
    super.dispose();
  }
}
