import 'package:flutter/material.dart';
import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'settings_controller.dart';

class SettingsScreen extends StatefulWidget {
  final AiService aiService;

  const SettingsScreen({
    super.key,
    required this.aiService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SettingsController(aiService: widget.aiService);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final llmInfo = _controller.llmInfo;
        final speechInfo = _controller.speechInfo;

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            title: const Text('Settings & Local Models', style: AppTypography.titleMedium),
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
                        child: Text(_controller.errorMessage!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
                      ),
                    ],
                  ),
                ),

              // Section 1: Local LLM Model
              const Text('Local Language Model (LLM)', style: AppTypography.titleSmall),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.psychology, color: AppColors.accentPurple, size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(llmInfo?.name ?? 'No LLM Model Loaded', style: AppTypography.labelLarge),
                              Text(
                                llmInfo != null ? '${llmInfo.formattedSize} • Ready for offline inference' : 'Select a .gguf model file from local storage',
                                style: AppTypography.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: llmInfo?.isLoaded == true ? AppColors.successLight : AppColors.warningLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            llmInfo?.isLoaded == true ? 'Ready' : 'Not Loaded',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: llmInfo?.isLoaded == true ? AppColors.success : AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _controller.isLoading ? null : _controller.pickAndLoadLlmModel,
                            icon: const Icon(Icons.file_open, size: 18),
                            label: const Text('Choose GGUF Model'),
                          ),
                        ),
                        if (llmInfo?.isLoaded == true) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _controller.unloadLlmModel,
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                            child: const Text('Unload'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Section 2: Speech Recognition Model (Whisper)
              const Text('Speech Recognition Model (Whisper)', style: AppTypography.titleSmall),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.record_voice_over, color: AppColors.primary, size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(speechInfo?.name ?? 'No Whisper Model Loaded', style: AppTypography.labelLarge),
                              Text(
                                speechInfo != null ? '${speechInfo.formattedSize} • Ready for speech-to-text' : 'Select a ggml whisper model (.bin) file',
                                style: AppTypography.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: speechInfo?.isLoaded == true ? AppColors.successLight : AppColors.warningLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            speechInfo?.isLoaded == true ? 'Ready' : 'Not Loaded',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: speechInfo?.isLoaded == true ? AppColors.success : AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _controller.isLoading ? null : _controller.pickAndLoadSpeechModel,
                            icon: const Icon(Icons.file_open, size: 18),
                            label: const Text('Choose Whisper Model'),
                          ),
                        ),
                        if (speechInfo?.isLoaded == true) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _controller.unloadSpeechModel,
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                            child: const Text('Unload'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Section 3: AI Inference Settings
              const Text('Inference Configuration', style: AppTypography.titleSmall),
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
                      displayValue: widget.aiService.settings.temperature.toStringAsFixed(2),
                      onChanged: (val) {
                        widget.aiService.updateSettings(
                          AiGenerationSettings(
                            temperature: val,
                            maxTokens: widget.aiService.settings.maxTokens,
                            contextLength: widget.aiService.settings.contextLength,
                          ),
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
                          AiGenerationSettings(
                            temperature: widget.aiService.settings.temperature,
                            maxTokens: val.round(),
                            contextLength: widget.aiService.settings.contextLength,
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
            Text(displayValue, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary)),
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
