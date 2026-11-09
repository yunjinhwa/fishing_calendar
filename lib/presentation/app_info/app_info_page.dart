import 'package:flutter/material.dart';

import '../../data/app_info/app_info_gateway.dart';
import '../../data/app_info/app_licenses.dart';
import '../../data/app_info/app_source_catalog.dart';

class AppInfoPage extends StatefulWidget {
  const AppInfoPage({
    super.key,
    this.gateway = const PackageAppInfoGateway(),
    this.linkLauncher,
  });

  final AppInfoGateway gateway;
  final AppInfoLinkLauncher? linkLauncher;

  @override
  State<AppInfoPage> createState() => _AppInfoPageState();
}

class _AppInfoPageState extends State<AppInfoPage> {
  late Future<AppInfoDetails> _details;

  @override
  void initState() {
    super.initState();
    registerAppLicenses();
    _details = widget.gateway.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('앱 정보')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Icon(Icons.calendar_month_outlined, size: 52),
            const SizedBox(height: 12),
            Text(
              '낚시 캘린더',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            FutureBuilder<AppInfoDetails>(
              future: _details,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return Text(
                    '버전 ${snapshot.requireData.displayVersion}',
                    textAlign: TextAlign.center,
                  );
                }
                if (snapshot.hasError) {
                  return Column(
                    children: [
                      const Text('버전 정보를 불러오지 못했어요.'),
                      TextButton(
                        onPressed: () => setState(() {
                          _details = widget.gateway.load();
                        }),
                        child: const Text('다시 시도'),
                      ),
                    ],
                  );
                }
                return const Text('버전 확인 중…', textAlign: TextAlign.center);
              },
            ),
            const SizedBox(height: 28),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.source_outlined),
                    title: const Text('API·데이터·사진 출처'),
                    subtitle: const Text('제공기관·제작자와 라이선스'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            AppSourcesPage(linkLauncher: widget.linkLauncher),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.code_outlined),
                    title: const Text('오픈소스 라이선스'),
                    subtitle: const Text('Flutter·패키지·포함 자료의 저작권 고지'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: '낚시 캘린더',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppSourcesPage extends StatelessWidget {
  const AppSourcesPage({super.key, this.linkLauncher});

  final AppInfoLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) {
    final categories = appSourceCatalog.map((item) => item.category).toSet();
    return Scaffold(
      appBar: AppBar(title: const Text('API·데이터·사진 출처')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final category in categories) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                child: Text(
                  category,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (final source in appSourceCatalog.where(
                      (item) => item.category == category,
                    ))
                      ListTile(
                        title: Text(source.title),
                        subtitle: Text(source.provider),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => AppSourceDetailPage(
                              source: source,
                              linkLauncher: linkLauncher,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AppSourceDetailPage extends StatelessWidget {
  const AppSourceDetailPage({
    super.key,
    required this.source,
    this.linkLauncher,
  });

  final AppSource source;
  final AppInfoLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(source.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _CreditText(
              label: '제공기관·제작자',
              value: source.provider,
              sourceUrl: source.sourceUrl,
              launcher: linkLauncher,
            ),
            if (source.licenseLabel case final String label)
              _CreditText(
                label: '라이선스',
                value: label,
                sourceUrl: source.licenseUrl,
                launcher: linkLauncher,
              ),
          ],
        ),
      ),
    );
  }
}

class _CreditText extends StatelessWidget {
  const _CreditText({
    required this.label,
    required this.value,
    this.sourceUrl,
    this.launcher,
  });

  final String label;
  final String value;
  final String? sourceUrl;
  final AppInfoLinkLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    final uri = parsePublicAppInfoUri(sourceUrl);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (uri == null)
            SelectableText(value)
          else
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 8),
                alignment: Alignment.centerLeft,
              ),
              onPressed: () async {
                final opened = await launchAppInfoLink(uri, launcher: launcher);
                if (!opened && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('링크를 열지 못했어요. 인터넷 연결과 브라우저를 확인해 주세요.'),
                    ),
                  );
                }
              },
              child: Text(value),
            ),
        ],
      ),
    );
  }
}
