import 'dart:async';

import 'package:flutter/material.dart';

import '../../explore_feed.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _explore?.dispose();
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
    explore.select(id);
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
    listenable: Listenable.merge([_explore!, widget.store]),
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
      if (options.isNotEmpty && !options.any((tab) => tab.id == explore.tab.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) explore.select(options.first.id);
        });
      }
      final selected = options.any((tab) => tab.id == explore.tab.id)
          ? explore.tab.id
          : options.firstOrNull?.id ?? '';
      final feed = explore.feed;
      final rankMode = _mode == _FindMode.rank;
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
              if (!rankMode)
                Padding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          explore.tab.id.isEmpty
                              ? '已选：全部剧集'
                              : '已选：${explore.tab.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: explore.tab.id.isEmpty
                            ? null
                            : () => _selectTab(explore, ''),
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('重置'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: feed == null
                    ? const StatusView.loading()
                    : RefreshIndicator(
                        key: _refreshKey,
                        onRefresh: explore.refresh,
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
                                            onAction: () => feed.reload(force: true),
                                          ),
                                  )
                                else ...[
                                  SliverPadding(
                                    padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                                    sliver: DramaSliverGrid(
                                      width: constraints.maxWidth - inset * 2,
                                      items: explore.items,
                                      rankOf: rankMode ? explore.rankOf : null,
                                      onOpen: _open,
                                    ),
                                  ),
                                  SliverToBoxAdapter(child: FeedFooter(feed: feed)),
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
