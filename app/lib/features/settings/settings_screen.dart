import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/backend_benchmark.dart';
import '../../core/ai/model_catalog.dart';
import '../../core/ai/speech_benchmark.dart';
import '../../core/ai/model_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'settings_controller.dart';
import 'backend_benchmark_controller.dart';
import 'backend_benchmark_screen.dart';
import 'speech_benchmark_controller.dart';
import 'speech_benchmark_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AiService aiService;
  final ModelManager? modelManager;
  final SettingsController? controller;

  const SettingsScreen({
    super.key,
    required this.aiService,
    this.modelManager,
    this.controller,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsController _controller;
  bool _ownsController = false;
  int? _draftThreads;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = SettingsController(
        aiService: widget.aiService,
        manager: widget.modelManager,
      );
      _ownsController = true;
    }
    _controller.refreshModels();
    _controller.aiService.refreshPluginInfo();
    _controller.aiService.refreshSpeechPluginInfo();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  bool get _backendBusy =>
      _controller.isLoading ||
      _controller.aiService.isGenerating ||
      _controller.aiService.initState == AiServiceInitState.initializing;

  Future<void> _backendAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        final message = e is PlatformException ? (e.message ?? e.code) : '$e';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  Future<void> _importBackend() async {
    final service = _controller.aiService;
    final before = service.pluginInfo.installed.length;
    await _backendAction(() async {
      await service.changeBackendPlugin(import: true);
      if (mounted && service.pluginInfo.installed.length > before) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Backend added. Select it below to use it.'),
          ),
        );
      }
    });
  }

  Widget _buildSpeechBackendCard() {
    final service = _controller.aiService;
    final plugin = service.speechPluginInfo;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Whisper-assisted segmentation'),
              value: service.whisperSegmentationEnabled,
              onChanged: (enabled) => _backendAction(
                () => service.setWhisperSegmentationEnabled(enabled),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Whisper Backend', style: AppTypography.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _backendBusy ? null : _openSpeechBenchmark,
                  icon: const Icon(Icons.speed),
                  label: const Text('Benchmark'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Import'),
                  onPressed: _backendBusy
                      ? null
                      : () => _backendAction(() async {
                          final before = plugin.installed.length;
                          await service.importSpeechBackend();
                          if (mounted &&
                              service.speechPluginInfo.installed.length >
                                  before) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Whisper backend added. Select it below to use it.',
                                ),
                              ),
                            );
                          }
                        }),
                ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                plugin.external
                    ? Icons.radio_button_unchecked
                    : Icons.radio_button_checked,
              ),
              title: const Text('Built-in Whisper CPU'),
              subtitle: Text(
                plugin.external
                    ? 'whisper.cpp'
                    : 'whisper.cpp · ${plugin.status}',
              ),
              onTap: _backendBusy
                  ? null
                  : () => _backendAction(() => service.selectSpeechBackend('')),
            ),
            for (final backend in plugin.installed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  plugin.id == backend.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(backend.name),
                subtitle: Text(
                  '${backend.engine} · ${backend.version} · ${backend.backendType}${plugin.id == backend.id ? ' · Loaded' : ''}',
                ),
                onTap: _backendBusy
                    ? null
                    : () => _backendAction(
                        () => service.selectSpeechBackend(backend.id),
                      ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete ${backend.name}',
                  onPressed: _backendBusy
                      ? null
                      : () => _backendAction(
                          () => service.deleteSpeechBackend(backend.id),
                        ),
                ),
              ),
            if (plugin.error.isNotEmpty)
              Text(
                plugin.error,
                style: const TextStyle(color: AppColors.error),
              ),
          ],
        ),
      ),
    );
  }

  void _openSpeechBenchmark() {
    final service = _controller.aiService;
    final engine = service.speechEngine;
    final path = engine.loadedModelPath;
    if (engine is! SpeechBenchmarkEngine || !engine.isLoaded || path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Load a Whisper model before benchmarking.'),
        ),
      );
      return;
    }
    final controller = SpeechBenchmarkController(
      engine: engine as SpeechBenchmarkEngine,
      store: DatabaseSpeechBenchmarkStore(),
      backends: {
        'cpu': 'Built-in CPU',
        for (final p in service.speechPluginInfo.installed)
          'plugin:${p.id}': p.name,
      },
      modelPath: path,
      modelName:
          _controller.whisperModels
              .where((m) => m.localPath == path)
              .firstOrNull
              ?.displayName ??
          'Selected Whisper model',
      onFinished: service.refreshSpeechPluginInfo,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SpeechBenchmarkScreen(controller: controller),
      ),
    );
  }

  void _openBenchmark() {
    final service = _controller.aiService;
    final engine = service.llmEngine;
    final path = engine.loadedModelPath;
    if (engine is! BenchmarkEngine || !engine.isLoaded || path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Load a language model before benchmarking.'),
        ),
      );
      return;
    }
    final plugin = service.pluginInfo;
    final benchmarkController = BackendBenchmarkController(
      engine: engine as BenchmarkEngine,
      store: DatabaseBenchmarkStore(
        legacyPluginRows: {
          for (final p in plugin.installed.where((p) => p.backendType == 'CPU'))
            'true/${p.name}/${p.version}/${p.fileName}': 'plugin:${p.id}',
        },
      ),
      backends: [
        ...(plugin.builtinBackends.isEmpty
            ? service.availableBackends
            : plugin.builtinBackends),
        ...plugin.installed.map(
          (p) => LlamaBackendInfo(
            backend: 'plugin:${p.id}',
            deviceName: p.name,
            compiled: true,
            available: true,
          ),
        ),
      ],
      runtime: service.llamaRuntimeSettings,
      modelName:
          _controller.llmModels
              .where((m) => m.localPath == path)
              .firstOrNull
              ?.displayName ??
          _controller.llmInfo?.name ??
          'Selected model',
      modelPath: path,
      pluginKey: 'backend_catalog_v1',
      onFinished: service.refreshAfterBenchmark,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BackendBenchmarkScreen(controller: benchmarkController),
      ),
    );
  }

  Future<void> _confirmDeleteModel({
    required String modelName,
    required VoidCallback onConfirm,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Model?'),
        content: Text(
          'Are you sure you want to remove "$modelName" from your device storage?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (result == true) {
      onConfirm();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final llmModels = _controller.llmModels;
        final whisperModels = _controller.whisperModels;

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            title: const Text(
              'Settings & Local Models',
              style: AppTypography.titleMedium,
            ),
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_controller.errorMessage != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.error),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: AppColors.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _controller.errorMessage!,
                            style: const TextStyle(
                              color: AppColors.error,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _controller.hasInventoryError
                                ? Icons.refresh
                                : Icons.close,
                            size: 16,
                            color: AppColors.error,
                          ),
                          tooltip: _controller.hasInventoryError
                              ? 'Retry model scan'
                              : 'Dismiss error',
                          onPressed: _controller.hasInventoryError
                              ? _controller.refreshModels
                              : _controller.clearError,
                        ),
                      ],
                    ),
                  ),

                if (_controller.llmRestorationError != null ||
                    _controller.speechRestorationError != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.shade400),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.amber.shade800,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Startup Restoration Notice',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.amber.shade900,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        if (_controller.llmRestorationError != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            _controller.llmRestorationError!,
                            style: TextStyle(
                              color: Colors.amber.shade900,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        if (_controller.speechRestorationError != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            _controller.speechRestorationError!,
                            style: TextStyle(
                              color: Colors.amber.shade900,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                // ==========================================
                // Storage Folder Configuration
                // ==========================================
                _buildStorageFolderCard(),
                const SizedBox(height: 24),

                if (!_controller.isStorageConfigured) ...[
                  _buildUnconfiguredCatalogPlaceholder(),
                  const SizedBox(height: 24),
                ],
                if (llmModels.isNotEmpty || whisperModels.isNotEmpty) ...[
                  // ==========================================
                  // Section 1: Local Language Model (LLM)
                  // ==========================================
                  const Text(
                    'Local Language Model (LLM)',
                    style: AppTypography.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Download an offline model for AI explanations, grammar insights, and translations.',
                    style: AppTypography.bodySmall,
                  ),
                  const SizedBox(height: 10),

                  ...llmModels.map((item) => _buildModelCard(item)),

                  const SizedBox(height: 24),

                  // ==========================================
                  // Section 2: Speech Recognition Model (Whisper)
                  // ==========================================
                  const Text(
                    'Speech Recognition Model (Whisper)',
                    style: AppTypography.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select an offline speech recognition model. Choose its speech backend separately below.',
                    style: AppTypography.bodySmall,
                  ),
                  const SizedBox(height: 10),

                  ...whisperModels.map((item) => _buildModelCard(item)),

                  const SizedBox(height: 16),

                  // Custom Models Information Card
                  _buildCustomModelsInfoCard(),

                  const SizedBox(height: 24),
                ],

                // ==========================================
                // Section 3: llama.cpp Runtime & Backend Settings
                // ==========================================
                const Text(
                  'llama.cpp Runtime & Hardware Acceleration',
                  style: AppTypography.titleSmall,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Configure hardware acceleration backend and execution engine parameters.',
                  style: AppTypography.bodySmall,
                ),
                const SizedBox(height: 10),

                _buildLlamaRuntimeCard(),
                const SizedBox(height: 24),
                _buildSpeechBackendCard(),

                const SizedBox(height: 24),

                // ==========================================
                // Section 4: AI Generation Settings
                // ==========================================
                const Text(
                  'Sampling & Generation Settings',
                  style: AppTypography.titleSmall,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      _buildSliderTile(
                        title: 'Temperature',
                        subtitle: 'Controls randomness vs determinism',
                        value: _controller.generationSettings.temperature,
                        min: 0.1,
                        max: 1.5,
                        divisions: 14,
                        displayValue: _controller.generationSettings.temperature
                            .toStringAsFixed(2),
                        onChanged: (val) {
                          _controller.updateAiGenerationSettings(
                            _controller.generationSettings.copyWith(
                              temperature: val,
                            ),
                          );
                        },
                      ),
                      const Divider(height: 20),
                      _buildSliderTile(
                        title: 'Top-P Sampling',
                        subtitle: 'Nucleus sampling threshold',
                        value: _controller.generationSettings.topP,
                        min: 0.1,
                        max: 1.0,
                        divisions: 18,
                        displayValue: _controller.generationSettings.topP
                            .toStringAsFixed(2),
                        onChanged: (val) {
                          _controller.updateAiGenerationSettings(
                            _controller.generationSettings.copyWith(topP: val),
                          );
                        },
                      ),
                      const Divider(height: 20),
                      _buildSliderTile(
                        title: 'Max Output Tokens',
                        subtitle: 'Maximum response length in tokens',
                        value: _controller.generationSettings.maxTokens
                            .toDouble(),
                        min: 128,
                        max: 2048,
                        divisions: 15,
                        displayValue:
                            '${_controller.generationSettings.maxTokens}',
                        onChanged: (val) {
                          _controller.updateAiGenerationSettings(
                            _controller.generationSettings.copyWith(
                              maxTokens: val.round(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // About Section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('About JLexa', style: AppTypography.labelLarge),
                      SizedBox(height: 4),
                      Text(
                        'JLexa 1.0.0 (Android-first)\nOffline Dictionary • Sentence Repeater • Spaced Repetition • Local AI Engine (llama.cpp / whisper.cpp)\nDictionary: 57,961 ECDICT learner entries (MIT) plus curated examples.',
                        style: AppTypography.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'JLexa',
                  ),
                  child: const Text('Open-source licenses'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildModelCard(ManagedModelItem item) {
    final isDownloading = item.state == ModelDownloadState.downloading;
    final isCancelling = _controller.isCancellingDownload(item.id);
    final isLoaded = item.state == ModelDownloadState.loaded;
    final isLoading = item.state == ModelDownloadState.loading;
    final isDownloaded = item.isDownloaded;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLoaded
              ? AppColors.primary
              : (item.isRecommended ? AppColors.secondary : AppColors.border),
          width: isLoaded ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                item.type == ModelType.llm
                    ? Icons.psychology
                    : Icons.record_voice_over,
                color: isLoaded ? AppColors.primary : AppColors.textSecondary,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.displayName, style: AppTypography.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (item.isRecommended)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'RECOMMENDED',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        _buildStateBadge(item.state),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${item.formattedSize}${item.speedHint.isNotEmpty ? " • ${item.speedHint}" : ""}${item.memoryHint.isNotEmpty ? " • ${item.memoryHint}" : ""}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (item.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(item.description, style: AppTypography.bodySmall),
          ],
          if (item.errorMessage?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              item.errorMessage!,
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ],
          if (isDownloading) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    item.progress != null
                        ? 'Downloading: ${item.progress!.formattedReceived} / ${item.progress!.formattedTotal}'
                        : 'Downloading...',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  item.progress?.percentageString ?? '0%',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: item.progress?.progress,
              backgroundColor: AppColors.border,
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: isCancelling
                    ? null
                    : () => _controller.cancelDownload(item.id),
                icon: const Icon(Icons.close, size: 16, color: AppColors.error),
                label: Text(
                  isCancelling ? 'Cancelling…' : 'Cancel',
                  style: const TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!isDownloaded && item.catalogModel != null)
                  FilledButton.tonalIcon(
                    onPressed:
                        _controller.isLoading || _controller.hasInventoryError
                        ? null
                        : () => _controller.downloadModel(item.catalogModel!),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                if (isDownloaded && !isLoaded) ...[
                  FilledButton.icon(
                    onPressed: _controller.isLoading || isLoading
                        ? null
                        : () => _controller.loadModel(item),
                    icon: isLoading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow, size: 18),
                    label: Text(isLoading ? 'Loading...' : 'Use'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _controller.isLoading
                        ? null
                        : () => _confirmDeleteModel(
                            modelName: item.displayName,
                            onConfirm: () => _controller.deleteModel(item),
                          ),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.textTertiary,
                      size: 20,
                    ),
                    tooltip: 'Delete Model File',
                  ),
                ],
                if (isLoaded) ...[
                  OutlinedButton(
                    onPressed: _controller.isLoading
                        ? null
                        : () => _controller.unloadModel(item),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                    ),
                    child: const Text('Unload'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _controller.isLoading
                        ? null
                        : () => _confirmDeleteModel(
                            modelName: item.displayName,
                            onConfirm: () => _controller.deleteModel(item),
                          ),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.textTertiary,
                      size: 20,
                    ),
                    tooltip: 'Delete Model File',
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateBadge(ModelDownloadState state) {
    Color bg;
    Color fg;
    String label;

    switch (state) {
      case ModelDownloadState.loaded:
        bg = AppColors.successLight;
        fg = AppColors.success;
        label = 'LOADED';
        break;
      case ModelDownloadState.loading:
        bg = AppColors.primaryLight;
        fg = AppColors.primary;
        label = 'LOADING...';
        break;
      case ModelDownloadState.downloaded:
        bg = AppColors.secondaryLight;
        fg = AppColors.secondary;
        label = 'DOWNLOADED';
        break;
      case ModelDownloadState.downloading:
        bg = AppColors.primaryLight;
        fg = AppColors.primary;
        label = 'DOWNLOADING';
        break;
      case ModelDownloadState.error:
        bg = AppColors.errorLight;
        fg = AppColors.error;
        label = 'ERROR';
        break;
      case ModelDownloadState.notDownloaded:
        bg = AppColors.background;
        fg = AppColors.textTertiary;
        label = 'GET';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }

  Widget _buildStorageFolderCard() {
    final isConfigured = _controller.isStorageConfigured;
    final location = _controller.storageLocationDisplay ?? 'Not configured';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isConfigured ? AppColors.border : Colors.amber.shade400,
          width: isConfigured ? 1.0 : 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isConfigured ? Icons.folder_outlined : Icons.folder_open,
                color: isConfigured ? AppColors.primary : Colors.amber.shade800,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isConfigured
                      ? 'Model Storage Directory'
                      : 'Storage Directory Required',
                  style: AppTypography.labelLarge.copyWith(
                    color: isConfigured
                        ? AppColors.textPrimary
                        : Colors.amber.shade900,
                  ),
                ),
              ),
              if (isConfigured)
                OutlinedButton.icon(
                  onPressed:
                      _controller.isLoading || _controller.hasActiveDownloads
                      ? null
                      : _controller.changeStorageFolder,
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('Change'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (isConfigured) ...[
            Text(
              location,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ] else ...[
            const Text(
              'Please select a storage directory on your device. Curated models and any models placed in this directory will be organized into llm/ and whisper/ subfolders.',
              style: AppTypography.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _controller.isLoading || _controller.hasActiveDownloads
                  ? null
                  : _controller.chooseStorageFolder,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Select Storage Folder'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUnconfiguredCatalogPlaceholder() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.lock_outline, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 8),
            const Text(
              'Model Catalog Unavailable',
              style: AppTypography.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Configure your storage directory above to browse, download, and manage local models.',
              style: AppTypography.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomModelsInfoCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Custom Models', style: AppTypography.labelLarge),
                SizedBox(height: 4),
                Text(
                  'Drop any .gguf files directly into the "llm/" subfolder, or Whisper models into "whisper/". They will be automatically recognized and listed above.',
                  style: AppTypography.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLlamaRuntimeCard() {
    final settings = _controller.llamaSettings;
    final activeInfo = _controller.activeBackendInfo;
    final plugin = _controller.aiService.pluginInfo;
    final backends = plugin.builtinBackends.isEmpty
        ? _controller.availableBackends
        : plugin.builtinBackends;
    final hasLoadedModel = _controller.aiService.llmEngine.isLoaded;
    final usesSmallerBatches =
        hasLoadedModel &&
        activeInfo.backend == 'vulkan' &&
        (activeInfo.batchSize < settings.resolvedBatchSize ||
            activeInfo.ubatchSize < settings.resolvedMicroBatchSize);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Active Backend Status Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.memory,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Active Runtime Status',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryDark,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        hasLoadedModel
                            ? activeInfo.backend.toUpperCase()
                            : 'NOT LOADED',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  hasLoadedModel
                      ? 'Device: ${activeInfo.deviceName.isNotEmpty ? activeInfo.deviceName : "CPU"}'
                      : 'Load an AI model to activate a runtime.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (hasLoadedModel) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Context: ${activeInfo.contextLength} tokens • Threads: ${activeInfo.threads} • Batch: ${activeInfo.batchSize} • Microbatch: ${activeInfo.ubatchSize}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                if (usesSmallerBatches) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'GPU compatibility mode uses smaller batches on this device. Longer questions may take more time to process.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                if (hasLoadedModel && activeInfo.backend == 'opencl') ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Experimental mixed GPU/CPU runtime: Q4_K and Q6_K matrix multiplication runs on GPU. Other operations and the KV cache stay on CPU; speed depends on the model.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Backend Preference Selection
          if (_controller.isLoading) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text(
              'Updating models and settings…',
              style: AppTypography.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
          const Text(
            'Hardware Backend Preference',
            style: AppTypography.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _backendBusy ? null : _openBenchmark,
                icon: const Icon(Icons.speed),
                label: const Text('Benchmark'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _backendBusy ||
                        !_controller.aiService.backendPlugins.supported
                    ? null
                    : _importBackend,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...LlamaBackendPreference.values.map((pref) {
            final bInfo = backends.firstWhere(
              (b) => b.backend.toLowerCase() == pref.name.toLowerCase(),
              orElse: () => LlamaBackendInfo(
                backend: pref.name,
                compiled:
                    pref == LlamaBackendPreference.auto ||
                    pref == LlamaBackendPreference.cpu,
                available:
                    pref == LlamaBackendPreference.auto ||
                    pref == LlamaBackendPreference.cpu,
                deviceName: pref == LlamaBackendPreference.cpu ? 'CPU' : '',
              ),
            );

            final isUsable =
                pref == LlamaBackendPreference.auto ||
                (bInfo.compiled && bInfo.available);

            return InkWell(
              onTap: isUsable && !_backendBusy
                  ? () => _backendAction(
                      () => _controller.aiService.selectBackend(
                        '',
                        preference: pref,
                      ),
                    )
                  : null,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      !plugin.external && settings.backend == pref
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: isUsable
                          ? (!plugin.external && settings.backend == pref
                                ? AppColors.primary
                                : AppColors.textSecondary)
                          : AppColors.textTertiary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              Text(
                                pref.label,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: isUsable
                                      ? AppColors.textPrimary
                                      : AppColors.textTertiary,
                                ),
                              ),
                              if (bInfo.deviceName.isNotEmpty &&
                                  pref != LlamaBackendPreference.auto) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '(${bInfo.deviceName})',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                              if (!isUsable &&
                                  pref != LlamaBackendPreference.auto) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    !bInfo.compiled
                                        ? 'Not Compiled'
                                        : 'No Device',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            pref.description,
                            style: TextStyle(
                              fontSize: 11,
                              color: isUsable
                                  ? AppColors.textSecondary
                                  : AppColors.textTertiary,
                            ),
                          ),
                          if (!isUsable && bInfo.reasonUnavailable != null)
                            Text(
                              bInfo.reasonUnavailable!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),

          ...plugin.installed.map(
            (backend) => Material(
              color: Colors.transparent,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(
                  plugin.id == backend.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: plugin.id == backend.id
                      ? AppColors.primary
                      : AppColors.textSecondary,
                ),
                title: Text(backend.name),
                subtitle: Text(
                  '${backend.engine} · ${backend.version} · ${backend.backendType}',
                ),
                onTap: _backendBusy
                    ? null
                    : () => _backendAction(
                        () => _controller.aiService.selectBackend(backend.id),
                      ),
                trailing: IconButton(
                  tooltip: 'Delete ${backend.name}',
                  onPressed: _backendBusy
                      ? null
                      : () => _backendAction(
                          () => _controller.aiService.deleteBackend(backend.id),
                        ),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
          ),

          const Divider(height: 24),

          // Advanced Options Expansion
          Material(
            color: Colors.transparent,
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text(
                  'Advanced llama.cpp Parameters',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Context size, CPU threads, and Flash Attention',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                children: [
                  const SizedBox(height: 8),

                  // CPU Threads
                  _buildSliderTile(
                    title: 'CPU Threads',
                    subtitle: _draftThreads == null && settings.threads == null
                        ? 'Auto (Default 4)'
                        : 'Custom: ${_draftThreads ?? settings.threads} threads',
                    value: (_draftThreads ?? settings.threads ?? 4).toDouble(),
                    min: 1,
                    max: 16,
                    divisions: 15,
                    displayValue:
                        _draftThreads == null && settings.threads == null
                        ? 'Auto'
                        : '${_draftThreads ?? settings.threads}',
                    enabled: !_controller.isLoading,
                    onChanged: (val) {
                      setState(() => _draftThreads = val.round());
                    },
                    onChangeEnd: (val) async {
                      await _controller.updateLlamaSettings(
                        settings.copyWith(threads: val.round()),
                      );
                      if (mounted) setState(() => _draftThreads = null);
                    },
                  ),
                  const Divider(height: 16),

                  // Context Length
                  _buildContextSelector(settings),
                  const Divider(height: 16),

                  // Flash Attention
                  _buildFlashAttentionSelector(settings),
                  const Divider(height: 16),

                  // Reset button
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _controller.isLoading
                          ? null
                          : () => _controller.resetLlamaSettings(),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Reset llama.cpp Settings'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextSelector(LlamaRuntimeSettings settings) {
    const options = [512, 1024, 2048, 4096, 8192];
    final currentCtx = settings.contextLength;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Text('Context Length', style: AppTypography.labelLarge),
            ),
            Text(
              currentCtx == null ? 'Auto (2048)' : '$currentCtx tokens',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Maximum tokens held in working memory (KV Cache)',
          style: AppTypography.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Auto (2048)'),
              selected: currentCtx == null,
              onSelected: _controller.isLoading
                  ? null
                  : (selected) {
                      if (selected) {
                        _controller.updateLlamaSettings(
                          settings.copyWith(contextLength: null),
                        );
                      }
                    },
            ),
            ...options.map((opt) {
              return ChoiceChip(
                label: Text('$opt'),
                selected: currentCtx == opt,
                onSelected: _controller.isLoading
                    ? null
                    : (selected) {
                        if (selected) {
                          _controller.updateLlamaSettings(
                            settings.copyWith(contextLength: opt),
                          );
                        }
                      },
              );
            }),
          ],
        ),
      ],
    );
  }

  Widget _buildFlashAttentionSelector(LlamaRuntimeSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Text('Flash Attention', style: AppTypography.labelLarge),
            ),
            Text(
              settings.flashAttention.name.toUpperCase(),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Memory-efficient attention computation (if supported by model)',
          style: AppTypography.bodySmall,
        ),
        const SizedBox(height: 8),
        SegmentedButton<LlamaFlashAttention>(
          segments: const [
            ButtonSegment(value: LlamaFlashAttention.auto, label: Text('Auto')),
            ButtonSegment(value: LlamaFlashAttention.on, label: Text('On')),
            ButtonSegment(value: LlamaFlashAttention.off, label: Text('Off')),
          ],
          selected: {settings.flashAttention},
          onSelectionChanged: _controller.isLoading
              ? null
              : (set) {
                  _controller.updateLlamaSettings(
                    settings.copyWith(flashAttention: set.first),
                  );
                },
        ),
      ],
    );
  }

  Widget _buildSliderTile({
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String displayValue,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(title, style: AppTypography.labelLarge)),
            Text(
              displayValue,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        Text(subtitle, style: AppTypography.bodySmall),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: AppColors.primary,
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? onChangeEnd : null,
        ),
      ],
    );
  }
}
