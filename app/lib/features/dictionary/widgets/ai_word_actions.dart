import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class AiWordActionsSection extends StatefulWidget {
  final String word;
  final ValueChanged<String> onAskPrompt;
  final bool isGenerating;

  const AiWordActionsSection({
    super.key,
    required this.word,
    required this.onAskPrompt,
    this.isGenerating = false,
  });

  @override
  State<AiWordActionsSection> createState() => _AiWordActionsSectionState();
}

class _AiWordActionsSectionState extends State<AiWordActionsSection> {
  final TextEditingController _customQuestionController = TextEditingController();

  @override
  void dispose() {
    _customQuestionController.dispose();
    super.dispose();
  }

  void _sendCustom() {
    final text = _customQuestionController.text.trim();
    if (text.isNotEmpty) {
      widget.onAskPrompt(text);
      _customQuestionController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              Text('Ask AI about "${widget.word}"', style: AppTypography.titleSmall),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Beta', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.primary)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPromptChip('Use in a sentence', 'Generate 3 natural example sentences with collocations'),
                _buildPromptChip('Similar words', 'Compare synonyms and explain subtle nuance differences'),
                _buildPromptChip('Collocations', 'Show common collocations and idioms with this word'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customQuestionController,
                  onSubmitted: (_) => _sendCustom(),
                  decoration: InputDecoration(
                    hintText: 'Ask anything about this word...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: widget.isGenerating ? null : _sendCustom,
                icon: widget.isGenerating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPromptChip(String label, String prompt) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w500)),
        backgroundColor: AppColors.primaryLight,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onPressed: () => widget.onAskPrompt(prompt),
      ),
    );
  }
}
