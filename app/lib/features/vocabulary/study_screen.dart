import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/collection/collection_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_repository.dart';
import '../collection/collection_screen.dart';
import 'vocabulary_screen.dart';

class StudyScreen extends StatefulWidget {
  final VocabularyRepository vocabularyRepo;
  final CollectionRepository collectionRepo;
  final ValueChanged<String> onOpenWordInDictionary;
  final bool isActive;
  final Future<void> Function()? onBeforeCollectionPlay;
  @visibleForTesting
  final AudioPlayer Function()? collectionPlayerFactory;

  const StudyScreen({
    super.key,
    required this.vocabularyRepo,
    required this.collectionRepo,
    required this.onOpenWordInDictionary,
    this.isActive = true,
    this.onBeforeCollectionPlay,
    this.collectionPlayerFactory,
  });

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Study', style: AppTypography.titleMedium),
        bottom: TabBar(
          labelStyle: AppTypography.labelLarge,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          onTap: (index) {
            FocusScope.of(context).unfocus();
            setState(() => _tab = index);
          },
          tabs: [
            for (final title in ['Vocabulary', 'Collection'])
              Tab(
                height: (MediaQuery.textScalerOf(context).scale(14) * 2 + 16)
                    .clamp(48, double.infinity),
                child: Text(title, textAlign: TextAlign.center, softWrap: true),
              ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          VocabularyScreen(
            vocabularyRepo: widget.vocabularyRepo,
            onOpenWordInDictionary: widget.onOpenWordInDictionary,
            embedded: true,
          ),
          CollectionScreen(
            collectionRepo: widget.collectionRepo,
            isActive: widget.isActive && _tab == 1,
            onBeforePlay: widget.onBeforeCollectionPlay,
            playerFactory: widget.collectionPlayerFactory,
          ),
        ],
      ),
    ),
  );
}
