import 'package:flutter/material.dart';

import '../../core/ai/ai_service.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/audio_service.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/audio/waveform_service.dart';
import '../../core/collection/collection_repository.dart';
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
  final CollectionRepository? collectionRepo;
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
    this.collectionRepo,
    this.activeLesson,
    required this.onOpenAiChat,
    required this.onImportAudio,
  });

  @override
  State<RepeaterScreen> createState() => RepeaterScreenState();
}

class RepeaterScreenState extends State<RepeaterScreen> {
  late final RepeaterController _controller;
  late final CollectionRepository _collectionRepo;
  bool _savingCollection = false;

  Future<void> prepareLessonDeletion(String lessonId) =>
      _controller.prepareLessonDeletion(lessonId);

  @override
  void initState() {
    super.initState();
    _collectionRepo = widget.collectionRepo ?? CollectionRepository();
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
    } else if (widget.activeLesson == null && oldWidget.activeLesson != null) {
      _controller.clearLesson();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    if (widget.collectionRepo == null) _collectionRepo.dispose();
    super.dispose();
  }

  void _showWordExplanation(String word) {
    final curSentence = _controller.visibleTranscriptSegment?.text ?? '';
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

  Future<void> _saveToCollection() async {
    final lesson = _controller.lesson;
    final segment = _controller.visibleTranscriptSegment;
    if (_savingCollection || lesson == null || segment == null) return;
    setState(() => _savingCollection = true);
    try {
      await _collectionRepo.saveSegment(
        lesson: lesson.copyWith(durationMs: _controller.durationMs),
        segment: segment,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to Collection in Study.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save this audio clip. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingCollection = false);
    }
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
              PopupMenuButton<String>(
                tooltip: 'Lesson options',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) async {
                  if (value == 'import') {
                    widget.onImportAudio();
                    return;
                  }
                  final redo = value == 'segments';
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(
                        redo ? 'Redo segments?' : 'Reset transcripts?',
                      ),
                      content: Text(
                        redo
                            ? 'Replace this lesson’s saved segments with detected speech regions? Their transcripts will also be cleared.'
                            : 'Clear cached transcripts for every segment in this lesson? Segment boundaries will stay the same.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true || !mounted) return;
                  if (redo) {
                    await _controller.redoSegments();
                  } else {
                    await _controller.resetTranscripts();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'import',
                    child: Text('Import audio'),
                  ),
                  PopupMenuItem(
                    value: 'segments',
                    enabled:
                        lesson != null &&
                        !_controller.isEditingCuts &&
                        !_controller.isWaveformLoading,
                    child: const Text('Redo segments'),
                  ),
                  PopupMenuItem(
                    value: 'transcripts',
                    enabled: lesson != null && !_controller.isEditingCuts,
                    child: const Text('Reset transcripts'),
                  ),
                ],
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
                    if (_controller.notice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _controller.notice!,
                          style: AppTypography.bodySmall,
                        ),
                      ),
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
                    if (_controller.isWaveformLoading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Preparing waveform and speech segments…'),
                            SizedBox(height: 8),
                            LinearProgressIndicator(),
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
                                  'No speech cuts',
                                  style: AppTypography.titleSmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'No speech activity was detected. Move the playhead onto speech and use Add Cut.',
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

                    // Local waveform centered on the playhead.
                    WaveformView(
                      key: ValueKey(_controller.lesson?.id),
                      fullPeaks: _controller.fullWaveformPeaks,
                      totalDurationMs: _controller.durationMs,
                      currentPositionMs: _controller.positionMs,
                      segments: _controller.segments,
                      currentSegment: _controller.currentSegment,
                      waveformService: widget.waveformService,
                      onSeek: _controller.seekTo,
                      onSeekStart: _controller.beginWaveformSeek,
                      onSeekEnd: _controller.endWaveformSeek,
                      onAddCut: _controller.canAddCut
                          ? _controller.addCutAtPlayhead
                          : null,
                      onDeleteCut: _controller.canDeleteCut
                          ? _controller.deleteCurrentCut
                          : null,
                      onSegmentBoundsChanged: (id, revision, newStart, newEnd) {
                        _controller.updateSegmentBounds(
                          segmentId: id,
                          expectedRevision: revision,
                          newStartMs: newStart,
                          newEndMs: newEnd,
                        );
                      },
                    ),
                    const SizedBox(height: 14),

                    // Adjust Segment controls & Main Playback bar
                    SegmentControls(
                      isPlaying: _controller.isPlaying,
                      isRepeatOne: _controller.isRepeatOne,
                      isAutoStop: _controller.isAutoStop,
                      onTogglePlay: _controller.togglePlayPause,
                      onToggleRepeatOne: _controller.toggleRepeatOne,
                      onToggleAutoStop: _controller.toggleAutoStop,
                      onPrevSentence: _controller.previousSentence,
                      onNextSentence: _controller.nextSentence,
                      onReplay: _controller.currentSegment == null
                          ? null
                          : _controller.repeatCurrentSentence,
                    ),
                    const SizedBox(height: 16),

                    // Transcript Card
                    TranscriptView(
                      segment: _controller.visibleTranscriptSegment,
                      auto: _controller.autoTranscribe,
                      onAutoChanged: _controller.setAutoTranscribe,
                      isTranscribing: _controller.isTranscribing,
                      isCancelling:
                          _controller.transcriptionState ==
                          TranscriptionState.cancelling,
                      progress: _controller.transcriptionProgress,
                      onCancel: _controller.cancelTranscription,
                      error: _controller.transcriptionError,
                      onTranscribe:
                          _controller.currentSegment == null ||
                              _controller.isWhisperBusyElsewhere
                          ? null
                          : _controller.transcribeCurrentCut,
                      onWordTap: _showWordExplanation,
                      onPlaySentence: _controller.repeatCurrentSentence,
                      onAddToCollection: _saveToCollection,
                      isSavingToCollection: _savingCollection,
                    ),
                    const SizedBox(height: 16),

                    // AI Explanation Card
                    AiExplanationCard(
                      isExpanded: _controller.isAiCardExpanded,
                      onToggleExpand: _controller.toggleAiCardExpanded,
                      explanation: _controller.aiExplanation,
                      isGenerating: _controller.isAiGenerating,
                      onOpenQa: _handleOpenQa,
                      onGenerate: _controller.generateExplanation,
                      onCancel: _controller.cancelExplanation,
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
        );
      },
    );
  }
}
