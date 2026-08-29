import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';
import '../../core/ai/ai_service.dart';
import '../../core/dictionary/dictionary_models.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/vocabulary/vocabulary_models.dart';
import '../../core/vocabulary/vocabulary_repository.dart';

class DictionaryController extends ChangeNotifier {
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final AiService aiService;
  final FlutterTts _tts = FlutterTts();

  String _currentQuery = '';
  DictionaryEntry? _currentEntry;
  bool _isSaved = false;
  bool _isLoading = false;
  List<String> _suggestions = [];
  int _selectedTab = 0; // 0: Dictionary, 1: AI Translation, 2: AI Explanation

  String _aiTranslationText = '';
  String _aiExplanationText = '';
  bool _isAiGenerating = false;

  String get currentQuery => _currentQuery;
  DictionaryEntry? get currentEntry => _currentEntry;
  bool get isSaved => _isSaved;
  bool get isLoading => _isLoading;
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
    _selectedTab = index;
    if (_selectedTab == 1 && _aiTranslationText.isEmpty && _currentEntry != null) {
      _fetchAiTranslation();
    } else if (_selectedTab == 2 && _aiExplanationText.isEmpty && _currentEntry != null) {
      _fetchAiExplanation();
    }
    notifyListeners();
  }

  Future<void> onQueryChanged(String query) async {
    _currentQuery = query;
    if (query.trim().isEmpty) {
      _suggestions = [];
      notifyListeners();
      return;
    }

    _suggestions = await dictionaryRepo.searchSuggestions(query);
    notifyListeners();
  }

  Future<void> search(String word) async {
    final clean = word.trim();
    if (clean.isEmpty) return;

    _isLoading = true;
    _currentQuery = clean;
    _suggestions = [];
    _aiTranslationText = '';
    _aiExplanationText = '';
    notifyListeners();

    _currentEntry = await dictionaryRepo.lookupWord(clean);
    if (_currentEntry != null) {
      _isSaved = await vocabularyRepo.isWordSaved(_currentEntry!.word);
    } else {
      _isSaved = false;
    }

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
    if (_currentEntry == null) return;

    if (_isSaved) {
      final existing = await vocabularyRepo.getWord(_currentEntry!.word);
      if (existing != null) {
        await vocabularyRepo.deleteWord(existing.id);
        _isSaved = false;
      }
    } else {
      final newWord = VocabularyWord(
        id: const Uuid().v4(),
        word: _currentEntry!.word,
        phonetic: _currentEntry!.phonetic,
        partOfSpeech: _currentEntry!.partOfSpeech,
        definitionSnapshot: _currentEntry!.definitions.isNotEmpty ? _currentEntry!.definitions.first : '',
        translationSnapshot: _currentEntry!.chineseDefinitions.isNotEmpty ? _currentEntry!.chineseDefinitions.first : '',
        source: 'Dictionary',
        sourceSentence: _currentEntry!.examples.isNotEmpty ? _currentEntry!.examples.first.english : null,
        dateAdded: DateTime.now(),
      );
      await vocabularyRepo.saveWord(newWord);
      _isSaved = true;
    }

    notifyListeners();
  }

  Future<void> _fetchAiTranslation() async {
    if (_currentEntry == null) return;
    if (!aiService.llmEngine.isLoaded) {
      _aiTranslationText = 'Load a local AI model to use AI translation.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiTranslationText = '';
    notifyListeners();

    await for (final chunk in aiService.translateText(_currentEntry!.word)) {
      _aiTranslationText += chunk;
      notifyListeners();
    }
    _isAiGenerating = false;
    notifyListeners();
  }

  Future<void> _fetchAiExplanation() async {
    if (_currentEntry == null) return;
    if (!aiService.llmEngine.isLoaded) {
      _aiExplanationText = 'Load a local AI model to use AI explanation.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiExplanationText = '';
    notifyListeners();

    await for (final chunk in aiService.explainWord(_currentEntry!.word)) {
      _aiExplanationText += chunk;
      notifyListeners();
    }
    _isAiGenerating = false;
    notifyListeners();
  }

  Future<void> askAiAboutWord(String prompt) async {
    if (_currentEntry == null) return;
    if (!aiService.llmEngine.isLoaded) {
      _aiExplanationText = 'Load a local AI model to use AI explanation.';
      _selectedTab = 2;
      notifyListeners();
      return;
    }

    _selectedTab = 2;
    _isAiGenerating = true;
    _aiExplanationText = 'Querying local model: "$prompt"...\n\n';
    notifyListeners();

    final fullPrompt = 'Word: ${_currentEntry!.word}\nRequest: $prompt\nProvide a clear, educational response.';
    await for (final chunk in aiService.llmEngine.generate(fullPrompt, settings: aiService.settings)) {
      _aiExplanationText += chunk;
      notifyListeners();
    }
    _isAiGenerating = false;
    notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _tts.stop();
    super.dispose();
  }
}
