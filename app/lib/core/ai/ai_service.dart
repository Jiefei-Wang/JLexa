import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../database/app_database.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'native_ai_bridge.dart';
import 'prompt_builder.dart';
import 'speech_engine.dart';

class AiService extends ChangeNotifier {
  final AiEngine llmEngine;
  final SpeechRecognitionEngine speechEngine;

  AiGenerationSettings _settings = const AiGenerationSettings();
  AiGenerationSettings get settings => _settings;

  String? _configuredLlmPath;
  String? get configuredLlmPath => _configuredLlmPath;

  String? _configuredSpeechPath;
  String? get configuredSpeechPath => _configuredSpeechPath;

  bool get isGenerating => llmEngine.state == AiModelState.generating;

  AiService({
    AiEngine? llm,
    SpeechRecognitionEngine? speech,
  })  : llmEngine = llm ?? NativeLlamaEngine(),
        speechEngine = speech ?? NativeWhisperEngine() {
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final db = await AppDatabase.instance.database;
      final results = await db.query('app_settings');
      final Map<String, String> map = {
        for (var r in results) r['key'] as String: r['value'] as String
      };

      if (map.containsKey('llm_model_path')) {
        _configuredLlmPath = map['llm_model_path'];
      }

      if (map.containsKey('whisper_model_path')) {
        _configuredSpeechPath = map['whisper_model_path'];
      }

      notifyListeners();
    } catch (_) {}
  }

  Future<void> saveModelPath(String key, String path) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert(
        'app_settings',
        {'key': key, 'value': path},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> loadLlmModel(String path) async {
    _configuredLlmPath = path;
    await llmEngine.loadModel(path, settings: _settings);
    await saveModelPath('llm_model_path', path);
    notifyListeners();
  }

  Future<void> unloadLlmModel() async {
    await llmEngine.unload();
    _configuredLlmPath = null;
    await saveModelPath('llm_model_path', '');
    notifyListeners();
  }

  Future<void> loadSpeechModel(String path) async {
    _configuredSpeechPath = path;
    await speechEngine.loadModel(path);
    await saveModelPath('whisper_model_path', path);
    notifyListeners();
  }

  Future<void> unloadSpeechModel() async {
    await speechEngine.unload();
    _configuredSpeechPath = null;
    await saveModelPath('whisper_model_path', '');
    notifyListeners();
  }

  void updateSettings(AiGenerationSettings newSettings) {
    _settings = newSettings;
    notifyListeners();
  }

  Stream<String> explainSentence(SentenceContext context) {
    if (!llmEngine.isLoaded) {
      return Stream.value('Load a local AI model to generate an explanation.');
    }
    final prompt = PromptBuilder.buildSentenceExplanation(context);
    return llmEngine.generate(prompt, settings: _settings);
  }

  Stream<String> translateText(String text) {
    if (!llmEngine.isLoaded) {
      return Stream.value('Load a local AI model to use AI translation.');
    }
    final prompt = PromptBuilder.buildTranslation(text);
    return llmEngine.generate(prompt, settings: _settings);
  }

  Stream<String> explainWord(String word) {
    if (!llmEngine.isLoaded) {
      return Stream.value('Load a local AI model to use AI explanation.');
    }
    final prompt = PromptBuilder.buildDictionaryExplanation(word);
    return llmEngine.generate(prompt, settings: _settings);
  }

  Stream<String> askSentenceQA({
    required SentenceContext context,
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    if (!llmEngine.isLoaded) {
      return Stream.value('Load a local AI model to ask questions.');
    }
    final prompt = PromptBuilder.buildSentenceQA(
      context: context,
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    return llmEngine.generate(prompt, settings: _settings);
  }

  Stream<String> askGeneralQA({
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    if (!llmEngine.isLoaded) {
      return Stream.value('Load a local AI model to ask questions.');
    }
    final prompt = PromptBuilder.buildGeneralQA(
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    return llmEngine.generate(prompt, settings: _settings);
  }
}
