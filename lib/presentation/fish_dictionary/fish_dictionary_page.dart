import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/fish/fish_catalog_service.dart';
import '../../data/models/fish_species.dart';
import '../../data/repositories/fish_species_repository.dart';
import '../../data/services/network_status_service.dart';
import 'fish_species_detail_page.dart';
import 'fish_species_photo.dart';
import 'fish_thumbnail_loader.dart';

class FishDictionaryPage extends StatefulWidget {
  const FishDictionaryPage({
    super.key,
    this.repository,
    this.networkStatus,
    this.isActive = true,
  });
  final FishSpeciesRepository? repository;
  final NetworkStatusService? networkStatus;
  final bool isActive;

  @override
  State<FishDictionaryPage> createState() => _FishDictionaryPageState();
}

class _FishDictionaryPageState extends State<FishDictionaryPage> {
  final _searchController = TextEditingController();
  FishCategory? _selectedCategory;
  FishCatalogSnapshot? _snapshot;
  FishCatalogFailure? _failure;
  bool _isLoading = false;
  bool _hasRequested = false;
  int _request = 0;
  int? _requestInterruptedByOffline;
  late NetworkStatusService _network;
  late bool _wasDisconnected;
  late FishThumbnailLoader _thumbnails;
  bool _routeCurrent = true;
  bool _openingDetail = false;

  FishSpeciesRepository get _repository =>
      widget.repository ?? FishSpeciesRepository.instance;

  @override
  void initState() {
    super.initState();
    _network = widget.networkStatus ?? NetworkStatusService.instance;
    _wasDisconnected = _network.isDisconnected;
    _network.addListener(_networkChanged);
    _thumbnails = _createThumbnailLoader();
    if (widget.isActive) _load();
  }

  FishThumbnailLoader _createThumbnailLoader() => FishThumbnailLoader(
    request: (fish, {bool forceRefresh = false}) => _repository.thumbnail(
      fish,
      forceRefresh: forceRefresh,
      allowNetwork: !_network.isDisconnected,
    ),
  );

  bool get _thumbnailActivity =>
      widget.isActive &&
      _routeCurrent &&
      !_openingDetail &&
      !_network.isDisconnected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _syncThumbnailActivity();
  }

  void _syncThumbnailActivity() => _thumbnails.setEnabled(_thumbnailActivity);

  void _filterChanged() {
    setState(() {});
    _thumbnails.setAllowedKeys(_filteredItems.map(fishThumbnailKey).toSet());
  }

  Future<void> _openFish(FishSpecies fish) async {
    setState(() => _openingDetail = true);
    _syncThumbnailActivity();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FishSpeciesDetailPage(
            fish: fish,
            repository: _repository,
            networkStatus: _network,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _openingDetail = false);
        _syncThumbnailActivity();
        if (!_isLoading) await _load(allowNetwork: false);
      }
    }
  }

  @override
  void didUpdateWidget(covariant FishDictionaryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.networkStatus != widget.networkStatus) {
      _network.removeListener(_networkChanged);
      _network = widget.networkStatus ?? NetworkStatusService.instance;
      _wasDisconnected = _network.isDisconnected;
      _network.addListener(_networkChanged);
    }
    if (oldWidget.repository != widget.repository) {
      _thumbnails.dispose();
      _thumbnails = _createThumbnailLoader();
      _request++;
      _requestInterruptedByOffline = null;
      _snapshot = null;
      _failure = null;
      _isLoading = false;
      _hasRequested = false;
      if (widget.isActive) _load();
    } else if (!oldWidget.isActive && widget.isActive) {
      _loadIfNeeded();
    }
    _syncThumbnailActivity();
  }

  void _loadIfNeeded() {
    if (!_isLoading) {
      // The repository rechecks its TTL; a fresh catalog remains a RAM read.
      _load(forceRefresh: _failure != null);
    }
  }

  void _networkChanged() {
    if (!mounted) return;
    final disconnected = _network.isDisconnected;
    final changed = disconnected != _wasDisconnected;
    _wasDisconnected = disconnected;
    _syncThumbnailActivity();
    if (changed && !disconnected) _thumbnails.retryVisible();
    if (changed && disconnected && _isLoading) {
      // An online response that arrives later cannot replace the offline view.
      _requestInterruptedByOffline = _request;
      _request++;
      setState(() {
        _isLoading = false;
        _failure = FishCatalogFailure.network;
      });
    } else if (changed &&
        !disconnected &&
        widget.isActive &&
        (_snapshot == null || _failure != null || _snapshot!.isStale)) {
      _load(forceRefresh: true);
    } else {
      setState(() {});
    }
  }

  Future<void> _load({bool forceRefresh = false, bool? allowNetwork}) async {
    if (!widget.isActive && allowNetwork != false) return;
    if (forceRefresh) _thumbnails.retryVisible(forceRefresh: true);
    final request = ++_request;
    _requestInterruptedByOffline = null;
    setState(() {
      _isLoading = true;
      _hasRequested = true;
      _failure = null;
    });
    try {
      final snapshot = await _repository.load(
        forceRefresh: forceRefresh,
        allowNetwork: allowNetwork ?? !_network.isDisconnected,
      );
      if (!mounted) return;
      final usableLocalBundle =
          snapshot.isBundled &&
          _snapshot == null &&
          _network.isDisconnected &&
          request == _requestInterruptedByOffline;
      if (request != _request && !usableLocalBundle) return;
      setState(() {
        _snapshot = snapshot;
        _failure = snapshot.failure;
        _isLoading = false;
      });
      _thumbnails.setAllowedKeys(_filteredItems.map(fishThumbnailKey).toSet());
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
    _thumbnails.dispose();
    _network.removeListener(_networkChanged);
    _searchController.dispose();
    super.dispose();
  }

  List<FishSpecies> get _filteredItems {
    final query = _searchController.text.trim().toLowerCase();
    return (_snapshot?.items ?? const <FishSpecies>[]).where((fish) {
      if (_selectedCategory != null && fish.category != _selectedCategory) {
        return false;
      }
      return query.isEmpty ||
          <String>[
            fish.name,
            fish.scientificName,
            ...fish.aliases,
          ].any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final items = _filteredItems;
    final itemIndices = <String, int>{
      for (var index = 0; index < items.length; index++)
        fishThumbnailKey(items[index]): index,
    };
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return TickerMode(
      enabled: widget.isActive,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('어류도감'),
          actions: [
            IconButton(
              tooltip: '새로고침',
              onPressed: _isLoading ? null : () => _load(forceRefresh: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: '어종 검색',
                    hintText: '이름, 학명 또는 다른 이름',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => _filterChanged(),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    for (final category in <FishCategory?>[
                      null,
                      FishCategory.sea,
                      FishCategory.freshwater,
                    ]) ...[
                      ChoiceChip(
                        label: Text(switch (category) {
                          FishCategory.sea => '바다',
                          FishCategory.freshwater => '민물',
                          _ => '전체',
                        }),
                        selected: _selectedCategory == category,
                        onSelected: (_) {
                          _selectedCategory = category;
                          _filterChanged();
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (_isLoading && snapshot != null)
                const LinearProgressIndicator(),
              if (snapshot != null &&
                  !keyboardVisible &&
                  (snapshot.isBundled ||
                      snapshot.isFromCache ||
                      snapshot.isStale ||
                      _network.isDisconnected ||
                      _failure != null))
                _CatalogNotice(
                  snapshot: snapshot,
                  offline: _network.isDisconnected,
                  failure: _failure,
                  retry: _isLoading ? null : () => _load(forceRefresh: true),
                ),
              if (snapshot != null && keyboardVisible && _failure != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '최신 자료를 확인하지 못했습니다.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () => _load(forceRefresh: true),
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: snapshot == null
                    ? !_hasRequested
                          ? const SizedBox.shrink()
                          : _isLoading
                          ? const Center(child: CircularProgressIndicator())
                          : _CatalogError(
                              failure:
                                  _failure ??
                                  FishCatalogFailure.invalidResponse,
                              retry: () => _load(forceRefresh: true),
                            )
                    : items.isEmpty
                    ? const _EmptyFishView()
                    : NotificationListener<ScrollNotification>(
                        onNotification: (_) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _thumbnails.recheckVisible();
                          });
                          return false;
                        },
                        child: RefreshIndicator(
                          onRefresh: () => _load(forceRefresh: true),
                          child: ListView.separated(
                            cacheExtent: 0,
                            addAutomaticKeepAlives: false,
                            findItemIndexCallback: (key) {
                              return key is ValueKey<String>
                                  ? itemIndices[key.value]
                                  : null;
                            },
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(16),
                            itemCount: items.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final fish = items[index];
                              return _FishSpeciesCard(
                                key: ValueKey(fishThumbnailKey(fish)),
                                fish: fish,
                                thumbnails: _thumbnails,
                                allowNetwork: !_network.isDisconnected,
                                onTap: _openFish,
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FishSpeciesCard extends StatefulWidget {
  const _FishSpeciesCard({
    super.key,
    required this.fish,
    required this.thumbnails,
    required this.allowNetwork,
    required this.onTap,
  });
  final FishSpecies fish;
  final FishThumbnailLoader thumbnails;
  final bool allowNetwork;
  final ValueChanged<FishSpecies> onTap;

  @override
  State<_FishSpeciesCard> createState() => _FishSpeciesCardState();
}

class _FishSpeciesCardState extends State<_FishSpeciesCard> {
  final _owner = Object();
  late FishSpecies _fish;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _fish = widget.fish;
    _attachAfterFrame();
  }

  @override
  void didUpdateWidget(covariant _FishSpeciesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thumbnails != widget.thumbnails) {
      oldWidget.thumbnails.detach(_owner);
    }
    _fish = hasFishThumbnail(widget.fish)
        ? widget.fish
        : mergeFishThumbnail(widget.fish, _fish);
    _attachAfterFrame();
  }

  void _attachAfterFrame() {
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (hasFishThumbnail(_fish)) {
        widget.thumbnails.detach(_owner);
        return;
      }
      widget.thumbnails.attach(
        owner: _owner,
        fish: _fish,
        isVisible: _isNearViewport,
        onResult: (fish) {
          if (!mounted ||
              generation != _generation ||
              fishThumbnailKey(fish) != fishThumbnailKey(widget.fish)) {
            return;
          }
          setState(() => _fish = mergeFishThumbnail(widget.fish, fish));
        },
      );
    });
  }

  bool _isNearViewport() {
    if (!mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final render = context.findRenderObject();
    final scrollable = Scrollable.maybeOf(context);
    if (render is! RenderBox ||
        !render.attached ||
        !render.hasSize ||
        scrollable == null) {
      return false;
    }
    final viewport = RenderAbstractViewport.maybeOf(render);
    if (viewport == null) return false;
    final top = viewport.getOffsetToReveal(render, 0).offset;
    final position = scrollable.position;
    return top + render.size.height > position.pixels - 48 &&
        top < position.pixels + position.viewportDimension + 48;
  }

  @override
  void dispose() {
    _generation++;
    widget.thumbnails.detach(_owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fish = _fish;
    final summary = [
      fish.categoryLabel,
      if (fish.family.trim().isNotEmpty) fish.family,
      if (fish.scientificName.trim().isNotEmpty) fish.scientificName,
    ].join(' · ');
    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: FishSpeciesPhoto(
            fish: fish,
            height: 56,
            compact: true,
            allowNetwork: widget.allowNetwork,
          ),
        ),
        title: Text(
          fish.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => widget.onTap(_fish),
      ),
    );
  }
}

class _CatalogNotice extends StatelessWidget {
  const _CatalogNotice({
    required this.snapshot,
    required this.offline,
    required this.failure,
    required this.retry,
  });
  final FishCatalogSnapshot snapshot;
  final bool offline;
  final FishCatalogFailure? failure;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    final at =
        (snapshot.isBundled
                ? snapshot.dataUpdatedAt ?? snapshot.fetchedAt
                : snapshot.fetchedAt)
            .toLocal();
    final date =
        '${at.year}.${at.month.toString().padLeft(2, '0')}.'
        '${at.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snapshot.isBundled
                    ? '기본 어종 자료 ${snapshot.items.length}종 · $date 기준'
                    : '저장된 어종 정보 · $date 기준',
              ),
              if (offline)
                Text(
                  snapshot.isBundled
                      ? '오프라인입니다. 앱에 포함된 기본 자료를 표시합니다.'
                      : '오프라인입니다. 저장된 정보를 표시합니다.',
                )
              else if (failure != null)
                Text(
                  snapshot.isBundled
                      ? '최신 자료를 확인하지 못해 앱에 포함된 기본 자료를 표시합니다.'
                      : _failureMessage(failure!),
                )
              else if (snapshot.isStale && !snapshot.isBundled)
                const Text('갱신이 필요한 정보입니다. 새로고침해 주세요.'),
              if (failure != null || (snapshot.isStale && !snapshot.isBundled))
                TextButton(onPressed: retry, child: const Text('다시 시도')),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.failure, required this.retry});
  final FishCatalogFailure failure;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline, size: 48),
          const SizedBox(height: 16),
          Text(_failureMessage(failure), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: retry, child: const Text('다시 시도')),
        ],
      ),
    ),
  );
}

String _failureMessage(FishCatalogFailure failure) => switch (failure) {
  FishCatalogFailure.configuration => '어류도감 서비스 연결 설정이 필요합니다.',
  FishCatalogFailure.unauthorized => '어류도감 서비스 인증을 확인할 수 없습니다.',
  FishCatalogFailure.rateLimited => '요청이 많습니다. 잠시 후 다시 시도해 주세요.',
  FishCatalogFailure.timedOut => '응답 시간이 초과되었습니다. 다시 시도해 주세요.',
  FishCatalogFailure.network => '연결할 수 없습니다. 네트워크를 확인해 주세요.',
  FishCatalogFailure.noData => '제공된 어종 정보가 없습니다.',
  FishCatalogFailure.invalidResponse => '어종 정보를 불러오지 못했습니다.',
};

class _EmptyFishView extends StatelessWidget {
  const _EmptyFishView();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('검색 결과가 없습니다.', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('검색어나 필터 조건을 변경해 보세요.', textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
