import 'package:markdown/markdown.dart' as md;

/// Read the displayed words aloud, rather than Markdown punctuation or URLs.
String chatPlainText(String source) {
  final document = md.Document(
    encodeHtml: false,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  String text(md.Node node) {
    if (node is md.Text) return node.text;
    if (node is! md.Element) return '';
    if (node.tag == 'img') return node.attributes['alt'] ?? '';
    final content = (node.children ?? const <md.Node>[]).map(text).join();
    const blocks = {
      'p',
      'li',
      'h1',
      'h2',
      'h3',
      'h4',
      'pre',
      'br',
      'tr',
      'td',
      'th',
    };
    return blocks.contains(node.tag) ? '$content\n' : content;
  }

  return document
      .parseLines(source.split('\n'))
      .map(text)
      .join('\n')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
