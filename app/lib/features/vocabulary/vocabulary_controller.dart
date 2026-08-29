import 'package:flutter/foundation.dart';
import '../../core/vocabulary/vocabulary_models.dart';
import '../../core/vocabulary/vocabulary_repository.dart';

class VocabularyController extends ChangeNotifier {
  final VocabularyRepository vocabularyRepo;

  List<VocabularyWord> _allWords = [];
  List<VocabularyWord> _filteredWords = [];
  String _searchQuery = '';
  int _filterTab = 0; // 0: All, 1: Due Review, 2: Learning, 3: Mastered
  bool _isLoading = false;

  List<VocabularyWord> get words => _filteredWords;
  int get allCount => _allWords.length;
  int get dueCount => _allWords.where((w) => w.isDue).length;
  int get learningCount => _allWords.where((w) => w.state == VocabularyState.learning || w.state == VocabularyState.newWord).length;
  int get masteredCount => _allWords.where((w) => w.state == VocabularyState.mastered).length;
  int get filterTab => _filterTab;
  bool get isLoading => _isLoading;

  VocabularyController({required this.vocabularyRepo}) {
    loadWords();
  }

  Future<void> loadWords() async {
    _isLoading = true;
    notifyListeners();

    try {
      _allWords = await vocabularyRepo.getAllWords();
      _applyFilter();
    } catch (_) {}

    _isLoading = false;
    notifyListeners();
  }

  void setFilterTab(int index) {
    _filterTab = index;
    _applyFilter();
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query.toLowerCase().trim();
    _applyFilter();
    notifyListeners();
  }

  void _applyFilter() {
    List<VocabularyWord> list = List.from(_allWords);

    switch (_filterTab) {
      case 1: // Due Review
        list = list.where((w) => w.isDue).toList();
        break;
      case 2: // Learning
        list = list.where((w) => w.state == VocabularyState.learning || w.state == VocabularyState.newWord).toList();
        break;
      case 3: // Mastered
        list = list.where((w) => w.state == VocabularyState.mastered).toList();
        break;
    }

    if (_searchQuery.isNotEmpty) {
      list = list.where((w) => w.word.toLowerCase().contains(_searchQuery)).toList();
    }

    _filteredWords = list;
  }

  Future<void> deleteWord(String id) async {
    await vocabularyRepo.deleteWord(id);
    await loadWords();
  }

  Future<void> reviewWord(String id, ReviewRating rating) async {
    await vocabularyRepo.reviewWord(id, rating);
    await loadWords();
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
    super.dispose();
  }
}
