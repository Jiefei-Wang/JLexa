import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'backend_plugins.dart';
import 'native_ai_bridge.dart';
import 'prompt_builder.dart';
import 'speech_engine.dart';

enum AiServiceInitState {
  uninitialized,
  initializing,
  ready,
  readyWithWarnings,
}

class AiService extends ChangeNotifier {
  final BackendPlugins backendPlugins;
  final BackendPlugins speechPlugins;
  BackendPluginInfo speechPluginInfo = const BackendPluginInfo(
    engine: 'whisper.cpp',
    backendType: 'CPU',
  );
  BackendPluginInfo pluginInfo = const BackendPluginInfo();
  final AiEngine llmEngine;
  final SpeechRecognitionEngine speechEngine;

  AiServiceInitState _initState = AiServiceInitState.uninitialized;
  AiServiceInitState get initState => _initState;

  bool _whisperSegmentationEnabled = false;
  bool get whisperSegmentationEnabled => _whisperSegmentationEnabled;

  Future<void> setWhisperSegmentationEnabled(bool enabled) async {
    if (_whisperSegmentationEnabled == enabled) return;
    await saveSetting('whisper_segmentation_enabled', enabled.toString());
    _whisperSegmentationEnabled = enabled;
    notifyListeners();
  }

  AiGenerationSettings _settings = const AiGenerationSettings();
  AiGenerationSettings get settings => _settings;

  LlamaRuntimeSettings _llamaRuntimeSettings = const LlamaRuntimeSettings();
  LlamaRuntimeSettings get llamaRuntimeSettings => _llamaRuntimeSettings;
  LlamaRuntimeSettings? _loadedLlamaRuntimeSettings;
  bool _isUpdatingLlamaRuntime = false;
  bool get isUpdatingBackend => _isUpdatingLlamaRuntime;

  List<LlamaBackendInfo> _availableBackends = const [];
  List<LlamaBackendInfo> get availableBackends => _availableBackends;

  LlamaActiveBackendInfo _activeBackendInfo = const LlamaActiveBackendInfo();
  LlamaActiveBackendInfo get activeBackendInfo => _activeBackendInfo;

  String? _configuredLlmPath;
  String? get configuredLlmPath => _configuredLlmPath;

  String? _configuredSpeechPath;
  String? get configuredSpeechPath => _configuredSpeechPath;

  String? _llmRestorationError;
  String? get llmRestorationError => _llmRestorationError;

  String? _speechRestorationError;
  String? get speechRestorationError => _speechRestorationError;

  bool get isGenerating => llmEngine.state == AiModelState.generating;

  AiService({
    AiEngine? llm,
    SpeechRecognitionEngine? speech,
    BackendPlugins? plugins,
    BackendPlugins? speechPlugins,
  }) : backendPlugins = plugins ?? BackendPlugins(),
       speechPlugins = speechPlugins ?? BackendPlugins(speech: true),
       llmEngine = llm ?? NativeLlamaEngine(),
       speechEngine = speech ?? NativeWhisperEngine();

  Future<void> initialize() async {
    if (_initState == AiServiceInitState.initializing ||
        _initState == AiServiceInitState.ready ||
        _initState == AiServiceInitState.readyWithWarnings) {
      return;
    }
    _initState = AiServiceInitState.initializing;
    notifyListeners();

    _llmRestorationError = null;
    _speechRestorationError = null;

    try {
      final db = await AppDatabase.instance.database;
      final results = await db.query('app_settings');
      final Map<String, String> map = {
        for (var r in results) r['key'] as String: r['value'] as String,
      };

      _whisperSegmentationEnabled =
          map['whisper_segmentation_enabled'] == 'true';

      if (map.containsKey('llm_model_path') &&
          map['llm_model_path']!.isNotEmpty) {
        _configuredLlmPath = map['llm_model_path'];
      }

      if (map.containsKey('whisper_model_path') &&
          map['whisper_model_path']!.isNotEmpty) {
        _configuredSpeechPath = map['whisper_model_path'];
      }

      if (map.containsKey('ai_generation_settings')) {
        try {
          final decoded = jsonDecode(
            map['ai_generation_settings']!,
          ) as Map<String, dynamic>;
          _settings = AiGenerationSettings.fromMap(decoded);
        } catch (_) {}
      }

      // Load & migrate LlamaRuntimeSettings
      if (map.containsKey('llama_runtime_settings')) {
        try {
          final decoded = jsonDecode(
            map['llama_runtime_settings']!,
          ) as Map<String, dynamic>;
          _llamaRuntimeSettings = LlamaRuntimeSettings.fromMap(decoded);
        } catch (_) {}
      } else {
        // Migrate from legacy generation settings if present
        _llamaRuntimeSettings = LlamaRuntimeSettings(
          backend: LlamaBackendPreference.auto,
          contextLength: _settings.contextLength,
          threads: _settings.threads,
        );
      }

      await refreshPluginInfo();

      // Discover available backends from native engine
      try {
        _availableBackends = await llmEngine.getAvailableBackends();
      } catch (_) {
        _availableBackends = const [
          LlamaBackendInfo(
            backend: 'cpu',
            compiled: true,
            available: true,
            deviceName: 'CPU',
          ),
        ];
      }

      // 1. Independent LLM restoration
      if (_configuredLlmPath != null && _configuredLlmPath!.isNotEmpty) {
        if (await _modelPathExists(_configuredLlmPath!)) {
          try {
            await llmEngine.loadModel(
              _configuredLlmPath!,
              settings: _settings,
              runtimeSettings: _llamaRuntimeSettings,
            );
            _activeBackendInfo = await llmEngine.getActiveBackendInfo();
            _loadedLlamaRuntimeSettings = _llamaRuntimeSettings;
          } catch (e) {
            _llmRestorationError =
                'Could not reload saved LLM: ${e.toString()}';
          }
        } else {
          _llmRestorationError =
              'Configured LLM file not found: $_configuredLlmPath';
        }
      }

      await refreshPluginInfo();

      await refreshSpeechPluginInfo();

      // 2. Independent Whisper restoration
      if (_configuredSpeechPath != null && _configuredSpeechPath!.isNotEmpty) {
        if (await _modelPathExists(_configuredSpeechPath!)) {
          try {
            await speechEngine.loadModel(_configuredSpeechPath!);
          } catch (e) {
            _speechRestorationError =
                'Could not reload saved Whisper model: ${e.toString()}';
          }
        } else {
          _speechRestorationError =
              'Configured Whisper file not found: $_configuredSpeechPath';
        }
      }

      await refreshSpeechPluginInfo();
      _initState =
          (_llmRestorationError != null || _speechRestorationError != null)
          ? AiServiceInitState.readyWithWarnings
          : AiServiceInitState.ready;
      notifyListeners();
    } catch (e) {
      _initState = AiServiceInitState.readyWithWarnings;
      notifyListeners();
    }
  }

  Future<bool> _modelPathExists(String path) {
    // Android's Storage Access Framework exposes documents as content URIs,
    // not filesystem paths. The native bridges validate/open these URIs via
    // ContentResolver and surface a useful restoration error if permission was
    // revoked or the document was removed.
    if (path.startsWith('content://')) {
      return Future.value(true);
    }
    return File(path).exists();
  }

  Future<void> saveSetting(String key, String value) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert('app_settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  Future<void> saveModelPath(String key, String path) async {
    await saveSetting(key, path);
  }

  Future<void> loadLlmModel(
    String path, {
    LlamaRuntimeSettings? runtimeSettings,
  }) async {
    final prevPath = _configuredLlmPath;
    final rSettings = runtimeSettings ?? _llamaRuntimeSettings;
    try {
      await llmEngine.loadModel(
        path,
        settings: _settings,
        runtimeSettings: rSettings,
      );
      _configuredLlmPath = path;
      _llmRestorationError = null;
      _activeBackendInfo = await llmEngine.getActiveBackendInfo();
      _loadedLlamaRuntimeSettings = rSettings;
      await saveSetting('llm_model_path', path);
      await refreshPluginInfo();
      notifyListeners();
    } catch (e) {
      _configuredLlmPath = prevPath;
      if (!llmEngine.isLoaded) {
        _activeBackendInfo = const LlamaActiveBackendInfo();
        _loadedLlamaRuntimeSettings = null;
      }
      notifyListeners();
      rethrow;
    }
  }

  /// Unloads the native LLM model from RAM while preserving the configured path.
  Future<void> unloadLlmModel() async {
    await llmEngine.unload();
    _loadedLlamaRuntimeSettings = null;
    _activeBackendInfo = const LlamaActiveBackendInfo();
    notifyListeners();
  }

  /// Explicitly removes the model configuration and optionally deletes the app-owned file.
  Future<void> forgetLlmModel({bool deleteFile = false}) async {
    final oldPath = _configuredLlmPath;
    await llmEngine.unload();
    _loadedLlamaRuntimeSettings = null;
    _configuredLlmPath = null;
    _llmRestorationError = null;
    _activeBackendInfo = const LlamaActiveBackendInfo();
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
    final prevPath = _configuredSpeechPath;
    try {
      await speechEngine.loadModel(path);
      await refreshSpeechPluginInfo();
      _configuredSpeechPath = path;
      _speechRestorationError = null;
      await saveSetting('whisper_model_path', path);
      notifyListeners();
    } catch (e) {
      _configuredSpeechPath = prevPath;
      notifyListeners();
      rethrow;
    }
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
    _speechRestorationError = null;
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

  Future<void> refreshPluginInfo() async {
    try {
      pluginInfo = await backendPlugins.status();
    } catch (e) {
      pluginInfo = BackendPluginInfo(status: 'Failed', error: '$e');
    }
    notifyListeners();
  }

  Future<void> refreshAfterBenchmark() async {
    _activeBackendInfo = llmEngine.isLoaded
        ? await llmEngine.getActiveBackendInfo()
        : const LlamaActiveBackendInfo();
    if (!llmEngine.isLoaded) _loadedLlamaRuntimeSettings = null;
    await refreshPluginInfo();
  }

  void _checkBackendMutation() {
    if (_initState == AiServiceInitState.initializing ||
        _isUpdatingLlamaRuntime ||
        isGenerating ||
        llmEngine.state == AiModelState.loading) {
      throw const AiBusyException(
        'Wait for the current AI operation to finish.',
      );
    }
  }

  Future<void> changeBackendPlugin({required bool import}) async {
    if (!import) {
      await selectBackend('');
      return;
    }
    _checkBackendMutation();
    _isUpdatingLlamaRuntime = true;
    notifyListeners();
    try {
      // Probe in the separate process; the current model remains loaded.
      pluginInfo = await backendPlugins.importPlugin();
    } finally {
      _isUpdatingLlamaRuntime = false;
      notifyListeners();
    }
  }

  Future<void> selectBackend(
    String id, {
    LlamaBackendPreference? preference,
  }) async {
    _checkBackendMutation();
    final previousId = pluginInfo.id;
    final previousRuntime = _llamaRuntimeSettings;
    final path = llmEngine.isLoaded ? llmEngine.loadedModelPath : null;
    final next = previousRuntime.copyWith(
      backend: id.isEmpty
          ? preference ?? previousRuntime.backend
          : LlamaBackendPreference.auto,
    );
    _isUpdatingLlamaRuntime = true;
    notifyListeners();
    try {
      await unloadLlmModel();
      try {
        pluginInfo = id.isEmpty
            ? await backendPlugins.useBuiltin()
            : await backendPlugins.select(id);
        _availableBackends = await llmEngine.getAvailableBackends();
        if (path != null) await loadLlmModel(path, runtimeSettings: next);
        if (id.isNotEmpty && pluginInfo.id != id) {
          throw AiGenerationException(
            pluginInfo.error.isEmpty
                ? 'Backend could not load the selected model.'
                : pluginInfo.error,
          );
        }
        _llamaRuntimeSettings = next;
        await saveSetting('llama_runtime_settings', jsonEncode(next.toMap()));
      } catch (e) {
        try {
          pluginInfo = previousId.isEmpty
              ? await backendPlugins.useBuiltin()
              : await backendPlugins.select(previousId);
          if (path != null) {
            await loadLlmModel(path, runtimeSettings: previousRuntime);
          }
        } catch (restoreError) {
          throw AiGenerationException(
            '$e. Could not restore the previous backend: $restoreError',
          );
        }
        rethrow;
      }
    } finally {
      try {
        _availableBackends = await llmEngine.getAvailableBackends();
        await refreshPluginInfo();
      } finally {
        _isUpdatingLlamaRuntime = false;
        notifyListeners();
      }
    }
  }

  Future<void> deleteBackend(String id) async {
    _checkBackendMutation();
    if (pluginInfo.id == id) {
      await selectBackend('', preference: LlamaBackendPreference.auto);
    }
    _isUpdatingLlamaRuntime = true;
    notifyListeners();
    try {
      pluginInfo = await backendPlugins.delete(id);
    } finally {
      _isUpdatingLlamaRuntime = false;
      notifyListeners();
    }
  }

  Future<void> refreshSpeechPluginInfo() async {
    try {
      speechPluginInfo = await speechPlugins.status();
    } catch (_) {}
    notifyListeners();
  }

  void _checkSpeechBackendMutation() {
    _checkBackendMutation();
    final engine = speechEngine;
    if (engine is NativeWhisperEngine && engine.isBusy) {
      throw const AiBusyException(
        'Wait for the current transcription to finish.',
      );
    }
  }

  Future<void> importSpeechBackend() async {
    _checkSpeechBackendMutation();
    _isUpdatingLlamaRuntime = true;
    notifyListeners();
    try {
      speechPluginInfo = await speechPlugins.importPlugin();
    } finally {
      _isUpdatingLlamaRuntime = false;
      notifyListeners();
    }
  }

  Future<void> selectSpeechBackend(String id) async {
    _checkSpeechBackendMutation();
    final previous = speechPluginInfo.id;
    final path = speechEngine.isLoaded ? speechEngine.loadedModelPath : null;
    _isUpdatingLlamaRuntime = true;
    notifyListeners();
    try {
      await speechEngine.unload();
      try {
        speechPluginInfo = id.isEmpty
            ? await speechPlugins.useBuiltin()
            : await speechPlugins.select(id);
        if (path != null) await loadSpeechModel(path);
        if (id.isNotEmpty && speechPluginInfo.id != id) {
          throw AiGenerationException(
            speechPluginInfo.error.isEmpty
                ? 'Whisper backend could not load the model.'
                : speechPluginInfo.error,
          );
        }
      } catch (e) {
        try {
          speechPluginInfo = previous.isEmpty
              ? await speechPlugins.useBuiltin()
              : await speechPlugins.select(previous);
          if (path != null) await loadSpeechModel(path);
        } catch (restoreError) {
          throw AiGenerationException(
            '$e. Could not restore the previous Whisper backend: $restoreError',
          );
        }
        rethrow;
      }
    } finally {
      await refreshSpeechPluginInfo();
      _isUpdatingLlamaRuntime = false;
      notifyListeners();
    }
  }

  Future<void> deleteSpeechBackend(String id) async {
    _checkSpeechBackendMutation();
    if (speechPluginInfo.id == id) await selectSpeechBackend('');
    _isUpdatingLlamaRuntime = true;
    notifyListeners();
    try {
      speechPluginInfo = await speechPlugins.delete(id);
    } finally {
      _isUpdatingLlamaRuntime = false;
      notifyListeners();
    }
  }

  Future<void> updateLlamaRuntimeSettings(
    LlamaRuntimeSettings newSettings, {
    bool autoReload = true,
  }) async {
    if (_isUpdatingLlamaRuntime || isGenerating) {
      throw const AiBusyException(
        'Wait for the current AI operation to finish before changing runtime settings.',
      );
    }
    _isUpdatingLlamaRuntime = true;
    final previousRuntime =
        _loadedLlamaRuntimeSettings ?? _llamaRuntimeSettings;
    final previousModel = llmEngine.isLoaded ? llmEngine.loadedModelPath : null;
    try {
      if (autoReload && previousModel != null) {
        try {
          await loadLlmModel(previousModel, runtimeSettings: newSettings);
        } catch (error) {
          try {
            await loadLlmModel(previousModel, runtimeSettings: previousRuntime);
          } catch (restoreError) {
            throw AiGenerationException(
              'Could not apply runtime settings: $error. Restoring the previous runtime also failed: $restoreError',
            );
          }
          throw AiGenerationException(
            'Could not apply runtime settings: $error. The previous working runtime has been restored.',
          );
        }
      }
      // Save only an accepted configuration; failed reloads must not poison
      // the next launch or leave Settings claiming that the switch succeeded.
      _llamaRuntimeSettings = newSettings;
      await saveSetting(
        'llama_runtime_settings',
        jsonEncode(newSettings.toMap()),
      );
    } finally {
      _isUpdatingLlamaRuntime = false;
      notifyListeners();
    }
  }

  Future<void> resetLlamaRuntimeSettings({bool autoReload = true}) async {
    await updateLlamaRuntimeSettings(
      LlamaRuntimeSettings.defaultSettings,
      autoReload: autoReload,
    );
  }

  AiGenerationHandle startExplainSentence(
    SentenceContext context, {
    AiRequestPriority priority = AiRequestPriority.background,
  }) {
    if (!llmEngine.isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }
    final msgs = PromptBuilder.buildSentenceExplanationMessages(context);
    final prompt = PromptBuilder.buildSentenceExplanation(context);
    return llmEngine.startGeneration(
      prompt,
      settings: _settings,
      chatMessages: msgs,
      priority: priority,
    );
  }

  Stream<String> explainSentence(SentenceContext context) {
    return startExplainSentence(
      context,
      priority: AiRequestPriority.background,
    ).stream;
  }

  AiGenerationHandle startDictionaryAiAnswer(
    String query, {
    String? dictionaryContext,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (!llmEngine.isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }
    final msgs = PromptBuilder.buildDictionaryAiAnswerMessages(
      query,
      dictionaryContext: dictionaryContext,
    );
    final prompt = PromptBuilder.buildDictionaryAiAnswer(
      query,
      dictionaryContext: dictionaryContext,
    );
    return llmEngine.startGeneration(
      prompt,
      settings: _settings,
      chatMessages: msgs,
      priority: priority,
    );
  }

  AiGenerationHandle startTranslateText(
    String text, {
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (!llmEngine.isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }
    final msgs = PromptBuilder.buildTranslationMessages(text);
    final prompt = PromptBuilder.buildTranslation(text);
    return llmEngine.startGeneration(
      prompt,
      settings: _settings,
      chatMessages: msgs,
      priority: priority,
    );
  }

  Stream<String> translateText(String text) {
    return startTranslateText(text).stream;
  }

  AiGenerationHandle startExplainWord(
    String word, {
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (!llmEngine.isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }
    final msgs = PromptBuilder.buildDictionaryExplanationMessages(word);
    final prompt = PromptBuilder.buildDictionaryExplanation(word);
    return llmEngine.startGeneration(
      prompt,
      settings: _settings,
      chatMessages: msgs,
      priority: priority,
    );
  }

  Stream<String> explainWord(String word) {
    return startExplainWord(word).stream;
  }

  AiGenerationHandle startSentenceQA({
    required SentenceContext context,
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (!llmEngine.isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
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
    return llmEngine.startGeneration(
      prompt,
      settings: _settings,
      chatMessages: msgs,
      priority: priority,
    );
  }

  Stream<String> askSentenceQA({
    required SentenceContext context,
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    return startSentenceQA(
      context: context,
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    ).stream;
  }

  AiGenerationHandle startGeneralQA({
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (!llmEngine.isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }
    final msgs = PromptBuilder.buildGeneralQAMessages(
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    final prompt = PromptBuilder.buildGeneralQA(
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    );
    return llmEngine.startGeneration(
      prompt,
      settings: _settings,
      chatMessages: msgs,
      priority: priority,
    );
  }

  Stream<String> askGeneralQA({
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    return startGeneralQA(
      userQuestion: userQuestion,
      chatHistory: chatHistory,
    ).stream;
  }
}
