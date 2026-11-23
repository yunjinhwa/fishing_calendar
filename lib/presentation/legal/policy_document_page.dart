import 'package:flutter/material.dart';

enum PolicyDocument {
  terms(title: '이용약관', assetPath: 'assets/legal/terms.txt'),
  privacy(title: '개인정보 처리방침', assetPath: 'assets/legal/privacy.txt');

  const PolicyDocument({required this.title, required this.assetPath});

  final String title;
  final String assetPath;
}

/// Displays a bundled policy without changing any consent or account state.
class PolicyDocumentPage extends StatefulWidget {
  const PolicyDocumentPage({super.key, required this.document, this.bundle});

  final PolicyDocument document;
  final AssetBundle? bundle;

  @override
  State<PolicyDocumentPage> createState() => _PolicyDocumentPageState();
}

class _PolicyDocumentPageState extends State<PolicyDocumentPage> {
  AssetBundle? _loadedBundle;
  PolicyDocument? _loadedDocument;
  late Future<String> _documentFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDocument();
  }

  @override
  void didUpdateWidget(covariant PolicyDocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.bundle != widget.bundle) {
      _updateDocument();
    }
  }

  void _updateDocument() {
    final bundle = widget.bundle ?? DefaultAssetBundle.of(context);
    if (identical(_loadedBundle, bundle) &&
        _loadedDocument == widget.document) {
      return;
    }

    _loadedBundle = bundle;
    _loadedDocument = widget.document;
    _documentFuture = _readDocument(bundle, widget.document);
  }

  Future<String> _readDocument(
    AssetBundle bundle,
    PolicyDocument document,
  ) async {
    // This page retains its own future; retries must bypass a cached failure.
    final text = await bundle.loadString(document.assetPath, cache: false);
    if (text.trim().isEmpty) {
      throw const FormatException('The bundled policy document is empty.');
    }
    return text;
  }

  void _retry() {
    setState(() {
      _documentFuture = _readDocument(_loadedBundle!, widget.document);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.document.title)),
      body: SafeArea(
        child: FutureBuilder<String>(
          key: ObjectKey(_documentFuture),
          future: _documentFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('문서를 불러오는 중입니다.'),
                  ],
                ),
              );
            }

            if (snapshot.hasError || !snapshot.hasData) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '문서를 불러오지 못했습니다. 다시 시도해 주세요.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _retry,
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              );
            }

            return _PolicyArticle(text: snapshot.requireData);
          },
        ),
      ),
    );
  }
}

class _PolicyArticle extends StatelessWidget {
  const _PolicyArticle({required this.text});

  final String text;

  static final _sectionHeading = RegExp(r'^(?:제\d+조\(|\d+\.\s)');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final titleStyle = theme.textTheme.headlineSmall?.copyWith(
      color: colors.onSurface,
      fontWeight: FontWeight.w700,
    );
    final sectionStyle = theme.textTheme.titleMedium?.copyWith(
      color: colors.primary,
      fontWeight: FontWeight.w700,
      height: 1.65,
    );
    final metadataStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      height: 1.55,
    );

    final lines = text.split('\n');
    final spans = <TextSpan>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      TextStyle? style;
      if (index == 0) {
        style = titleStyle;
      } else if (_sectionHeading.hasMatch(line)) {
        style = sectionStyle;
      } else if (line.startsWith('공개 전 검토본') || line.startsWith('시행일 ')) {
        style = metadataStyle;
      }
      spans.add(TextSpan(text: line, style: style));
      if (index < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }

    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          child: Center(
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 720),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText.rich(
                TextSpan(children: spans),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurface,
                  height: 1.7,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
