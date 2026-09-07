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
  final VoidCallback? onAddToCollection;
  final bool isSavingToCollection;
  final bool isTranscribing;
  final bool isCancelling;
  final double? progress;
  final VoidCallback? onCancel;
  final String? error;
  const TranscriptView({
    super.key,
    required this.segment,
    required this.auto,
    required this.onAutoChanged,
    this.onTranscribe,
    required this.onWordTap,
    this.onPlaySentence,
    this.onAddToCollection,
    this.isSavingToCollection = false,
    this.isTranscribing = false,
    this.isCancelling = false,
    this.progress,
    this.onCancel,
    this.error,
  });

  List<String> _displayParts(String text) => RegExp(
    r"[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’\-][A-Za-zÀ-ÖØ-öø-ÿ]+)*|[^A-Za-zÀ-ÖØ-öø-ÿ\s]+",
  ).allMatches(text).map((m) => m.group(0)!).toList();
  bool _isWord(String s) => RegExp(r'[A-Za-zÀ-ÖØ-öø-ÿ]').hasMatch(s);

  @override
  Widget build(BuildContext context) {
    final text = segment?.text.trim() ?? '';
    final confidence = segment?.confidence ?? -1;
    final busy = isTranscribing || isCancelling;
    final reportedProgress = progress;
    final fraction =
        !isCancelling &&
            reportedProgress != null &&
            reportedProgress.isFinite &&
            reportedProgress > 0
        ? reportedProgress.clamp(0.0, 1.0)
        : null;
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
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
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
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: TextButton.icon(
                          onPressed: busy ? null : onTranscribe,
                          icon: busy
                              ? SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    value: fraction,
                                    strokeWidth: 2,
                                    semanticsLabel: isCancelling
                                        ? 'Cancelling transcription'
                                        : 'Transcribing',
                                  ),
                                )
                              : const Icon(Icons.subtitles, size: 17),
                          label: Text(
                            isCancelling
                                ? 'Cancelling…'
                                : isTranscribing
                                ? fraction == null
                                      ? 'Transcribing…'
                                      : 'Transcribing ${(fraction * 100).round()}%'
                                : 'Transcribe',
                          ),
                        ),
                      ),
                      if (busy)
                        IconButton(
                          tooltip: isCancelling
                              ? 'Cancelling transcription'
                              : 'Cancel transcription',
                          visualDensity: VisualDensity.compact,
                          onPressed: isCancelling ? null : onCancel,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                    ],
                  ),
                ),
                if (confidence >= 0 && confidence <= 1)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('Confidence ${(confidence * 100).round()}%'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (error != null && !busy)
            Text(error!, style: const TextStyle(color: AppColors.error)),
          if (text.isEmpty && !busy && error == null)
            const Text(
              'No transcript is displayed for the active cut.',
              style: AppTypography.bodySmall,
            )
          else if (text.isNotEmpty)
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
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: busy || isSavingToCollection
                          ? null
                          : onAddToCollection,
                      icon: isSavingToCollection
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.library_add_outlined, size: 20),
                      label: Text(
                        isSavingToCollection ? 'Saving…' : 'Add to Collection',
                      ),
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
