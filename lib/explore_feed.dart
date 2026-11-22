import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'drama_feed.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'source_catalog.dart';

const recommendTab = CatalogCategory('app:recommend', '推荐');

const hongguoGenreTabs = <CatalogCategory>[
  CatalogCategory.all,
  CatalogCategory('series', '系列剧'),
  CatalogCategory('short_play', '真人剧'),
  CatalogCategory('comic_series', '漫剧'),
  CatalogCategory('ai_series', 'AI剧'),
];

CatalogCategory rankingTab(RankingBoard board) =>
    CatalogCategory('app:rank:${board.id}', board.name);

class ExploreFeed extends ChangeNotifier {
  ExploreFeed(this.repository, this.store) {
    store.addListener(_storeChanged);
    repository.catalogUpdates.addListener(_metadataChanged);
    _open();
  }
  final AppRepository repository;
  final LocalStore store;
  SourceCatalog? _catalog;
  CatalogCategory _tab = CatalogCategory.all;
  CatalogCategory _genre = CatalogCategory.all;
  DramaFeed? _feed;
  Map<String, int> _ranks = const {};
  final _feeds = <String, DramaFeed>{};
  final _rankings = <String, Map<String, int>>{};
  bool _disposed = false;

  SourceSite? get source => _catalog?.source;
  DramaFeed? get feed => _feed;
  CatalogCategory get tab => _tab;
  CatalogCategory get genre => _genre;
  bool get usesHongguoGenreTabs => source?.id == 'hongguo-self';
  List<CatalogCategory> get genreTabs =>
      usesHongguoGenreTabs ? hongguoGenreTabs : categories;
  List<CatalogCategory> get categories => _catalog?.categories ?? const [];
  bool get recommending => _tab.id == recommendTab.id;

  List<CatalogCategory> get tabs {
    final catalog = _catalog;
    if (catalog == null) return const [];
    if (usesHongguoGenreTabs) {
      return [
        if (catalog.recommends) recommendTab,
        for (final board in catalog.boards)
          if (_boardMatchesGenre(board)) rankingTab(board),
      ];
    }
    final [all, ...genres] = catalog.categories;
    return [
      if (catalog.recommends) recommendTab,
      all,
      for (final board in catalog.boards) rankingTab(board),
      ...genres,
    ];
  }

  bool _boardMatchesGenre(RankingBoard board) {
    final id = board.id.toLowerCase();
    final name = board.name.replaceAll(RegExp(r'\\s+'), '');
    return switch (_genre.id) {
      '' => id.contains('hot') && !id.contains('real') &&
          !id.contains('comic') && !id.contains('ai'),
      'short_play' => id.contains('real') || name.contains('真人'),
      'comic_series' => id.contains('comic') || name.contains('漫'),
      'ai_series' => id.contains('ai') || name.contains('AI'),
      'series' => id.contains('series') || name.contains('系列') || name.contains('新季'),
      _ => false,
    };
  }

  void selectGenre(String id) {
    if (!usesHongguoGenreTabs || _genre.id == id) return;
    final selected = genreTabs.where((item) => item.id == id).firstOrNull;
    if (selected == null) return;
    _genre = selected;
    final nextTabs = tabs;
    final next = nextTabs.where((item) => item.id == recommendTab.id).firstOrNull ??
        nextTabs.firstOrNull;
    if (next != null) {
      _select(next);
    } else {
      _tab = CatalogCategory.all;
      _feed = null;
      _ranks = const {};
      _notify();
    }
  }

  int? rankOf(Drama drama) => _ranks[drama.id];

  WatchEntry? get resume {
    final source = this.source;
    if (source == null || _tab.id != tabs.first.id) return null;
    return store.history
        .where((entry) => entry.drama.source == source.id)
        .firstOrNull;
  }

  Drama? get featured =>
      recommending && resume == null ? _feed?.items.firstOrNull : null;

  List<Drama> get items {
    final items = _feed?.items ?? const <Drama>[];
    return featured == null ? items : items.skip(1).toList();
  }

  void select(String id) {
    if (id == _tab.id) return;
    final tab = tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab != null) _select(tab);
  }

  Future<void> refresh() async {
    final catalog = _catalog;
    if (catalog == null) return;
    if (catalog.categories.length == 1) {
      unawaited(_loadCategories(catalog, force: true));
    }
    await _feed?.reload(force: true);
  }

  void _open() {
    final id = store.source;
    if (id == _catalog?.source.id) return;
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    _dropFeeds();
    if (id.isEmpty) {
      _catalog = null;
      return;
    }
    final catalog = _catalog = SourceCatalog(repository, SourceSite.byId(id));
    _genre = CatalogCategory.all;
    _select(catalog.recommends ? recommendTab : CatalogCategory.all);
    unawaited(_loadCategories(catalog));
  }

  Future<void> _loadCategories(
    SourceCatalog catalog, {
    bool force = false,
  }) async {
    try {
      await catalog.loadCategories(force: force);
    } catch (_) {}
    if (_disposed || catalog != _catalog) return;
    _notify();
  }

  void _select(CatalogCategory tab) {
    final catalog = _catalog!;
    if (recommending) unawaited(repository.cancelRecommendations());
    _tab = tab;
    final feedKey = _feedKey(tab);
    if (_feeds[feedKey] case final kept?) {
      _feed = kept;
      _ranks = _rankings[feedKey] ?? const {};
      if (kept.items.isEmpty && !kept.loading) unawaited(kept.reload());
      _notify();
      return;
    }
    final board = catalog.boards
        .where((board) => rankingTab(board).id == tab.id)
        .firstOrNull;
    final ranks = _ranks = _rankings[feedKey] = <String, int>{};
    final feed = _feed = _feeds[feedKey] = tab.id == recommendTab.id
        ? DramaFeed(
            cumulative: true,
            load: (page, force) => _saved(
              catalog.recommendations(
                genre: _recommendationGenre,
                more: page > 1,
                force: force,
              ),
            ),
          )
        : board != null
        ? DramaFeed(
            load: (page, force) =>
                _saved(_ranking(catalog, board, ranks, page, force)),
          )
        : DramaFeed(
            cached: () => catalog.cached(tab),
            load: (page, force) =>
                _saved(catalog.fetch(tab, page: page, force: force)),
          );
    feed.addListener(_notify);
    unawaited(feed.reload());
    _notify();
  }

  String get _recommendationGenre =>
      _genre.id == 'short_play' ||
          _genre.id == 'comic_series' ||
          _genre.id == 'ai_series'
      ? _genre.id
      : SourceCatalog.recommendGenre;

  String _feedKey(CatalogCategory tab) => '${_genre.id}|${tab.id}';

  Future<CatalogPage> _ranking(
    SourceCatalog catalog,
    RankingBoard board,
    Map<String, int> ranks,
    int page,
    bool force,
  ) async {
    final result = await catalog.ranking(board, page: page, force: force);
    for (final item in result.items) {
      ranks[item.drama.id] = item.rank;
    }
    return CatalogPage(
      [for (final item in result.items) item.drama],
      hasMore: result.hasMore,
      warning: result.warning,
      page: result.page,
    );
  }

  Future<CatalogPage> _saved(Future<CatalogPage> request) async {
    final page = await request;
    unawaited(store.refreshDramas(page.items).catchError((Object _) {}));
    return page;
  }

  void _storeChanged() {
    _open();
    _notify();
  }

  void _metadataChanged() {
    final drama = repository.catalogUpdates.latest;
    if (drama == null || drama.source != source?.id) return;
    _catalog?.remember([drama]);
    for (final feed in _feeds.values) {
      feed.update(drama);
    }
    unawaited(store.refreshDrama(drama).catchError((Object _) {}));
  }

  void _dropFeeds() {
    for (final feed in _feeds.values) {
      feed.dispose();
    }
    _feeds.clear();
    _rankings.clear();
    _feed = null;
    _ranks = const {};
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_storeChanged);
    repository.catalogUpdates.removeListener(_metadataChanged);
    _dropFeeds();
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    super.dispose();
  }
}
