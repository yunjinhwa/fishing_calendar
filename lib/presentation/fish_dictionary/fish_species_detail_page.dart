import 'package:flutter/material.dart';

import '../../data/fish/fish_catalog_service.dart';
import '../../data/models/fish_species.dart';
import '../../data/repositories/fish_species_repository.dart';
import '../../data/services/network_status_service.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';
import 'fish_species_photo.dart';

class FishSpeciesDetailPage extends StatefulWidget {
  const FishSpeciesDetailPage({
    super.key,
    required this.fish,
    this.repository,
    this.networkStatus,
  });
  final FishSpecies fish;
  final FishSpeciesRepository? repository;
  final NetworkStatusService? networkStatus;

  @override
  State<FishSpeciesDetailPage> createState() => _FishSpeciesDetailPageState();
}

class _FishSpeciesDetailPageState extends State<FishSpeciesDetailPage> {
  late FishSpecies _fish;
  late NetworkStatusService _network;
  bool _isLoading = true;
  FishCatalogFailure? _failure;
  int _request = 0;
  late bool _wasDisconnected;

  @override
  void initState() {
    super.initState();
    _fish = widget.fish;
    _network = widget.networkStatus ?? NetworkStatusService.instance;
    _wasDisconnected = _network.isDisconnected;
    _network.addListener(_networkChanged);
    _loadDetail();
  }

  @override
  void didUpdateWidget(covariant FishSpeciesDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.networkStatus != widget.networkStatus) {
      _network.removeListener(_networkChanged);
      _network = widget.networkStatus ?? NetworkStatusService.instance;
      _wasDisconnected = _network.isDisconnected;
      _network.addListener(_networkChanged);
    }
    if (oldWidget.fish != widget.fish ||
        oldWidget.repository != widget.repository) {
      _fish = widget.fish;
      _loadDetail();
    }
  }

  void _networkChanged() {
    if (!mounted) return;
    final disconnected = _network.isDisconnected;
    final changed = disconnected != _wasDisconnected;
    _wasDisconnected = disconnected;
    if (changed && disconnected && _isLoading) {
      _request++;
      setState(() {
        _isLoading = false;
        _failure = FishCatalogFailure.network;
      });
    } else if (changed && !disconnected && _failure != null) {
      _loadDetail(forceRefresh: true);
    } else {
      setState(() {});
    }
  }

  Future<void> _loadDetail({bool forceRefresh = false}) async {
    final request = ++_request;
    setState(() {
      _isLoading = true;
      _failure = null;
    });
    try {
      final fish = await (widget.repository ?? FishSpeciesRepository.instance)
          .detail(
            widget.fish,
            forceRefresh: forceRefresh,
            allowNetwork: !_network.isDisconnected,
          );
      if (!mounted || request != _request) return;
      setState(() {
        _fish = fish;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _failure = error is FishCatalogException
            ? error.reason
            : FishCatalogFailure.invalidResponse;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _request++;
    _network.removeListener(_networkChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fish = _fish;
    final hasTransientPartial =
        fish.detailNeedsRetry && !_isLoading && _failure == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(fish.name),
        actions: [
          IconButton(
            tooltip: '상세 정보 새로고침',
            onPressed: _isLoading
                ? null
                : () => _loadDetail(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FishSpeciesPhoto(
              fish: fish,
              allowNetwork: !_network.isDisconnected,
            ),
            const SizedBox(height: 24),
            Text(
              fish.name,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(label: Text(fish.categoryLabel)),
            ),
            const SizedBox(height: 16),
            if (_isLoading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('상세 정보를 불러오는 중입니다.'),
              const SizedBox(height: 16),
            ],
            if (hasTransientPartial) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('일부 정보를 불러오지 못했습니다.'),
                      TextButton(
                        onPressed: () => _loadDetail(forceRefresh: true),
                        child: const Text('상세 정보 다시 시도'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_failure != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_detailFailureMessage(_failure!)),
                      const Text('기본 어종 정보는 계속 확인할 수 있습니다.'),
                      TextButton(
                        onPressed: () => _loadDetail(forceRefresh: true),
                        child: const Text('상세 정보 다시 시도'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const _SectionTitle(title: '기본 정보'),
            const SizedBox(height: 8),
            _InfoCard(
              children: [
                _InfoRow(label: '학명', value: fish.scientificName),
                _InfoRow(label: '분류', value: fish.family),
                _InfoRow(label: '서식지', value: fish.habitat),
                _InfoRow(label: '크기', value: fish.sizeDescription),
                if (fish.aliases.isNotEmpty)
                  _InfoRow(label: '다른 이름', value: fish.aliases.join(', ')),
              ],
            ),
            const SizedBox(height: 24),
            const _SectionTitle(title: '특징'),
            const SizedBox(height: 8),
            _FeatureDescription(
              description: fish.feature,
              retryPending: fish.detailNeedsRetry,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                final allowed = await requireMemberAccess(
                  context,
                  message: '도감의 어종을 출조 기록으로 저장하려면 로그인이 필요합니다.',
                );
                if (!allowed || !context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RecordFormPage(initialFishName: fish.name),
                  ),
                );
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('이 어종으로 기록 작성하기'),
            ),
          ],
        ),
      ),
    );
  }
}

String _detailFailureMessage(FishCatalogFailure failure) => switch (failure) {
  FishCatalogFailure.configuration => '상세 정보 서비스 연결 설정이 필요합니다.',
  FishCatalogFailure.unauthorized => '상세 정보 서비스 인증을 확인할 수 없습니다.',
  FishCatalogFailure.rateLimited => '요청이 많습니다. 잠시 후 다시 시도해 주세요.',
  FishCatalogFailure.timedOut => '상세 정보 응답 시간이 초과되었습니다.',
  FishCatalogFailure.network => '상세 정보에 연결할 수 없습니다. 네트워크를 확인해 주세요.',
  FishCatalogFailure.noData => '제공된 상세 정보가 없습니다.',
  FishCatalogFailure.invalidResponse => '상세 정보를 불러오지 못했습니다.',
};

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.trim().isEmpty ? '제공되지 않음' : value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _FeatureDescription extends StatelessWidget {
  const _FeatureDescription({
    required this.description,
    this.retryPending = false,
  });
  final String description;
  final bool retryPending;

  @override
  Widget build(BuildContext context) {
    final paragraphs = description
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim()
        .split(RegExp(r'\n[ \t]*\n'))
        .map((paragraph) => paragraph.trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList();
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.normal,
      height: 1.65,
      color: paragraphs.isEmpty
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface,
    );
    return _InfoCard(
      children: [
        if (paragraphs.isEmpty)
          Text(
            retryPending ? '특징을 불러오지 못했습니다. 다시 시도해 주세요.' : '제공되지 않음',
            style: style,
          )
        else
          for (var index = 0; index < paragraphs.length; index++) ...[
            if (index > 0) const SizedBox(height: 16),
            Text(paragraphs[index], style: style),
          ],
      ],
    );
  }
}
