import 'dart:async';

import 'package:flutter/material.dart';

import '../../explore_feed.dart';
import '../../drama_feed.dart';
import '../../category_filter_models.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../explore/source_actions.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/page_header.dart';
import '../widgets/source_bar.dart';
import '../widgets/status_view.dart';

enum _FindMode { rank, filter }

class FindDramaPage extends StatefulWidget {
  const FindDramaPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<FindDramaPage> createState() => FindDramaPageState();
}

class FindDramaPageState extends State<FindDramaPage> {
  ExploreFeed? _explore;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  _FindMode _mode = _FindMode.rank;
  String _shown = '';
  DramaFeed? _filterFeed;
  Set<String> _filterIds = {};
  String _filterGenre = '';
  CategoryFilterPanel? _filterPanel;
  bool _filterPanelLoading = false;
  String _filterPanelKey = '';
  int _filterOffset = 0;
  String _filterSessionId = '';
  final Set<String> _filterSeenIds = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _explore?.dispose();
    _filterFeed?.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  List<CatalogCategory> _options(ExploreFeed explore) => [
    for (final tab in explore.tabs)
      if (_mode == _FindMode.rank
          ? tab.id.isEmpty || tab.id.startsWith('app:')
          : !tab.id.startsWith('app:'))
        tab,
  ];

  void _changeMode(_FindMode mode, ExploreFeed explore) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    if (mode == _FindMode.filter && explore.source?.id == 'hongguo-self') {
      _filterPanel = null;
      _filterPanelKey = '';
      _filterIds.clear();
      _filterFeed?.dispose();
      _filterFeed = null;
      unawaited(_ensureCategoryFilters(explore));
    }
    final options = [
      for (final tab in explore.tabs)
        if (mode == _FindMode.rank
            ? tab.id.isEmpty || tab.id.startsWith('app:')
            : !tab.id.startsWith('app:'))
          tab,
    ];
    if (options.isNotEmpty && !options.any((tab) => tab.id == explore.tab.id)) {
      explore.select(options.first.id);
    }
    _toTop();
  }

  void _selectTab(ExploreFeed explore, String id) {
    if (id == explore.tab.id) {
      if (_scroll.hasClients && _scroll.offset > 0) _toTop();
      return;
    }
    if (_mode == _FindMode.filter) {
      _filterFeed?.dispose();
      _filterFeed = null;
      _filterIds.clear();
    }
    explore.select(id);
    if (_mode == _FindMode.filter && explore.source?.id == 'hongguo-self') {
      _filterPanel = null;
      _filterPanelKey = '';
      _filterIds.clear();
      _filterFeed?.dispose();
      _filterFeed = null;
      unawaited(_ensureCategoryFilters(explore));
    }
    _toTop();
  }

  void _toTop() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: Motion.of(context, Motion.long),
        curve: Motion.enter,
      );
    }
  }

  void reselect() {
    if (!_scroll.hasClients || _scroll.offset <= 0) {
      unawaited(_refreshKey.currentState?.show());
    } else {
      _toTop();
    }
  }

  Future<void> _pickCategory(BuildContext anchor, ExploreFeed explore) async {
    final options = _options(explore);
    if (options.isEmpty) return;
    final value = await showChoicePanel<String>(
      context: anchor,
      title: _mode == _FindMode.rank ? '全部榜单' : '筛选找片',
      options: [for (final tab in options) ChoiceOption(tab.id, tab.name)],
      selected: options.any((tab) => tab.id == explore.tab.id)
          ? explore.tab.id
          : options.first.id,
      grid: ChoiceGrid.categories,
    );
    if (value != null) _selectTab(explore, value);
  }

  String _genreFor(ExploreFeed explore) => switch (explore.tab.id) {
    'short_play' || 'comic_series' || 'ai_series' => explore.tab.id,
    _ => '',
  };

  Future<void> _ensureCategoryFilters(ExploreFeed explore) async {
    final source = explore.source;
    if (source == null || source.id != 'hongguo-self') return;
    final genre = _genreFor(explore);
    final key = '${source.id}|$genre';
    if (_filterPanelKey == key || _filterPanelLoading) return;
    _filterPanelLoading = true;
    _filterPanelKey = key;
    try {
      await AppScope.of(context).repository.cancelCategoryFilters();
      final panel = await AppScope.of(context).repository.categoryFilterPanel(
        source.id,
        genre: genre,
      );
      if (!mounted || _filterPanelKey != key) return;
      setState(() {
        _filterPanel = panel;
        _filterGenre = genre;
        _filterIds.removeWhere((id) => !panel.validItemIds.contains(id));
      });
      await _reloadCategoryFilterResults(explore, genre);
    } catch (error) {
      if (!mounted) return;
      _filterPanelKey = '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载红果筛选条件失败：$error')),
      );
    } finally {
      _filterPanelLoading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _reloadCategoryFilterResults(
    ExploreFeed explore,
    String genre,
  ) async {
    final source = explore.source;
    if (source == null || source.id != 'hongguo-self') return;
    final repository = AppScope.of(context).repository;
    _filterOffset = 0;
    _filterSessionId = '';
    _filterSeenIds.clear();
    _filterFeed?.dispose();
    final feed = DramaFeed(
      load: (page, force) async {
        if (page <= 1 || force) {
          _filterOffset = 0;
          _filterSessionId = '';
          _filterSeenIds.clear();
        }
        final result = await repository.categoryFilterPage(
          source.id,
          genre: genre,
          filterIds: _filterIds.toList(),
          offset: _filterOffset,
          sessionId: _filterSessionId,
          seenIds: _filterSeenIds.toList(),
        );
        _filterOffset = result.nextOffset;
        _filterSessionId = result.sessionId;
        final dramas = [
          for (final item in result.items) Drama.fromJson(item),
        ];
        for (final drama in dramas) {
          final id = drama.sourceId.isNotEmpty
              ? drama.sourceId
              : drama.id.split(':').last;
          if (id.isNotEmpty) _filterSeenIds.add(id);
        }
        return CatalogPage(dramas, hasMore: result.hasMore, page: page);
      },
    );
    _filterFeed = feed;
    if (mounted) setState(() {});
    await feed.reload(force: true);
    if (mounted) _toTop();
  }

  Future<void> _selectFilterItem(
    ExploreFeed explore,
    CategoryFilterRow row,
    String? itemId,
  ) async {
    final rowIds = row.items.map((item) => item.id).toSet();
    setState(() {
      if (itemId == null) {
        _filterIds.removeAll(rowIds);
      } else if (row.singleChoice) {
        _filterIds.removeAll(rowIds);
        _filterIds.add(itemId);
      } else if (_filterIds.contains(itemId)) {
        _filterIds.remove(itemId);
      } else {
        _filterIds.add(itemId);
      }
    });
    await _reloadCategoryFilterResults(explore, _filterGenre);
  }

  Future<void> _refresh(ExploreFeed explore) async {
    if (_mode == _FindMode.filter && _filterFeed != null) {
      await AppScope.of(context).repository.cancelCategoryFilters();
      await _filterFeed!.reload(force: true);
    } else {
      await explore.refresh();
    }
  }

  Widget _buildFilterRow(ExploreFeed explore, CategoryFilterRow row) {
    final theme = Theme.of(context);
    final selectedInRow = row.items.where((item) => _filterIds.contains(item.id));
    final allSelected = selectedInRow.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChoice(
                    label: '全部',
                    selected: allSelected,
                    onTap: () => _selectFilterItem(explore, row, null),
                  ),
                  for (final item in row.items)
                    _filterChoice(
                      label: item.name,
                      selected: _filterIds.contains(item.id),
                      onTap: () => _selectFilterItem(explore, row, item.id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChoice({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: theme.textTheme.labelMedium?.copyWith(
          color: selected
              ? theme.colorScheme.onSecondaryContainer
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        onSelected: (_) => onTap(),
      ),
    );
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  void _searchSubmitted(SourceSite source, String query) {
    if (query.trim().isEmpty) return;
    _search.clear();
    openSearch(context, widget.store, source, query: query);
  }

  void _resetScroll(ExploreFeed explore) {
    final shown = '${explore.source?.id}|${_mode.name}|${explore.tab.id}';
    if (shown == _shown) return;
    _shown = shown;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _toTop();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_explore!, widget.store, ?_filterFeed]),
    builder: (context, _) {
      final explore = _explore!;
      _resetScroll(explore);
      final source = explore.source;
      final form = AppScope.formFactorOf(context);
      final television = form == FormFactor.television;
      final inset = switch (form) {
        FormFactor.phone => 16.0,
        FormFactor.pad || FormFactor.window => 24.0,
        FormFactor.television => televisionInset,
      };
      if (source == null) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (!television) const PageHeader(title: '找剧'),
                const Expanded(
                  child: StatusView(
                    title: '还没有选择站源',
                    message: '请先在发现页选择并启用红果等短剧站源。',
                    icon: Icons.movie_filter_outlined,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final options = _options(explore);
      if (options.isNotEmpty &&
          !options.any((tab) => tab.id == explore.tab.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) explore.select(options.first.id);
        });
      }
      final selected = options.any((tab) => tab.id == explore.tab.id)
          ? explore.tab.id
          : options.firstOrNull?.id ?? '';
      final feed = _mode == _FindMode.filter && _filterFeed != null
          ? _filterFeed
          : explore.feed;
      final visibleItems = _mode == _FindMode.filter && _filterFeed != null
          ? _filterFeed!.items
          : explore.items;
      final rankMode = _mode == _FindMode.rank;
      if (!rankMode && source.id == 'hongguo-self' &&
          _filterPanel == null && !_filterPanelLoading) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_ensureCategoryFilters(explore));
        });
      }
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (!television)
                SourceBar(
                  source: source.name,
                  searchController: _search,
                  onSwitchSource: (anchor) => pickSource(anchor, widget.store),
                  onOpenSearch: () => openSearch(context, widget.store, source),
                  onSearchSubmitted: (query) => _searchSubmitted(source, query),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(inset, 8, inset, 4),
                child: SegmentedButton<_FindMode>(
                  segments: const [
                    ButtonSegment(
                      value: _FindMode.rank,
                      icon: Icon(Icons.leaderboard_outlined),
                      label: Text('榜单'),
                    ),
                    ButtonSegment(
                      value: _FindMode.filter,
                      icon: Icon(Icons.tune_rounded),
                      label: Text('筛选找片'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (value) {
                    if (value.isNotEmpty) _changeMode(value.first, explore);
                  },
                  showSelectedIcon: false,
                ),
              ),
              if (options.isNotEmpty)
                CategoryTabs<String>(
                  options: [
                    for (final tab in options) ChoiceOption(tab.id, tab.name),
                  ],
                  selected: selected,
                  onSelected: (id) => _selectTab(explore, id),
                  onShowAll: (anchor) => _pickCategory(anchor, explore),
                ),
              if (!rankMode && source.id == 'hongguo-self') ...[
                if (_filterPanel == null && _filterPanelLoading)
                  const LinearProgressIndicator(minHeight: 2),
                if (_filterPanel != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(inset, 4, 0, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final row in _filterPanel!.rows)
                          _buildFilterRow(explore, row),
                      ],
                    ),
                  ),
              ],
              if (!rankMode && source.id != 'hongguo-self')
                Padding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      explore.tab.id.isEmpty
                          ? '已选：全部剧集'
                          : '已选：${explore.tab.name}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              Expanded(
                child: feed == null
                    ? const StatusView.loading()
                    : RefreshIndicator(
                        key: _refreshKey,
                        onRefresh: () => _refresh(explore),
                        child: LayoutBuilder(
                          builder: (context, constraints) => AutoLoadMore(
                            feed: feed,
                            child: CustomScrollView(
                              controller: _scroll,
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                if (feed.items.isEmpty)
                                  SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: feed.loading
                                        ? const StatusView.loading()
                                        : StatusView(
                                            title: feed.error.isNotEmpty
                                                ? '加载失败'
                                                : '暂无剧集',
                                            message: feed.error.isNotEmpty
                                                ? feed.error
                                                : '当前分类暂时没有可展示的内容。',
                                            action: '重试',
                                            onAction: () =>
                                                feed.reload(force: true),
                                          ),
                                  )
                                else ...[
                                  SliverPadding(
                                    padding: EdgeInsets.fromLTRB(
                                      inset,
                                      16,
                                      inset,
                                      0,
                                    ),
                                    sliver: DramaSliverGrid(
                                      width: constraints.maxWidth - inset * 2,
                                      items: visibleItems,
                                      rankOf: rankMode ? explore.rankOf : null,
                                      onOpen: _open,
                                    ),
                                  ),
                                  SliverToBoxAdapter(
                                    child: FeedFooter(feed: feed),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
