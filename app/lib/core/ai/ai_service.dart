import 'dart:convert';
import 'dart:io';
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

      if (map.containsKey('llm_model_path') && map['llm_model_path']!.isNotEmpty) {
        _configuredLlmPath = map['llm_model_path'];
      }

      if (map.containsKey('whisper_model_path') && map['whisper_model_path']!.isNotEmpty) {
        _configuredSpeechPath = map['whisper_model_path'];
      }

      if (map.containsKey('ai_generation_settings')) {
        try {
          final decoded = jsonDecode(map['ai_generation_settings']!) as Map<String, dynamic>;
          _settings = AiGenerationSettings.fromMap(decoded);
        } catch (_) {}
      }

      notifyListeners();
    } catch (_) {}
  }

  Future<void> saveSetting(String key, String value) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert(
        'app_settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> saveModelPath(String key, String path) async {
    await saveSetting(key, path);
  }

  Future<void> loadLlmModel(String path) async {
    _configuredLlmPath = path;
    await llmEngine.loadModel(path, settings: _settings);
    await saveSetting('llm_model_path', path);
    notifyListeners();
  }

  /// Unloads the native LLM model from RAM while preserving the configured path.
  Future<void> unloadLlmModel() async {
    await llmEngine.unload();
    notifyListeners();
  }

  /// Explicitly removes the model configuration and optionally deletes the app-owned file.
  Future<void> forgetLlmModel({bool deleteFile = false}) async {
    final oldPath = _configuredLlmPath;
    await llmEngine.unload();
    _configuredLlmPath = null;
    await saveSetting('llm_model_path', '');
    if (deleteFile && oldPath != null) {
      try {
        final f = File(oldPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> loadSpeechModel(String path) async {
    _configuredSpeechPath = path;
    await speechEngine.loadModel(path);
    await saveSetting('whisper_model_path', path);
    notifyListeners();
  }

  /// Unloads the native Whisper model from RAM while preserving the configured path.
  Future<void> unloadSpeechModel() async {
    await speechEngine.unload();
    notifyListeners();
  }

  /// Explicitly removes the speech model configuration and optionally deletes the app-owned file.
  Future<void> forgetSpeechModel({bool deleteFile = false}) async {
    final oldPath = _configuredSpeechPath;
    await speechEngine.unload();
    _configuredSpeechPath = null;
    await saveSetting('whisper_model_path', '');
    if (deleteFile && oldPath != null) {
      try {
        final f = File(oldPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  void updateSettings(AiGenerationSettings newSettings) {
    _settings = newSettings;
    saveSetting('ai_generation_settings', jsonEncode(newSettings.toMap()));
    notifyListeners();
  }

  Stream<String> explainSentence(SentenceContext context) {
    if (!llmEngine.isLoaded) {
      return Stream.error(const AiModelNotLoadedException());
    }
    final msgs = PromptBuilder.buildSentenceExplanationMessages(context);
    final prompt = PromptBuilder.buildSentenceExplanation(context);
    return llmEngine.generate(
      prompt,
      settings: _settings,
      chatMessages: msgs,
    );
  }

  Stream<String> translateText(String text) {
    if (!llmEngine.isLoaded) {
      return Stream.error(const AiModelNotLoadedException());
    }
    final msgs = PromptBuilder.buildTranslationMessages(text);
    final prompt = PromptBuilder.buildTranslation(text);
    return llmEngine.generate(
      prompt,
      settings: _settings,
      chatMessages: msgs,
    );
  }

  Stream<String> explainWord(String word) {
    if (!llmEngine.isLoaded) {
      return Stream.error(const AiModelNotLoadedException());
    }
    final msgs = PromptBuilder.buildDictionaryExplanationMessages(word);
    final prompt = PromptBuilder.buildDictionaryExplanation(word);
    return llmEngine.generate(
      prompt,
      settings: _settings,
      chatMessages: msgs,
    );
  }

  Stream<String> askSentenceQA({
    required SentenceContext context,
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    if (!llmEngine.isLoaded) {
      return Stream.error(const AiModelNotLoadedException());
    }
    final msgs = PromptBuilder.buildSentenceQAMessages(
      context: context,
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    final prompt = PromptBuilder.buildSentenceQA(
      context: context,
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    return llmEngine.generate(
      prompt,
      settings: _settings,
      chatMessages: msgs,
    );
  }

  Stream<String> askGeneralQA({
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    if (!llmEngine.isLoaded) {
      return Stream.error(const AiModelNotLoadedException());
    }
    final msgs = PromptBuilder.buildGeneralQAMessages(
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    final prompt = PromptBuilder.buildGeneralQA(
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    return llmEngine.generate(
      prompt,
      settings: _settings,
      chatMessages: msgs,
    );
  }
}
