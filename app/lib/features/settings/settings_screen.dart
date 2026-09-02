import 'package:flutter/material.dart';

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
                        icon: const Icon(Icons.close, size: 16, color: AppColors.error),
                        onPressed: _controller.clearError,
                      ),
                    ],
                  ),
                ),

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

              // Local LLM Import Box
              _buildImportBox(
                title: 'Have your own GGUF model?',
                buttonLabel: 'Import Local GGUF',
                icon: Icons.file_open,
                onTap: _controller.isLoading ? null : _controller.pickAndImportLlmModel,
              ),

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

              // Local Whisper Import Box
              _buildImportBox(
                title: 'Have your own Whisper model?',
                buttonLabel: 'Import Local Whisper Model',
                icon: Icons.file_open,
                onTap: _controller.isLoading
                    ? null
                    : _controller.pickAndImportSpeechModel,
              ),

              const SizedBox(height: 24),

              // ==========================================
              // Section 3: AI Inference Settings
              // ==========================================
              const Text(
                'Inference Configuration',
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
                      subtitle: 'Controls creativity vs determinism',
                      value: widget.aiService.settings.temperature,
                      min: 0.1,
                      max: 1.5,
                      divisions: 14,
                      displayValue: widget.aiService.settings.temperature
                          .toStringAsFixed(2),
                      onChanged: (val) {
                        widget.aiService.updateSettings(
                          widget.aiService.settings.copyWith(temperature: val),
                        );
                        setState(() {});
                      },
                    ),
                    const Divider(height: 20),
                    _buildSliderTile(
                      title: 'Max Output Tokens',
                      subtitle: 'Maximum length of generated answers',
                      value: widget.aiService.settings.maxTokens.toDouble(),
                      min: 128,
                      max: 2048,
                      divisions: 15,
                      displayValue: '${widget.aiService.settings.maxTokens}',
                      onChanged: (val) {
                        widget.aiService.updateSettings(
                          widget.aiService.settings.copyWith(
                            maxTokens: val.round(),
                          ),
                        );
                        setState(() {});
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
                item.type == ModelType.llm ? Icons.psychology : Icons.record_voice_over,
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
            Text(
              item.description,
              style: AppTypography.bodySmall,
            ),
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
                  style: const TextStyle(fontSize: 12, color: AppColors.primary),
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
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildImportBox({
    required String title,
    required String buttonLabel,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, style: BorderStyle.solid),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(title, style: AppTypography.labelLarge),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(buttonLabel),
          ),
        ],
      ),
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
