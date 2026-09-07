import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/collection/collection_models.dart';
import '../../core/collection/collection_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'collection_playback_controller.dart';

class CollectionScreen extends StatefulWidget {
  final CollectionRepository collectionRepo;
  final bool isActive;
  final Future<void> Function()? onBeforePlay;
  final AudioPlayer Function()? playerFactory;

  const CollectionScreen({
    super.key,
    required this.collectionRepo,
    this.isActive = true,
    this.onBeforePlay,
    this.playerFactory,
  });

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen>
    with WidgetsBindingObserver {
  late final CollectionPlaybackController _playback;
  List<CollectionClip> _clips = [];
  bool _loading = true;
  String? _loadError;
  int _loadGeneration = 0;
  bool _foreground = true;
  bool _routeCurrent = true;
  final Set<String> _deleting = {};
  double? _seekPreview;
  String? _previewClipId;

  @override
  void initState() {
    super.initState();
    _foreground =
        (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _playback = CollectionPlaybackController(
      repository: widget.collectionRepo,
      onBeforePlay: () async {
        await widget.onBeforePlay?.call();
      },
      playerFactory: widget.playerFactory,
    );
    _playback.setActive(widget.isActive && _foreground);
    widget.collectionRepo.addListener(_onCollectionChanged);
    unawaited(_loadClips());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _updateActivity();
  }

  @override
  void didUpdateWidget(covariant CollectionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateActivity();
  }

  void _updateActivity() =>
      _playback.setActive(widget.isActive && _foreground && _routeCurrent);

  void _onCollectionChanged() => unawaited(_loadClips());

  Future<void> _loadClips() async {
    final generation = ++_loadGeneration;
    try {
      final clips = await widget.collectionRepo.getClips();
      if (!mounted || generation != _loadGeneration) return;
      final selected = _playback.clip;
      if (selected != null && !clips.any((clip) => clip.id == selected.id)) {
        unawaited(_playback.forget(selected.id));
      }
      setState(() {
        _clips = clips;
        _loading = false;
        _loadError = null;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load your collection. Please try again.';
      });
    }
  }

  Future<void> _deleteClip(CollectionClip clip) async {
    if (!_deleting.add(clip.id)) return;
    setState(() {});
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Delete saved clip?'),
          content: Text(
            'Delete the saved audio and transcript from “${clip.sourceTitle}”?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _playback.forget(clip.id);
      await widget.collectionRepo.deleteClip(clip);
      await _loadClips();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Clip deleted')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not delete this clip. Please try again.'),
          ),
        );
      }
    } finally {
      _deleting.remove(clip.id);
      if (mounted) setState(() {});
    }
  }

  String _time(int milliseconds, {bool precise = false}) {
    final ms = milliseconds < 0 ? 0 : milliseconds;
    final seconds = ms ~/ 1000;
    final fraction = precise && ms % 1000 != 0
        ? '.${(ms % 1000).toString().padLeft(3, '0')}'
        : '';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}$fraction';
  }

  Widget _clipCard(CollectionClip clip) {
    final selected = _playback.clip?.id == clip.id;
    final preparing = selected && _playback.isPreparing;
    final playing = selected && _playback.isPlaying;
    final duration = selected
        ? _playback.duration.inMilliseconds
        : clip.durationMs;
    final position = selected ? _playback.position.inMilliseconds : 0;
    final preview = _previewClipId == clip.id ? _seekPreview : null;
    return Card(
      margin: EdgeInsets.zero,
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    clip.sourceTitle,
                    style: AppTypography.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Delete clip',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _deleting.contains(clip.id)
                      ? null
                      : () => _deleteClip(clip),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text(
              '${_time(clip.sourceStartMs, precise: true)}–${_time(clip.sourceEndMs, precise: true)} in original audio',
              style: AppTypography.bodySmall,
            ),
            const SizedBox(height: 12),
            if (selected && _playback.error != null) ...[
              const SizedBox(height: 12),
              Text(
                _playback.error!,
                style: AppTypography.bodyMedium.copyWith(
                  color: AppColors.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _deleting.contains(clip.id)
                      ? null
                      : () => _playback.toggle(clip),
                  icon: preparing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(playing ? Icons.pause : Icons.play_arrow),
                  label: Text(
                    preparing
                        ? 'Cancel'
                        : playing
                        ? 'Pause'
                        : 'Play',
                  ),
                ),
                if (selected)
                  IconButton(
                    tooltip: 'Replay clip',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: preparing || _deleting.contains(clip.id)
                        ? null
                        : () => _playback.play(clip, replay: true),
                    icon: const Icon(Icons.replay),
                  ),
                Text(
                  '${_time(position)} / ${_time(duration)}',
                  style: AppTypography.bodySmall,
                ),
              ],
            ),
            if (selected)
              Semantics(
                label: 'Clip position',
                child: Slider(
                  value: (preview ?? position.toDouble()).clamp(
                    0,
                    duration > 0 ? duration.toDouble() : 1,
                  ),
                  max: duration > 0 ? duration.toDouble() : 1,
                  semanticFormatterCallback: (value) =>
                      '${_time(value.round())} of ${_time(duration)}',
                  onChanged: !_playback.canSeek || duration <= 0
                      ? null
                      : (value) => setState(() {
                          _previewClipId = clip.id;
                          _seekPreview = value;
                        }),
                  onChangeEnd: (value) {
                    setState(() => _seekPreview = null);
                    unawaited(
                      _playback.seek(Duration(milliseconds: value.round())),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            SelectableText(
              clip.transcript.isEmpty
                  ? 'No transcript was saved for this clip.'
                  : clip.transcript,
              style: AppTypography.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _playback,
    builder: (context, _) => SafeArea(
      top: false,
      child: RefreshIndicator(
        onRefresh: _loadClips,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_loadError != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: _loadClips,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_clips.isEmpty && _loadError == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.bookmarks_outlined,
                        size: 48,
                        color: AppColors.primary,
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Your saved listening clips',
                        style: AppTypography.titleSmall,
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'In Listening, transcribe a segment and save it to Collection. Its audio and transcript stay together here.',
                        style: AppTypography.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList.separated(
                  itemCount: _clips.length,
                  itemBuilder: (context, index) => _clipCard(_clips[index]),
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    ++_loadGeneration;
    WidgetsBinding.instance.removeObserver(this);
    widget.collectionRepo.removeListener(_onCollectionChanged);
    _playback.dispose();
    super.dispose();
  }
}
