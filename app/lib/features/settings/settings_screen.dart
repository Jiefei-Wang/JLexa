import 'package:flutter/material.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/model_catalog.dart';
import '../../core/ai/model_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'settings_controller.dart';

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
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
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
          body: ListView(
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
                        icon: const Icon(
                          Icons.close,
                          size: 16,
                          color: AppColors.error,
                        ),
                        onPressed: _controller.clearError,
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
              ] else ...[
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
                  'Select an offline speech recognition model for audio lesson transcription.',
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
                      'JLexa 1.0.0 (Android-first)\nOffline Dictionary • Sentence Repeater • Spaced Repetition • Local AI Engine (llama.cpp / whisper.cpp)',
                      style: AppTypography.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _buildModelCard(ManagedModelItem item) {
    final isDownloading = item.state == ModelDownloadState.downloading;
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.displayName,
                            style: AppTypography.labelLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.isRecommended) ...[
                          const SizedBox(width: 6),
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
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
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
              _buildStateBadge(item.state),
            ],
          ),
          if (item.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(item.description, style: AppTypography.bodySmall),
          ],
          if (isDownloading) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  item.progress != null
                      ? 'Downloading: ${item.progress!.formattedReceived} / ${item.progress!.formattedTotal}'
                      : 'Downloading...',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.primary,
                  ),
                ),
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
                onPressed: () => _controller.cancelDownload(item.id),
                icon: const Icon(Icons.close, size: 16, color: AppColors.error),
                label: const Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (!isDownloaded && item.catalogModel != null)
                  FilledButton.tonalIcon(
                    onPressed: _controller.isLoading
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
                  onPressed: _controller.isLoading
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
              onPressed: _controller.isLoading
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
    final backends = _controller.availableBackends;

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
                    const Text(
                      'Active Runtime Status',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryDark,
                        fontSize: 14,
                      ),
                    ),
                    const Spacer(),
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
                        activeInfo.backend.toUpperCase(),
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
                  'Device: ${activeInfo.deviceName.isNotEmpty ? activeInfo.deviceName : "CPU"}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Context: ${activeInfo.contextLength} tokens • Threads: ${activeInfo.threads} • Batch: ${activeInfo.batchSize}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Backend Preference Selection
          const Text(
            'Hardware Backend Preference',
            style: AppTypography.labelLarge,
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
              onTap: isUsable
                  ? () => _controller.updateBackendPreference(pref)
                  : null,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      settings.backend == pref
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: isUsable
                          ? (settings.backend == pref
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
                          Row(
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),

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
                  'Context size, threads, batch sizes, and Flash Attention',
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
                    subtitle: settings.threads == null
                        ? 'Auto (Default 4)'
                        : 'Custom: ${settings.threads} threads',
                    value: (settings.threads ?? 4).toDouble(),
                    min: 1,
                    max: 16,
                    divisions: 15,
                    displayValue: settings.threads == null
                        ? 'Auto'
                        : '${settings.threads}',
                    onChanged: (val) {
                      _controller.updateLlamaSettings(
                        settings.copyWith(threads: val.round()),
                      );
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
                      onPressed: () => _controller.resetLlamaSettings(),
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
            const Text('Context Length', style: AppTypography.labelLarge),
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
              onSelected: (selected) {
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
                onSelected: (selected) {
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
            const Text('Flash Attention', style: AppTypography.labelLarge),
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
          onSelectionChanged: (set) {
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
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: AppTypography.labelLarge),
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
          onChanged: onChanged,
        ),
      ],
    );
  }
}
