import 'package:flutter/material.dart';

import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../cover_blur.dart';
import '../detail/detail_page.dart';
import '../widgets/bar_button.dart';
import '../widgets/source_bar.dart';
import '../widgets/status_view.dart';
import 'hongguo_find_page.dart';
import 'source_actions.dart';

class HongguoFindModule extends StatefulWidget {
  const HongguoFindModule({super.key, required this.store});

  final LocalStore store;

  @override
  State<HongguoFindModule> createState() => _HongguoFindModuleState();
}

class _HongguoFindModuleState extends State<HongguoFindModule> {
  ExploreFeed? _explore;
  final _search = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(
      AppScope.of(context).repository,
      widget.store,
      rankingMode: true,
      sourceId: hongguoFindSourceId,
    );
  }

  @override
  void dispose() {
    _explore?.dispose();
    _search.dispose();
    super.dispose();
  }

  void _open(Drama drama) => Navigator.of(
    context,
    rootNavigator: switch (AppScope.formFactorOf(context)) {
      FormFactor.phone || FormFactor.television => true,
      FormFactor.pad || FormFactor.window => false,
    },
  ).push(
    MaterialPageRoute<void>(
      builder: (_) => DetailPage(store: widget.store, drama: drama),
    ),
  );

  void _searchSubmitted(SourceSite source, String query) {
    if (query.trim().isEmpty) return;
    _search.clear();
    openSearch(context, widget.store, source, query: query);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_explore!, widget.store]),
    builder: (context, _) {
      final explore = _explore!;
      final source = explore.source;
      final television = AppScope.formFactorOf(context) == FormFactor.television;
      if (source == null) {
        return const Scaffold(
          body: StatusView(
            title: '找剧模块暂不可用',
            message: '请确认红果短剧站源已安装并启用。',
            icon: Icons.extension_off_rounded,
          ),
        );
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
                  showSourceSwitcher: false,
                  onSwitchSource: (_) {},
                  onOpenSearch: () => openSearch(context, widget.store, source),
                  onSearchSubmitted: (query) => _searchSubmitted(source, query),
                  leading: [
                    if (widget.store.blurCoversButton)
                      if (CoverBlurScope.of(context) case final blur?)
                        BarButton(
                          icon: blur.mode != CoverBlur.off
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          tooltip: blur.mode != CoverBlur.off ? '显示封面' : '模糊封面',
                          onPressed: blur.onToggle,
                        ),
                  ],
                ),
              Expanded(
                child: HongguoFindPage(
                  key: ValueKey(source.id),
                  explore: explore,
                  store: widget.store,
                  onOpen: _open,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
