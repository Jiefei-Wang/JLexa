import 'package:flutter/foundation.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/dictionary/dictionary_repository.dart';

class HomeController extends ChangeNotifier {
  final DictionaryRepository dictionaryRepo;
  final LessonRepository lessonRepo;

  List<String> _recentSearches = [];
  List<AudioLesson> _lessons = [];
  bool _isLoading = false;
  bool _isDisposed = false;

  List<String> get recentSearches => _recentSearches;
  List<AudioLesson> get lessons => _lessons;
  bool get isLoading => _isLoading;

  HomeController({
    required this.dictionaryRepo,
    required this.lessonRepo,
  }) {
    lessonRepo.addListener(_onLessonRepoChanged);
    loadData();
  }

  void _onLessonRepoChanged() {
    loadData();
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
    lessonRepo.removeListener(_onLessonRepoChanged);
    super.dispose();
  }

  Future<void> loadData() async {
    _isLoading = true;
    notifyListeners();

    try {
      _recentSearches = await dictionaryRepo.getRecentSearches();
      _lessons = await lessonRepo.getAllLessons();
    } catch (_) {}

    _isLoading = false;
    notifyListeners();
  }

  Future<void> deleteLesson(String id) async {
    await lessonRepo.deleteLesson(id);
    await loadData();
  }
}
