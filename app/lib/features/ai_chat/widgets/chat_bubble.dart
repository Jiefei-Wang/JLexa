import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../core/ai/ai_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final ValueChanged<String> onSpeak;
  final VoidCallback? onDelete;
  final bool isSpeaking;
  final bool canSpeak;

  const ChatBubble({
    super.key,
    required this.message,
    required this.onSpeak,
    this.onDelete,
    this.isSpeaking = false,
    this.canSpeak = true,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryLight,
              ),
              child: const Icon(
                Icons.psychology,
                size: 20,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isUser ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: isUser ? null : Border.all(color: AppColors.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(5),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isUser)
                    SelectableText(
                      message.content,
                      style: AppTypography.bodyMedium.copyWith(
                        color: isUser ? Colors.white : AppColors.textPrimary,
                      ),
                    )
                  else
                    MarkdownBody(
                      data: message.content,
                      selectable: true,
                      fitContent: true,
                      styleSheet:
                          MarkdownStyleSheet.fromTheme(Theme.of(context))
                              .copyWith(
                                p: AppTypography.bodyMedium,
                                tableColumnWidth: const IntrinsicColumnWidth(),
                                tableScrollbarThumbVisibility: true,
                              ),
                      // Generated images are descriptions only. Never fetch a
                      // model-provided network, asset, or local-file location.
                      imageBuilder: (uri, title, alt) => Text(
                        alt?.isNotEmpty == true
                            ? 'Image: $alt'
                            : 'Image omitted',
                        style: AppTypography.bodySmall,
                      ),
                      onTapLink: (text, href, title) {
                        if (href == null) return;
                        showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Link'),
                            content: SingleChildScrollView(
                              child: SelectableText(href),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: href));
                                  Navigator.pop(context);
                                },
                                child: const Text('Copy link'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  if (message.audioTimestampLabel != null ||
                      !isUser ||
                      onDelete != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (message.audioTimestampLabel != null)
                          Text(
                            message.audioTimestampLabel!,
                            style: TextStyle(
                              fontSize: 10,
                              color: isUser
                                  ? Colors.white70
                                  : AppColors.textTertiary,
                            ),
                          ),
                        if (!isUser)
                          IconButton(
                            tooltip: isSpeaking
                                ? 'Stop reading aloud'
                                : 'Read answer aloud',
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            onPressed: canSpeak
                                ? () => onSpeak(message.content)
                                : null,
                            icon: Icon(
                              isSpeaking
                                  ? Icons.stop_circle_outlined
                                  : Icons.volume_up_outlined,
                            ),
                            color: AppColors.primary,
                          ),
                        if (onDelete != null)
                          IconButton(
                            tooltip: 'Delete message',
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            onPressed: onDelete,
                            icon: const Icon(Icons.delete_outline),
                            color: isUser
                                ? Colors.white70
                                : AppColors.textTertiary,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }
}
