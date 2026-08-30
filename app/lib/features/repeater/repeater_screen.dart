import 'package:flutter/material.dart';

import '../../core/ai/ai_service.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/audio_service.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/audio/waveform_service.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_repository.dart';
import 'repeater_controller.dart';
import 'widgets/ai_explanation_card.dart';
import 'widgets/progress_scrubber.dart';
import 'widgets/segment_controls.dart';
import 'widgets/transcript_view.dart';
import 'widgets/waveform_view.dart';
import 'widgets/word_explanation_sheet.dart';

class RepeaterScreen extends StatefulWidget {
  final LessonRepository lessonRepo;
  final AudioService audioService;
  final WaveformService waveformService;
  final AiService aiService;
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final AudioLesson? activeLesson;
  final void Function({
    required String lessonTitle,
    required String sentenceText,
    String? prevSentence,
    String? nextSentence,
    int startMs,
    int endMs,
    List<String> uncertainWords,
  })
  onOpenAiChat;
  final VoidCallback onImportAudio;

  const RepeaterScreen({
    super.key,
    required this.lessonRepo,
    required this.audioService,
    required this.waveformService,
    required this.aiService,
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    this.activeLesson,
    required this.onOpenAiChat,
    required this.onImportAudio,
  });

  @override
  State<RepeaterScreen> createState() => _RepeaterScreenState();
}

class _RepeaterScreenState extends State<RepeaterScreen> {
  late final RepeaterController _controller;

  @override
  void initState() {
    super.initState();
    _controller = RepeaterController(
      lessonRepo: widget.lessonRepo,
      audioService: widget.audioService,
      waveformService: widget.waveformService,
      aiService: widget.aiService,
      initialLesson: widget.activeLesson,
    );
  }

  @override
  void didUpdateWidget(covariant RepeaterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeLesson != null &&
        widget.activeLesson?.id != oldWidget.activeLesson?.id) {
      _controller.loadLesson(widget.activeLesson!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showWordExplanation(String word) {
    final curSentence = _controller.currentSegment?.text ?? '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WordExplanationSheet(
        word: word,
        sentenceText: curSentence,
        dictionaryRepo: widget.dictionaryRepo,
        vocabularyRepo: widget.vocabularyRepo,
        aiService: widget.aiService,
      ),
    );
  }

  void _handleOpenQa() {
    final ctx = _controller.getCurrentSentenceContext();
    widget.onOpenAiChat(
      lessonTitle: ctx.lessonTitle,
      sentenceText: ctx.sentenceText,
      prevSentence: ctx.previousSentence,
      nextSentence: ctx.nextSentence,
      startMs: ctx.startMs,
      endMs: ctx.endMs,
      uncertainWords: ctx.uncertainWords,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final lesson = _controller.lesson;

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0,
            title: Text(
              lesson?.title ?? 'Listening Practice',
              style: AppTypography.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                icon: const Icon(
                  Icons.file_upload_outlined,
                  color: AppColors.textPrimary,
                ),
                tooltip: 'Import Audio',
                onPressed: widget.onImportAudio,
              ),
            ],
          ),
          body: _controller.isLoading
              ? const Center(child: CircularProgressIndicator())
              : lesson == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.graphic_eq,
                          size: 64,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'No audio selected',
                          style: AppTypography.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Import an audio lesson or select one from the Home tab to begin practicing.',
                          style: AppTypography.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: widget.onImportAudio,
                          icon: const Icon(Icons.add),
                          label: const Text('Import Audio'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_controller.audioLoadError != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.errorLight,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.error),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: AppColors.error,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _controller.audioLoadError!,
                                style: const TextStyle(
                                  color: AppColors.error,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_controller.transcriptionState ==
                            TranscriptionState.transcribing ||
                        _controller.transcriptionState ==
                            TranscriptionState.cancelling)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _controller.transcriptionState ==
                                            TranscriptionState.cancelling
                                        ? 'Cancelling transcription...'
                                        : 'Transcribing with Whisper (${(_controller.transcriptionProgress * 100).toInt()}%)...',
                                    style: AppTypography.titleSmall,
                                  ),
                                ),
                                if (_controller.transcriptionState !=
                                    TranscriptionState.cancelling)
                                  TextButton(
                                    onPressed: _controller.cancelTranscription,
                                    child: const Text(
                                      'Cancel',
                                      style: TextStyle(color: AppColors.error),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value:
                                  _controller.transcriptionState ==
                                      TranscriptionState.cancelling
                                  ? null
                                  : (_controller.transcriptionProgress > 0
                                        ? _controller.transcriptionProgress
                                        : null),
                              backgroundColor: AppColors.border,
                              color: AppColors.primary,
                            ),
                          ],
                        ),
                      )
                    else if (_controller.segments.isEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
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
                                const Icon(
                                  Icons.subtitles_outlined,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'No Transcript Segments',
                                  style: AppTypography.titleSmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Generate synchronized sentence boundaries and text using on-device Whisper AI.',
                              style: AppTypography.bodySmall,
                            ),
                            if (_controller.transcriptionError != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                _controller.transcriptionError!,
                                style: const TextStyle(
                                  color: AppColors.error,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _controller.transcribeLesson,
                              icon: const Icon(Icons.auto_awesome, size: 18),
                              label: const Text('Transcribe with Whisper'),
                            ),
                          ],
                        ),
                      ),

                    // Total Progress Scrubber
                    ProgressScrubber(
                      positionMs: _controller.positionMs,
                      durationMs: _controller.durationMs,
                      onSeek: _controller.seekTo,
                    ),
                    const SizedBox(height: 14),

                    // Local Waveform (10 seconds)
                    WaveformView(
                      fullPeaks: _controller.fullWaveformPeaks,
                      totalDurationMs: _controller.durationMs,
                      currentPositionMs: _controller.positionMs,
                      currentSegment: _controller.currentSegment,
                      waveformService: widget.waveformService,
                      onSegmentBoundsChanged: (newStart, newEnd) {
                        if (_controller.currentSegment != null) {
                          _controller.updateSegmentBounds(
                            segmentId: _controller.currentSegment!.id,
                            newStartMs: newStart,
                            newEndMs: newEnd,
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 14),

                    // Adjust Segment controls & Main Playback bar
                    SegmentControls(
                      currentSegment: _controller.currentSegment,
                      snapToSpeech: _controller.snapToSpeechEnabled,
                      onToggleSnap: (_) => _controller.toggleSnapToSpeech(),
                      onCutStart: _controller.cutStartAtPlayhead,
                      onAddCut: _controller.addCutAtPlayhead,
                      onCutEnd: _controller.cutEndAtPlayhead,
                      onMergeNext: _controller.mergeWithNextSegment,
                      isPlaying: _controller.isPlaying,
                      isRepeatOne: _controller.isRepeatOne,
                      onTogglePlay: _controller.togglePlayPause,
                      onToggleRepeatOne: _controller.toggleRepeatOne,
                      onPrevSentence: _controller.previousSentence,
                      onNextSentence: _controller.nextSentence,
                    ),
                    const SizedBox(height: 16),

                    // Transcript Card
                    TranscriptView(
                      segment: _controller.currentSegment,
                      onWordTap: _showWordExplanation,
                      onPlaySentence: _controller.repeatCurrentSentence,
                    ),
                    const SizedBox(height: 16),

                    // AI Explanation Card
                    AiExplanationCard(
                      isExpanded: _controller.isAiCardExpanded,
                      onToggleExpand: _controller.toggleAiCardExpanded,
                      explanation: _controller.aiExplanation,
                      isGenerating: _controller.isAiGenerating,
                      onOpenQa: _handleOpenQa,
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
        );
      },
    );
  }
}
