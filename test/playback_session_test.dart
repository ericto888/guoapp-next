import 'dart:ui';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _PlaybackRepository extends FakeRepository {
  final resolved = <({int episode, int quality})>[];
  final released = <String>[];
  final preloaded = <int>[];
  var fallbacks = 0;
  var resolveFailure = '';
  var _sessions = 0;

  bool streamAlive = true;
  int statusFailures = 0;
  int statusCalls = 0;

  @override
  Future<PlaybackStreamStatus> playbackStatus() async {
    statusCalls++;
    if (statusFailures > 0) {
      statusFailures--;
      throw StateError('temporary probe failure');
    }
    return PlaybackStreamStatus(alive: streamAlive);
  }

  PlaybackPlan _plan({int route = 0}) {
    _sessions++;
    return PlaybackPlan(
      url: 'https://media.test/$_sessions.m3u8',
      session: 'session-$_sessions',
      routeIndex: route,
      routeCount: 2,
      quality: 1080,
      qualities: const [1080, 720],
    );
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolved.add((episode: episode.number, quality: quality));
    if (resolveFailure.isNotEmpty) throw AppFailure(resolveFailure);
    return _plan();
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async {
    fallbacks++;
    return _plan(route: current.routeIndex + 1);
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    preloaded.add(episode.number);
    return _plan();
  }

  @override
  Future<void> release(String session) async => released.add(session);
}

class _AdvancingPlayer extends FakePlayer {
  @override
  Future<void> play() async {
    progress(state.position + const Duration(seconds: 1));
    await super.play();
  }
}

final _show = drama('show', title: '测试剧');

Future<(PlaybackSession, FakePlayer)> _open(
  _PlaybackRepository repository,
  LocalStore store, {
  int index = 0,
  double position = 0,
  FakePlayer? standby,
  bool autoplay = true,
}) async {
  final player = FakePlayer();
  final session = PlaybackSession(
    repository: repository,
    store: store,
    detail: dramaDetail(_show, count: 3),
    player: player,
    standby: standby,
    index: index,
    position: position,
    autoplay: autoplay,
  );
  addTearDown(() {
    if (_closed.add(session)) session.dispose();
  });
  await pumpEventQueue();
  return (session, player);
}

final _closed = <PlaybackSession>{};

void _close(PlaybackSession session) {
  _closed.add(session);
  session.dispose();
}

Duration _seconds(num value) => Duration(milliseconds: (value * 1000).round());

Future<void> _settle(FakePlayer player) async {
  player.state = player.state.copyWith(buffer: _seconds(80));
  player.progress(_seconds(60), duration: _seconds(100));
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await pumpEventQueue();
}

void main() {
  test('blocked words saved elsewhere reach the playing session', () async {
    final store = await openStore();
    final (session, _) = await _open(_PlaybackRepository(), store);

    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(danmakuWords: const ['剧透']),
    );
    expect(session.danmaku.blockedWords, ['剧透']);
  });

  test('opens the episode at the resume position and saves progress', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(
      repository,
      store,
      index: 1,
      position: 30,
    );

    expect(session.ready, isTrue);
    expect(session.episode.number, 2);
    expect(repository.resolved.single, (episode: 2, quality: 0));
    expect(player.opened.single.uri, 'https://media.test/1.m3u8');
    expect(player.opened.single.start, _seconds(30));
    expect(player.rates, [1.0]);
    expect(session.qualityLabel, '自动（1080P）');

    player.progress(_seconds(40), duration: _seconds(100));
    await session.saveProgress();
    final watch = store.watched(_show.id)!;
    expect(watch.episode, 2);
    expect(watch.position, 40);
    expect(watch.duration, 100);
  });

  test('a finished episode moves on to the next one', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.progress(_seconds(99.5), duration: _seconds(100));
    player.finish();
    await pumpEventQueue();

    expect(session.index, 1);
    expect(session.ready, isTrue);
    expect(player.opened, hasLength(2));
    expect(player.opened.last.start, isNull);
    expect(repository.released, contains('session-1'));
    expect(store.watched(_show.id)!.episode, 1);
  });

  test('the last episode stops at its end instead of looping', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store, index: 2);

    player.progress(_seconds(99.5), duration: _seconds(100));
    player.finish();
    await pumpEventQueue();

    expect(session.index, 2);
    expect(player.opened, hasLength(1));
    expect(store.watched(_show.id)!.episode, 3);
  });

  test('a player error switches to the other route at the same spot', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.progress(_seconds(20), duration: _seconds(100));
    player.fail('connection reset by https://media.test/1.m3u8?token=x');
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await pumpEventQueue();

    expect(repository.fallbacks, 1);
    expect(repository.resolved, hasLength(1));
    expect(player.opened, hasLength(2));
    expect(player.opened.last.start, _seconds(20));
    expect(session.ready, isTrue);
    expect(repository.released, contains('session-1'));
  });

  test('a quality change is saved and reloads where it was', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.progress(_seconds(15), duration: _seconds(100));
    await session.setQuality(720);

    expect(store.playbackPreferences.quality, 720);
    expect(repository.resolved.last, (episode: 1, quality: 720));
    expect(player.opened.last.start, _seconds(15));
    expect(session.qualityLabel, '720P');
  });

  test('speed changes are saved and applied unless boosting', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    await session.setSpeed(1.5);
    expect(store.playbackPreferences.speed, 1.5);
    expect(player.rates.last, 1.5);

    session.beginBoost();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(session.boosting, isTrue);
    expect(player.rates.last, 2);
    expect(session.endBoost(), isTrue);
    await pumpEventQueue();
    expect(player.rates.last, 1.5);
    expect(session.endBoost(), isFalse);
  });

  test('a volume change while paused flushes audio before resuming', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.progress(_seconds(12), duration: _seconds(100));
    session.togglePlayback();
    await pumpEventQueue();
    expect(player.state.playing, isFalse);

    expect(session.toggleMute(), 0);
    session.togglePlayback();
    await pumpEventQueue();
    expect(player.seeks, [_seconds(12)]);
    expect(player.state.playing, isTrue);

    session.togglePlayback();
    session.togglePlayback();
    await pumpEventQueue();
    expect(player.seeks, hasLength(1));
  });

  test('a failed resolve shows the reason and retry loads again', () async {
    final repository = _PlaybackRepository()..resolveFailure = '站源暂时不可用';
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    expect(session.ready, isFalse);
    expect(session.error, '站源暂时不可用');
    expect(player.opened, isEmpty);

    repository.resolveFailure = '';
    await session.retry();
    expect(session.error, isNull);
    expect(session.ready, isTrue);
    expect(player.opened, hasLength(1));
  });

  test('switching users pauses and stops recording progress', () async {
    final repository = _PlaybackRepository();
    final store = await openStore(viewerPreferences);
    final (session, player) = await _open(repository, store);

    player.progress(_seconds(30), duration: _seconds(100));
    await store.switchProfile('viewer');
    await pumpEventQueue();

    expect(player.state.playing, isFalse);
    await session.saveProgress();
    expect(store.watched(_show.id), isNull);
    expect(() => session.setSpeed(2), throwsStateError);
  });

  test('closing saves progress and releases the session and player', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.progress(_seconds(50), duration: _seconds(100));
    _close(session);
    await pumpEventQueue();

    expect(store.watched(_show.id)!.position, 50);
    expect(repository.released, contains('session-1'));
    expect(player.disposed, isTrue);
  });

  test('video size sets the aspect ratio', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.resize(1920, 1080);
    expect(session.aspectRatio, closeTo(16 / 9, .001));
    expect(
      videoDisplaySize(const VideoParams(w: 1920, h: 1080, rotate: 90)),
      const Size(1080, 1920),
    );
  });

  test('a paused preopen records nothing until it starts', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(
      repository,
      store,
      position: 30,
      autoplay: false,
    );

    expect(player.opened.single.start, _seconds(30));
    expect(player.state.playing, isFalse);
    player.progress(_seconds(31), duration: _seconds(100));
    await session.saveProgress();
    expect(store.watched(_show.id), isNull);

    session.start(0, position: 30);
    await pumpEventQueue();
    expect(player.state.playing, isTrue);
    expect(session.paused, isFalse);
    expect(player.opened, hasLength(1));
    await session.saveProgress();
    expect(store.watched(_show.id)!.position, 31);
  });

  test(
    'starting a different episode than the preopened one loads it',
    () async {
      final repository = _PlaybackRepository();
      final store = await openStore();
      final (session, player) = await _open(
        repository,
        store,
        position: 30,
        autoplay: false,
      );

      session.start(2);
      await pumpEventQueue();

      expect(session.index, 2);
      expect(repository.resolved.last.episode, 3);
      expect(player.opened.last.start, isNull);
      expect(player.state.playing, isTrue);
    },
  );

  test('the next episode waits paused in the standby player', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final standby = FakePlayer();
    final (session, player) = await _open(repository, store, standby: standby);

    await _settle(player);

    expect(repository.preloaded, [2]);
    expect(session.standbyIndex, 1);
    expect(identical(session.standby, standby), isTrue);
    expect(standby.opened.single.uri, 'https://media.test/2.m3u8');
    expect(standby.state.playing, isFalse);

    player.finish();
    await pumpEventQueue();

    expect(session.index, 1);
    expect(identical(session.player, standby), isTrue);
    expect(standby.state.playing, isTrue);
    expect(standby.opened, hasLength(1));
    expect(repository.resolved, hasLength(1));
    expect(player.stops, greaterThan(0));
    expect(repository.released, contains('session-1'));
    expect(session.standbyIndex, -1);
  });

  test('jumping elsewhere drops the waiting next episode', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final standby = FakePlayer();
    final (session, player) = await _open(repository, store, standby: standby);
    await _settle(player);

    await session.play(2);

    expect(identical(session.player, player), isTrue);
    expect(session.standbyIndex, -1);
    expect(standby.stops, greaterThan(0));
    expect(repository.released, contains('session-2'));
    expect(repository.resolved.last.episode, 3);
  });

  test('a locked boost survives pausing and switching episodes', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    session.setBoostLocked(true);
    await pumpEventQueue();
    expect(player.rates.last, 2);

    session.togglePlayback();
    await pumpEventQueue();
    expect(session.boosting, isTrue);

    await session.play(1);
    expect(player.rates.last, 2);
    expect(session.boostLocked, isTrue);

    session.setBoostLocked(false);
    await pumpEventQueue();
    expect(player.rates.last, 1);
    expect(session.boosting, isFalse);
  });

  test('holding boosts at once and letting go restores the speed', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    session.holdBoost();
    await pumpEventQueue();
    expect(player.rates.last, 2);

    session.endBoost();
    await pumpEventQueue();
    expect(player.rates.last, 1);

    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(boostSpeed: 3),
    );
    session.holdBoost();
    await pumpEventQueue();
    expect(player.rates.last, 3);
  });

  test(
    'the next episode opens near the end and keeps loading while paused',
    () async {
      final repository = _PlaybackRepository();
      final store = await openStore();
      final standby = FakePlayer();
      final (session, player) = await _open(
        repository,
        store,
        standby: standby,
      );

      session.togglePlayback();
      player.state = player.state.copyWith(buffer: _seconds(24));
      player.progress(_seconds(20), duration: _seconds(100));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await pumpEventQueue();
      expect(repository.preloaded, isEmpty);
      expect(session.standbyIndex, -1);

      player.state = player.state.copyWith(buffer: _seconds(64));
      player.progress(_seconds(60), duration: _seconds(100));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await pumpEventQueue();

      expect(player.state.playing, isFalse);
      expect(session.standbyIndex, 1);
    },
  );

  test('a paused preopen does not open the next episode', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final standby = FakePlayer();
    final (session, player) = await _open(
      repository,
      store,
      standby: standby,
      autoplay: false,
    );

    await _settle(player);

    expect(repository.preloaded, isEmpty);
    expect(session.standbyIndex, -1);
  });

  test(
    'starting a preopened session restores the user play intent',
    () async {
      final repository = _PlaybackRepository();
      final store = await openStore();
      final (session, player) = await _open(
        repository,
        store,
        autoplay: false,
      );

      expect(session.ready, isTrue);
      expect(session.paused, isTrue);
      expect(player.state.playing, isFalse);

      session.start(0);
      await pumpEventQueue();

      expect(player.state.playing, isTrue);
      expect(session.paused, isFalse);
    },
  );

  test('switching to the waiting episode swaps players at once', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final standby = FakePlayer();
    final (session, player) = await _open(repository, store, standby: standby);
    await _settle(player);

    final switching = session.play(1);

    expect(identical(session.player, standby), isTrue);
    expect(session.ready, isTrue);
    expect(session.paused, isFalse);
    await switching;
    expect(standby.state.playing, isTrue);
    expect(store.watched(_show.id)!.episode, 1);
  });

  test(
    'swapping to a standby player preserves an explicit paused intent',
    () async {
      final repository = _PlaybackRepository();
      final store = await openStore();
      final standby = FakePlayer();
      final (session, player) = await _open(
        repository,
        store,
        standby: standby,
      );
      await _settle(player);

      await session.play(1, playWhenReady: false);

      expect(identical(session.player, standby), isTrue);
      expect(session.paused, isTrue);
      expect(standby.state.playing, isFalse);
    },
  );

  test('only buffering that lasts counts as stalled', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);

    player.buffer(true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    player.buffer(false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(session.stalled, isFalse);

    player.buffer(true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(session.stalled, isTrue);
    player.buffer(false);
    expect(session.stalled, isFalse);
  });

  test('lifecycle suspension does not appear as a user pause', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);
    await _settle(player);

    expect(session.paused, isFalse);

    // Backgrounding pauses the engine, but must not change the user's intent.
    session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
    expect(player.state.playing, isFalse);
    expect(session.paused, isFalse);

    session.onLifecycleEvent(AppLifecycleState.resumed, source: 'test');
    await pumpEventQueue();
    expect(session.paused, isFalse);

    // An explicit user pause remains visible and must survive backgrounding.
    session.togglePlayback();
    expect(session.paused, isTrue);
    session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
    session.onLifecycleEvent(AppLifecycleState.resumed, source: 'test');
    expect(session.paused, isTrue);
    await pumpEventQueue();
    expect(player.state.playing, isFalse);
  });

  test('rebuilds the player when lifecycle resume cannot advance', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final player = FakePlayer();
    final rebuilt = FakePlayer();
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: dramaDetail(_show, count: 3),
      player: player,
      respawn: () => rebuilt,
      index: 0,
      position: 5,
    );
    addTearDown(() {
      if (_closed.add(session)) session.dispose();
    });
    await pumpEventQueue();
    expect(player.opened.single.start, _seconds(5));

    // iOS 切出/锁屏：只有 paused→resumed 序列，旧实例回前台位置不再推进。
    session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
    session.onLifecycleEvent(AppLifecycleState.resumed, source: 'test');

    await Future<void>.delayed(const Duration(milliseconds: 3600));
    expect(identical(session.player, rebuilt), isTrue);
    expect(player.disposed, isTrue);
    expect(rebuilt.opened.first.start, _seconds(5));
  });

  test('rebuilds when the local stream listener is gone', () async {
    final repository = _PlaybackRepository()..streamAlive = false;
    final store = await openStore();
    final player = FakePlayer();
    final rebuilt = FakePlayer();
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: dramaDetail(_show, count: 3),
      player: player,
      respawn: () => rebuilt,
      index: 0,
    );
    addTearDown(() {
      if (_closed.add(session)) session.dispose();
    });
    await pumpEventQueue();

    // 后台监听被系统回收：缓冲耗尽后播放器报 connection refused。
    player.fail('tcp: Connection refused');
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    expect(identical(session.player, rebuilt), isTrue);
    expect(repository.fallbacks, 0);
  });

  test(
    'inactive freezes next-episode preload without pausing current playback',
    () async {
      final repository = _PlaybackRepository();
      final store = await openStore();
      final standby = FakePlayer();
      final (session, player) = await _open(
        repository,
        store,
        standby: standby,
      );
      await _settle(player);

      expect(session.standbyIndex, 1);
      expect(player.state.playing, isTrue);

      session.onLifecycleEvent(AppLifecycleState.inactive, source: 'test');
      await pumpEventQueue();

      expect(player.state.playing, isTrue);
      expect(session.standbyIndex, -1);
      expect(standby.stops, greaterThan(0));
      expect(repository.released, contains('session-2'));
    },
  );

  test(
    'iOS dead stream is probed before old player play and rebuilds directly',
    () async {
      final repository = _PlaybackRepository()..streamAlive = false;
      final store = await openStore();
      final player = _AdvancingPlayer();
      final rebuilt = FakePlayer();
      final session = PlaybackSession(
        repository: repository,
        store: store,
        detail: dramaDetail(_show, count: 3),
        player: player,
        respawn: () => rebuilt,
        index: 0,
        position: 9.5,
        isIOS: true,
      );
      addTearDown(() {
        if (_closed.add(session)) session.dispose();
      });
      await pumpEventQueue();

      session.onLifecycleEvent(AppLifecycleState.inactive, source: 'test');
      session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
      session.onLifecycleEvent(AppLifecycleState.resumed, source: 'test');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(repository.statusCalls, 1);
      expect(
        player.playCalls,
        0,
        reason: 'dead listener must be detected before old play',
      );
      expect(identical(session.player, rebuilt), isTrue);
      expect(rebuilt.opened.single.start, _seconds(9.5));
    },
  );

  test('iOS alive stream keeps the in-place restore path', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final player = _AdvancingPlayer();
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: dramaDetail(_show, count: 3),
      player: player,
      index: 0,
      position: 9.5,
      isIOS: true,
    );
    addTearDown(() {
      if (_closed.add(session)) session.dispose();
    });
    await pumpEventQueue();

    session.onLifecycleEvent(AppLifecycleState.inactive, source: 'test');
    session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
    session.onLifecycleEvent(AppLifecycleState.resumed, source: 'test');
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(repository.statusCalls, 1);
    expect(player.playCalls, 1);
    expect(identical(session.player, player), isTrue);
  });

  test('iOS unknown stream probe still attempts in-place restore', () async {
    final repository = _PlaybackRepository()..statusFailures = 1;
    final store = await openStore();
    final player = _AdvancingPlayer();
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: dramaDetail(_show, count: 3),
      player: player,
      index: 0,
      position: 9.5,
      isIOS: true,
    );
    addTearDown(() {
      if (_closed.add(session)) session.dispose();
    });
    await pumpEventQueue();

    session.onLifecycleEvent(AppLifecycleState.inactive, source: 'test');
    session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
    session.onLifecycleEvent(AppLifecycleState.resumed, source: 'test');
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(repository.statusCalls, 2);
    expect(player.playCalls, 1);
    expect(identical(session.player, player), isTrue);
  });

  test('upstream HTTP 503 refreshes the current signed URL first', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final (session, player) = await _open(repository, store);
    await _settle(player);

    player.fail('HTTP error 503 Service Unavailable');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await pumpEventQueue();

    expect(repository.resolved, hasLength(2));
    expect(repository.fallbacks, 0);
    expect(session.ready, isTrue);
  });

  test('background drops the standby player', () async {
    final repository = _PlaybackRepository();
    final store = await openStore();
    final standby = FakePlayer();
    final (session, player) = await _open(repository, store, standby: standby);
    await _settle(player);
    expect(session.standbyIndex, 1);
    expect(identical(session.standby, standby), isTrue);

    // 系统可能在后台回收本机监听，待机地址随之失效，必须换新实例。
    session.onLifecycleEvent(AppLifecycleState.paused, source: 'test');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(session.standbyIndex, -1);
    expect(session.standby, isNull);
    expect(standby.disposed, isTrue);
  });
}
