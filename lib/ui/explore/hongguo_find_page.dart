import 'dart:async';

import 'package:flutter/material.dart';

import '../../category_filter_models.dart';
import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/cover_image.dart';
import '../widgets/drama_grid.dart';
import '../widgets/drama_tile.dart';
import '../widgets/follow_button.dart';
import '../widgets/status_view.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';

class HongguoFindPage extends StatefulWidget {
  const HongguoFindPage({
    super.key,
    required this.explore,
    required this.store,
    required this.onOpen,
  });

  final ExploreFeed explore;
  final LocalStore store;
  final ValueChanged<Drama> onOpen;

  @override
  State<HongguoFindPage> createState() => _HongguoFindPageState();
}

class _HongguoFindPageState extends State<HongguoFindPage> {
  static const _rankMode = '榜单';
  static const _filterMode = '筛选找片';

  final _scroll = ScrollController();
  final _panelKey = GlobalKey();
  String _mode = _rankMode;
  CategoryFilterPanel? _panel;
  String _panelError = '';
  String _filterGenre = '';
  final Map<String, Set<String>> _selected = {};
  final Map<String, String> _selectedNames = {};
  final Set<String> _seenIds = {};
  DramaFeed? _filterFeed;
  int _filterOffset = 0;
  String _filterSessionId = '';
  int _panelGeneration = 0;
  int _filterGeneration = 0;
  bool _panelLoading = false;
  bool _collapsed = false;

  ExploreFeed get explore => widget.explore;
  SourceSite get source => explore.source!;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrollChanged);
  }

  @override
  void dispose() {
    _scroll.removeListener(_scrollChanged);
    _scroll.dispose();
    _filterFeed?.dispose();
    unawaited(explore.repository.cancelCategoryFilters());
    super.dispose();
  }

  void _scrollChanged() {
    if (_mode != _filterMode || _panelKey.currentContext == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final object = _panelKey.currentContext?.findRenderObject();
      if (object is! RenderBox || !object.attached) return;
      final top = object.localToGlobal(Offset.zero).dy;
      final next = top < MediaQuery.paddingOf(context).top + 76;
      if (next != _collapsed) setState(() => _collapsed = next);
    });
  }

  void _setMode(String value) {
    if (_mode == value) return;
    setState(() {
      _mode = value;
      _collapsed = false;
    });
    _toTop();
    if (value == _filterMode && _panel == null && !_panelLoading) {
      unawaited(_loadPanel());
    }
  }

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _loadPanel() async {
    final generation = ++_panelGeneration;
    final genre = _filterGenre;
    setState(() {
      _panelLoading = true;
      _panelError = '';
    });
    try {
      final panel = await explore.repository.categoryFilterPanel(
        source.id,
        genre: genre,
      );
      if (!mounted || generation != _panelGeneration || genre != _filterGenre) {
        return;
      }
      setState(() {
        _panel = panel;
        _panelLoading = false;
      });
      _reloadFilterResults();
    } catch (error) {
      if (!mounted || generation != _panelGeneration) return;
      setState(() {
        _panelError = error.toString();
        _panelLoading = false;
      });
    }
  }

  List<String> get _filterIds => [
    for (final values in _selected.values)
      ...values.where((value) => value.isNotEmpty),
  ]..sort();

  Future<CatalogPage> _loadFilterPage(int page, bool force) async {
    if (page <= 1) {
      _filterOffset = 0;
      _filterSessionId = '';
      _seenIds.clear();
    }
    final generation = _filterGeneration;
    final result = await explore.repository.categoryFilterPage(
      source.id,
      genre: _filterGenre,
      filterIds: _filterIds,
      offset: _filterOffset,
      sessionId: _filterSessionId,
      seenIds: _seenIds.toList(),
    );
    if (generation != _filterGeneration) {
      throw AppFailure('筛选条件已更新');
    }
    final items = [
      for (final item in result.items) Drama.fromJson(item),
    ];
    _filterOffset = result.nextOffset;
    _filterSessionId = result.sessionId;
    _seenIds.addAll(items.map((item) => item.sourceId.isNotEmpty ? item.sourceId : item.id));
    return CatalogPage(items, hasMore: result.hasMore, page: page);
  }

  void _reloadFilterResults() {
    if (_panel == null) return;
    _filterGeneration++;
    _filterFeed ??= DramaFeed(load: _loadFilterPage);
    unawaited(_filterFeed!.reload(force: true));
    if (mounted) setState(() {});
  }

  void _selectFilter(CategoryFilterRow row, CategoryFilterItem item) {
    if (row.type == 'genre') {
      if (_filterGenre == item.id) return;
      setState(() {
        _filterGenre = item.id;
        _selected.clear();
        _selectedNames.clear();
        if (item.id.isNotEmpty) {
          _selected['genre'] = {item.id};
          _selectedNames[item.id] = item.name;
        }
        _panel = null;
      });
      _filterGeneration++;
      unawaited(_loadPanel());
      return;
    }

    setState(() {
      final values = _selected.putIfAbsent(row.type, () => <String>{});
      if (item.id.isEmpty) {
        for (final id in values) {
          _selectedNames.remove(id);
        }
        values.clear();
      } else if (row.singleChoice) {
        for (final id in values) {
          if (id != item.id) _selectedNames.remove(id);
        }
        values
          ..clear()
          ..add(item.id);
        _selectedNames[item.id] = item.name;
      } else if (!values.add(item.id)) {
        values.remove(item.id);
        _selectedNames.remove(item.id);
      } else {
        _selectedNames[item.id] = item.name;
      }
      if (values.isEmpty) _selected.remove(row.type);
    });
    _reloadFilterResults();
  }

  void _removeFilter(String type, String id) {
    if (type == 'genre') {
      final row = _panel?.rows.where((item) => item.type == 'genre').firstOrNull;
      if (row != null) {
        _selectFilter(row, const CategoryFilterItem(id: '', name: '全部'));
      }
      return;
    }
    setState(() {
      _selected[type]?.remove(id);
      if (_selected[type]?.isEmpty == true) _selected.remove(type);
      _selectedNames.remove(id);
    });
    _reloadFilterResults();
  }

  void _resetFilters() {
    setState(() {
      _filterGenre = '';
      _selected.clear();
      _selectedNames.clear();
      _panel = null;
      _collapsed = false;
    });
    _filterGeneration++;
    unawaited(_loadPanel());
  }

  List<({String type, String id, String name})> _picks(CategoryFilterPanel panel) {
    final result = <({String type, String id, String name})>[];
    for (final row in panel.rows) {
      for (final id in _selected[row.type] ?? const <String>{}) {
        final name = row.items.where((item) => item.id == id).firstOrNull?.name ??
            _selectedNames[id] ??
            '';
        if (name.isNotEmpty) result.add((type: row.type, id: id, name: name));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: explore,
    builder: (context, _) {
      final form = AppScope.formFactorOf(context);
      final inset = form == FormFactor.phone ? 16.0 : 24.0;
      final modes = Padding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: CategoryTabs<String>(
          options: const [
            ChoiceOption(_rankMode, _rankMode),
            ChoiceOption(_filterMode, _filterMode),
          ],
          selected: _mode,
          onSelected: _setMode,
        ),
      );
      return Column(
        children: [
          modes,
          Expanded(
            child: _mode == _rankMode
                ? _rankContent(inset)
                : _filterContent(inset),
          ),
        ],
      );
    },
  );

  Widget _rankContent(double inset) {
    final feed = explore.feed;
    if (feed == null) return const StatusView.loading();
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) {
        final items = explore.items;
        if (feed.items.isEmpty) {
          return RefreshIndicator(
            onRefresh: () => feed.reload(force: true),
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _genreAndBoards(inset)),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: feed.loading
                      ? const Center(child: CircularProgressIndicator())
                      : _status(feed),
                ),
              ],
            ),
          );
        }
        final width = MediaQuery.sizeOf(context).width - inset * 2;
        final top = items.take(3).toList();
        final rest = items.skip(3).toList();
        return Stack(
          children: [
            AutoLoadMore(
              feed: feed,
              child: RefreshIndicator(
                onRefresh: () => feed.reload(force: true),
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(child: _genreAndBoards(inset)),
                    if (top.isNotEmpty)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(inset, 18, inset, 0),
                        sliver: SliverGrid(
                          gridDelegate: dramaGridDelegate(context, width),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => DramaTile(
                              drama: top[index],
                              rank: explore.rankOf(top[index]) ?? index + 1,
                              showScore: false,
                              exploreBlur: true,
                              onTap: () => widget.onOpen(top[index]),
                              onMore: () => quickFollow(context, widget.store, top[index]),
                            ),
                            childCount: top.length,
                          ),
                        ),
                      ),
                    if (rest.isNotEmpty)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(inset, 18, inset, 0),
                        sliver: SliverList.separated(
                          itemCount: rest.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          itemBuilder: (context, index) {
                            final drama = rest[index];
                            return _RankListRow(
                              drama: drama,
                              rank: explore.rankOf(drama) ?? index + 4,
                              onTap: () => widget.onOpen(drama),
                              onMore: () => quickFollow(context, widget.store, drama),
                            );
                          },
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 8, inset, 24),
                      sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _genreAndBoards(double inset) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Row(
            children: [
              for (final genre in explore.genreTabs)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(genre.name),
                    selected: explore.genre.id == genre.id,
                    onSelected: (_) => explore.selectGenre(genre.id),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Row(
            children: [
              for (final tab in explore.tabs)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(tab.name),
                    selected: explore.tab.id == tab.id,
                    onSelected: (_) => explore.select(tab.id),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterContent(double inset) {
    final feed = _filterFeed;
    return Stack(
      children: [
        if (_panelLoading && _panel == null)
          const StatusView.loading()
        else if (_panelError.isNotEmpty && _panel == null)
          StatusView(
            title: '筛选条件加载失败',
            message: _panelError,
            icon: Icons.cloud_off_rounded,
            action: '重试',
            onAction: _loadPanel,
          )
        else if (_panel != null)
          ListenableBuilder(
            listenable: feed ?? _EmptyListenable.instance,
            builder: (context, _) {
              final current = _filterFeed;
              if (current == null) return const StatusView.loading();
              return AutoLoadMore(
                feed: current,
                child: RefreshIndicator(
                  onRefresh: () => current.reload(force: true),
                  child: CustomScrollView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          key: _panelKey,
                          padding: const EdgeInsets.only(top: 18),
                          child: _filterPanel(inset),
                        ),
                      ),
                      if (current.items.isEmpty && current.loading)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (current.items.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _status(current),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                          sliver: DramaSliverGrid(
                            width: MediaQuery.sizeOf(context).width - inset * 2,
                            items: current.items,
                            exploreBlur: true,
                            onOpen: widget.onOpen,
                            onMore: (drama) => quickFollow(context, widget.store, drama),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(inset, 8, inset, 24),
                        sliver: SliverToBoxAdapter(child: FeedFooter(feed: current)),
                      ),
                    ],
                  ),
                ),
              );
            },
          )
        else
          const StatusView.loading(),
        if (_mode == _filterMode && _collapsed && _panel != null)
          Positioned(
            top: 4,
            left: 12,
            right: 12,
            child: _stickyBar(),
          ),
      ],
    );
  }

  Widget _filterPanel(double inset) {
    final panel = _panel!;
    final genreRow = panel.rows.where((row) => row.type == 'genre').firstOrNull;
    final rows = panel.rows.where((row) => row.type != 'genre').toList();
    final picks = _picks(panel);
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.symmetric(horizontal: inset),
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (genreRow != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: _filterChips(
                genreRow,
                [const CategoryFilterItem(id: '', name: '全部'), ...genreRow.items],
              ),
            ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
              child: _filterChips(
                row,
                [const CategoryFilterItem(id: '', name: '全部'), ...row.items],
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
            child: Row(
              children: [
                Text('已选', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13)),
                const SizedBox(width: 8),
                Expanded(
                  child: picks.isEmpty
                      ? Text('全部剧集', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13))
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final pick in picks)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InputChip(
                                    label: Text(pick.name),
                                    onDeleted: () => _removeFilter(pick.type, pick.id),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                TextButton.icon(
                  onPressed: picks.isEmpty ? null : _resetFilters,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重置'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChips(
    CategoryFilterRow row,
    List<CategoryFilterItem> items,
  ) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected[row.type] ?? const <String>{};
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (row.type != 'genre')
          SizedBox(
            width: 52,
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: row.singleChoice
                        ? ChoiceChip(
                            label: Text(item.name),
                            selected: selected.contains(item.id) || (item.id.isEmpty && selected.isEmpty),
                            onSelected: (_) => _selectFilter(row, item),
                            visualDensity: VisualDensity.compact,
                          )
                        : FilterChip(
                            label: Text(item.name),
                            selected: selected.contains(item.id) || (item.id.isEmpty && selected.isEmpty),
                            onSelected: (_) => _selectFilter(row, item),
                            visualDensity: VisualDensity.compact,
                          ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _stickyBar() {
    final panel = _panel!;
    final picks = _picks(panel);
    final colors = Theme.of(context).colorScheme;
    final title = picks.isEmpty ? '全部剧集' : picks.map((pick) => pick.name).join(' · ');
    return Material(
      elevation: 5,
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          _toTop();
          setState(() => _collapsed = false);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, color: colors.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (picks.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(12)),
                  child: Text('${picks.length}', style: TextStyle(color: colors.onPrimary, fontSize: 11)),
                ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status(DramaFeed feed) {
    if (feed.loading) return const StatusView.loading();
    if (feed.error.isNotEmpty) {
      return StatusView(
        title: '暂时无法加载',
        message: feed.error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => feed.reload(force: true),
      );
    }
    return StatusView(
      title: '没有找到符合条件的剧',
      message: '可以调整筛选条件再试试',
      icon: Icons.inbox_outlined,
      action: '重置筛选',
      onAction: _resetFilters,
    );
  }
}

class _RankListRow extends StatelessWidget {
  const _RankListRow({
    required this.drama,
    required this.rank,
    required this.onTap,
    required this.onMore,
  });
  final Drama drama;
  final int rank;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                rank.toString().padLeft(2, '0'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: rank <= 3 ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 62,
              height: 90,
              child: DramaCover(drama: drama, details: false, radius: 8, exploreBlur: true),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(drama.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 7),
                  Text(
                    [
                      if (drama.category.isNotEmpty) drama.category,
                      if (drama.episodes > 0) '${drama.episodes}集',
                      if (drama.heat.isNotEmpty) drama.heat,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                  ),
                  if (drama.description.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(drama.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '收藏 / 预约',
              onPressed: onMore,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyListenable extends ChangeNotifier {
  static final instance = _EmptyListenable();
}
