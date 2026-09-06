import 'package:flutter/material.dart';

import '../../../core/audio/audio_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class TranscriptView extends StatelessWidget {
  final AudioSegment? segment;
  final bool auto;
  final ValueChanged<bool> onAutoChanged;
  final VoidCallback? onTranscribe;
  final ValueChanged<String> onWordTap;
  final VoidCallback? onPlaySentence;
  const TranscriptView({
    super.key,
    required this.segment,
    required this.auto,
    required this.onAutoChanged,
    this.onTranscribe,
    required this.onWordTap,
    this.onPlaySentence,
  });

  List<String> _displayParts(String text) => RegExp(
    r"[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’\-][A-Za-zÀ-ÖØ-öø-ÿ]+)*|[^A-Za-zÀ-ÖØ-öø-ÿ\s]+",
  ).allMatches(text).map((m) => m.group(0)!).toList();
  bool _isWord(String s) => RegExp(r'[A-Za-zÀ-ÖØ-öø-ÿ]').hasMatch(s);

  @override
  Widget build(BuildContext context) {
    final text = segment?.text.trim() ?? '';
    final confidence = segment?.confidence ?? -1;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              const Text('Transcript', style: AppTypography.titleSmall),
              Checkbox(
                value: auto,
                onChanged: (v) => onAutoChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
              const Text('Auto', style: AppTypography.bodySmall),
              TextButton.icon(
                onPressed: onTranscribe,
                icon: const Icon(Icons.subtitles, size: 17),
                label: const Text('Transcribe'),
              ),
              if (confidence >= 0 && confidence <= 1)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('Confidence ${(confidence * 100).round()}%'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (text.isEmpty)
            const Text(
              'No transcript is displayed for the active cut.',
              style: AppTypography.bodySmall,
            )
          else
            Wrap(
              spacing: 4,
              runSpacing: 6,
              children: _displayParts(text)
                  .map(
                    (part) => _isWord(part)
                        ? InkWell(
                            onTap: () => onWordTap(part),
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 1,
                              ),
                              child: Text(
                                part,
                                style: AppTypography.transcript,
                              ),
                            ),
                          )
                        : Text(part, style: AppTypography.transcript),
                  )
                  .toList(),
            ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Tap a word to see its explanation',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
                if (onPlaySentence != null)
                  IconButton(
                    tooltip: 'Play this cut',
                    onPressed: onPlaySentence,
                    icon: const Icon(
                      Icons.volume_up_outlined,
                      color: AppColors.primary,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
