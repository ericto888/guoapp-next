import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState, Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'app_device.dart';
import 'core_bridge.dart';
import 'danmaku_controller.dart';
import 'danmaku_style.dart';
import 'diary_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'playback_preferences.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';

Size? videoDisplaySize(VideoParams parameters) {
  final width = (parameters.dw ?? 0) > 0 ? parameters.dw! : parameters.w ?? 0;
  final height = (parameters.dh ?? 0) > 0 ? parameters.dh! : parameters.h ?? 0;
  if (width <= 0 || height <= 0) return null;
  final rotation = (parameters.rotate ?? 0) % 180;
  return rotation == 90
      ? Size(height.toDouble(), width.toDouble())
      : Size(width.toDouble(), height.toDouble());
}

String _diagnostic(Object error) {
  final text = error.toString().replaceAll(
    RegExp(r'[a-z]+://\S+', caseSensitive: false),
    '[地址]',
  );
  return text.length > 300 ? text.substring(0, 300) : text;
}

/// 取流探活结果：只有两次都明确返回 false 才算确认失效。
enum _StreamProbe { alive, dead, unknown }

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.repository,
    required this.store,
    required this.detail,
    required Player player,
    this._standby,
    this._respawn,
    this._onRetired,
    this._spawnStandby,
    required int index,
    double position = 0,
    bool autoplay = true,
    @visibleForTesting bool? isIOS,
  }) : _player = player,
       _isIOS = isIOS ?? Platform.isIOS,
       _engaged = autoplay,
       _index = index,
       _epoch = store.profileEpoch {
    final preferences = store.playbackPreferences;
    _speed = preferences.speed;
    _quality = preferences.quality;
    _danmakuEnabled = preferences.danmaku;
    _videoFit = preferences.videoFit;
    _unmutedVolume = store.playerVolume.clamp(1.0, 100.0);
    unawaited(_player.setVolume(_unmutedVolume));
    _loader = PlaybackLoader(repository);
    _preloader = PlaybackPreloader(repository)..addListener(_prime);
    danmaku = DanmakuController(repository)
      ..setEnabled(_danmakuEnabled)
      ..setBlockedWords(preferences.danmakuWords);
    store.addListener(_accessChanged);
    store.addListener(_syncBlockedWords);
    _bind();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => saveProgress(quiet: true),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || !_acceptErrors || _loading || _error != null) return;
      if (_health.stalled(
        position: player.state.position,
        // 缓冲中即使 mpv 暂时报 playing=false，也说明用户仍有播放意图；
        // 否则卡在缓冲时停滞检测永远不会触发。
        playing:
            _playIntent && (player.state.playing || player.state.buffering),
        foreground: _foreground,
        now: DateTime.now(),
      )) {
        DiaryService.add(
          '[Play] 停滞检测 位置=${player.state.position.inSeconds}s '
          '播放=${player.state.playing} 缓冲=${player.state.buffering}',
        );
        unawaited(_recover('position_stalled_20s'));
      }
    });
    unawaited(play(index, position: position, playWhenReady: autoplay));
  }

  void _bind() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final size = videoDisplaySize(player.state.videoParams);
    if (size != null) _videoSize = size;
    _buffering(player.state.buffering);
    final stream = player.stream;
    _subscriptions.addAll([
      stream.error.listen(_playerError),
      stream.completed.listen(_completed),
      stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
          if (position >= const Duration(seconds: 2)) {
            unawaited(_logVideoOutput(player.state.videoParams));
          }
        }
        _sync();
      }),
      stream.playing.listen((playing) {
        if (!playing) {
          endBoost();
          _networkSpeed = 0;
        }
        _sync();
      }),
      stream.buffering.listen((buffering) {
        _buffering(buffering);
        _sync();
      }),
      for (final changes in [stream.duration, stream.buffer, stream.rate])
        changes.listen((_) => _sync()),
      stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size == null || _closed) return;
        _videoSize = size;
        _notify();
        unawaited(_logVideoOutput(parameters));
      }),
    ]);
  }

  int? _networkSpeed;
  bool _speedReading = false;
  Duration? _speedResumeAt;
  DateTime? _speedResumeDeadline;

  void _holdNetworkSpeed() {
    _speedResumeAt = player.state.position;
    _speedResumeDeadline = DateTime.now().add(const Duration(seconds: 15));
  }

  String _videoOutput = '';
  String _videoOutputSession = '';

  Future<void> _logVideoOutput(VideoParams parameters) async {
    final platform = player.platform;
    if (parameters.pixelformat == null || platform is! NativePlayer) return;
    if (!player.state.playing ||
        player.state.buffering ||
        player.state.position < const Duration(seconds: 2)) {
      return;
    }
    final session = _plan?.session ?? '';
    if (session.isEmpty || session == _videoOutputSession) return;
    try {
      final values = [
        for (final name in [
          'hwdec-current',
          'current-vo',
          'video-codec',
          'container-fps',
        ])
          await platform.getProperty(name),
      ];
      if (_closed) return;
      _videoOutputSession = session;
      final line =
          '[Video] decoder=${store.playbackPreferences.televisionDecoder.name} hwdec=${values[0]} vo=${values[1]} codec=${values[2]} fps=${values[3]} format=${parameters.pixelformat} hw_format=${parameters.hwPixelformat} size=${parameters.w}x${parameters.h}';
      if (line == _videoOutput) return;
      _videoOutput = line;
      DiaryService.add(line);
    } catch (_) {}
  }

  final AppRepository repository;
  final LocalStore store;
  DramaDetail detail;
  Player _player;
  final bool _isIOS;
  Player? _standby;

  /// 切出/锁屏后底层实例可能已被系统回收，恢复播放前需要重建播放器。
  final Player Function()? _respawn;
  final void Function(Player player)? _onRetired;
  final Player Function()? _spawnStandby;
  bool _rebuilding = false;
  bool _rebuildQueued = false;
  double _queuedPosition = 0;
  bool _queuedPlay = true;
  int? _queuedToken;
  late final DanmakuController danmaku;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  final _recovery = PlaybackRecovery();
  final _health = PlaybackHealth();
  final int _epoch;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _boostTimer;
  Timer? _stallTimer;
  Timer? _volumeTimer;
  Timer? _sleepTimer;
  Timer? _standbyIdleTimer;
  Timer? _resumeTimer;
  Timer? _seekWatchdog;
  DateTime? _pausedSince;
  DateTime? _sleepAt;
  int _sleepMinutes = 0;
  bool _sleepAtEpisodeEnd = false;
  bool _advancingSeason = false;
  Future<void> _operations = Future<void>.value();
  Future<void> _rates = Future<void>.value();
  int _index;
  int _openedIndex = -1;
  int _generation = 0;
  int _seekSequence = 0;
  bool _loading = true;
  bool _online = false;
  bool _localFailure = false;
  bool _loginRequired = false;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _resumeIntent = true;
  bool _lifecycleDormant = false;
  bool _pipActive = false;
  AppLifecycleState? _lastLifecycle;
  int _restoreToken = 0;
  bool _pendingError = false;
  bool _boosting = false;
  bool _boostLocked = false;
  bool _locked = false;
  bool _engaged;
  bool _staleAudio = false;
  bool _stalled = false;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  String? _savedProgressKey;
  bool _savedQuietly = false;
  PlaybackPlan? _plan;
  int _streamEpoch = 0;
  PlaybackPlan? _standbyPlan;
  int _standbyIndex = -1;
  bool _standbyOpen = false;
  bool _standbyCleaning = false;
  Future<void> _standbyCleanup = Future<void>.value();
  Future<void>? _standbyOpening;
  DateTime _standbyAt = DateTime(2000);
  double _openedAt = 0;
  double _speed = 1;
  int _quality = 0;
  bool _danmakuEnabled = true;
  Size? _videoSize;
  VideoFit _videoFit = VideoFit.auto;
  double _resumePosition = 0;
  double _unmutedVolume = 100;

  Player get player => _player;

  Player? get standby => _standbyOpen ? _standby : null;
  int get standbyIndex => _standbyOpen ? _standbyIndex : -1;
  int get index => _index;
  Episode get episode => detail.episodes[_index];
  bool get loading => _loading;
  String get loadingMessage => _loadingMessage;
  String? get error => _error;
  bool get localFailure => _localFailure;
  bool get loginRequired => _loginRequired;
  String? get saveWarning => _saveWarning;
  bool get ready => !_loading && _error == null;
  bool get advancingSeason => _advancingSeason;
  DramaSeason? get nextSeason => detail.nextSeason;

  /// Exposes the same explicit next-season action used by the portrait pager.
  Future<void> playNextSeason() => _playNextSeason();

  bool get stalled => _stalled;

  bool get paused => !_playIntent;
  bool get boosting => _boosting;
  bool get boostLocked => _boostLocked;
  bool get locked => _locked;
  Size? get videoSize => _videoSize;
  double get aspectRatio => switch (_videoSize) {
    final size? => size.width / size.height,
    null => 9 / 16,
  };
  bool get aspectKnown => _videoSize != null;
  VideoFit get videoFit => _videoFit;
  double get speed => _speed;
  DateTime? get sleepAt => _sleepAt;
  int get sleepMinutes => _sleepMinutes;
  bool get sleepAtEpisodeEnd => _sleepAtEpisodeEnd;
  int get quality => _quality;
  bool get local => _plan?.local == true;
  List<int> get qualities => _plan?.qualities ?? const [];
  bool get danmakuSupported => SourceSite.byId(detail.drama.source).danmaku;
  bool get danmakuEnabled => _danmakuEnabled;
  PlaybackPreferences get preferences => _preferences;
  DanmakuStyle get danmakuStyle => DanmakuStyle.of(store.playbackPreferences);
  bool get hasPrevious => _index > 0;
  bool get hasNext => _index + 1 < detail.episodes.length;
  String get qualityLabel {
    final plan = _plan;
    if (plan != null && plan.local) {
      return plan.quality > 0 ? '本地 ${plan.quality}P' : '本地';
    }
    if (_quality > 0) return '${_quality}P';
    return plan != null && plan.quality > 0 ? '自动（${plan.quality}P）' : '自动';
  }

  double get currentPosition =>
      _openedIndex == _index && player.state.position > Duration.zero
      ? player.state.position.inMilliseconds / 1000
      : _resumePosition;

  bool get _usable => !_closed && store.profileEpoch == _epoch;
  bool _current(int ticket) => _usable && ticket == _generation;

  PlaybackPreferences get _preferences => store.playbackPreferences.copyWith(
    speed: _speed,
    quality: _quality,
    danmaku: _danmakuEnabled,
    videoFit: _videoFit,
    autoAdvance: true,
    preload: true,
  );

  double get _rate => _boosting ? store.playbackPreferences.boostSpeed : _speed;

  void _buffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering) {
      _stallTimer = Timer(const Duration(milliseconds: 500), () {
        if (_closed || !player.state.buffering) return;
        _stalled = true;
        _notify();
      });
    } else if (_stalled) {
      _stalled = false;
      _notify();
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _accessChanged() {
    if (_closed) return;
    if (store.profileEpoch != _epoch || store.locked) {
      _preloader.clear();
      unawaited(_dropStandby());
      _playIntent = false;
      _resumeIntent = false;
      endBoost();
      unawaited(player.pause());
    }
    if (store.profileEpoch != _epoch ||
        store.locked ||
        !store.allowsSource(detail.drama.source)) {
      danmaku.setPlan(null);
    }
  }

  void _syncBlockedWords() {
    if (_closed) return;
    danmaku.setBlockedWords(store.playbackPreferences.danmakuWords);
  }

  void _sync() {
    _syncDanmaku();
    _syncPreload();
  }

  void _syncDanmaku() {
    if (_closed) return;
    final state = player.state;
    danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          ready &&
          _openedIndex == _index &&
          _usable &&
          !store.locked &&
          store.allowsSource(detail.drama.source),
    );
  }

  void _syncPreload() {
    if (_closed || _standbyCleaning) return;
    if (!_foreground ||
        _lifecycleDormant ||
        _plan?.local == true ||
        !ready ||
        _openedIndex != _index ||
        !_usable ||
        !_engaged ||
        store.locked ||
        !hasNext) {
      _preloader.clear();
      return;
    }
    final state = player.state;
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    final ahead = state.buffer.inMilliseconds - position;
    if (_standby != null) {
      if (_standbyOpen &&
          DateTime.now().difference(_standbyAt) > const Duration(minutes: 8)) {
        unawaited(_dropStandby());
      }
      if (_standbyIndex >= 0 ||
          duration <= 0 ||
          duration - position > 45000 ||
          ahead < 3000) {
        return;
      }
    } else {
      if (!state.playing || state.buffering || !_playIntent) {
        _preloader.pause();
        return;
      }
      if (duration <= 0 ||
          position < 2000 ||
          (position < duration ~/ 2 && duration - position > 45000) ||
          ahead < 5000) {
        return;
      }
    }
    _preloader.prepare(
      detail.drama,
      detail.episodes[_index + 1],
      quality: _quality,
      online: _online,
    );
  }

  void _playerError(String error) {
    if (_closed || !_acceptErrors || error.trim().isEmpty) return;
    final upstream503 =
        _plan?.local != true && RegExp(r'\b503\b').hasMatch(error);
    DiaryService.add(
      '[Play] ${upstream503 ? '上游 HTTP 503' : '播放器报错'}：${_diagnostic(error)}',
    );
    _queueRecovery(upstream503 ? 'upstream_503' : 'player_error');
  }

  void _completed(bool completed) {
    if (!completed || _loading || _closed || !_acceptErrors || _error != null) {
      return;
    }
    final duration = player.state.duration;
    final position = player.state.position;
    if (duration <= Duration.zero
        ? position <= Duration.zero
        : position < duration - const Duration(seconds: 2)) {
      _queueRecovery('early_completion');
    } else if (_foreground && hasNext && !_sleepAtEpisodeEnd) {
      unawaited(play(_index + 1));
    } else if (_foreground &&
        !_sleepAtEpisodeEnd &&
        detail.nextSeason != null) {
      unawaited(_playNextSeason());
    } else {
      final sleeping = _sleepAtEpisodeEnd;
      if (sleeping) _clearSleep();
      _stop();
      if (sleeping) _notify();
    }
  }

  void _stop() {
    _playIntent = false;
    _resumeIntent = false;
    endBoost();
    unawaited(player.pause());
    unawaited(saveProgress());
  }

  void syncSeasons(List<DramaSeason> seasons) {
    if (_closed ||
        seasons.isEmpty ||
        identical(seasons, detail.seasons) ||
        !seasons.any((season) => season.drama.id == detail.drama.id)) {
      return;
    }
    detail = DramaDetail(
      detail.drama,
      detail.episodes,
      warning: detail.warning,
      seasons: seasons,
    );
  }

  Future<void> _playNextSeason() async {
    final season = detail.nextSeason;
    if (_advancingSeason || season == null || !_usable) return;
    _advancingSeason = true;
    final ticket = _generation;
    DiaryService.add('[Play] 本季播完，切换到${season.label}');
    await _dropStandby();
    _preloader.clear();
    try {
      await saveProgress();
      final next = await repository.detail(season.drama);
      if (!_current(ticket) || !_foreground) return;
      if (next.episodes.isEmpty) throw AppFailure('下一季暂时没有可播放的分集');
      detail = DramaDetail(
        repository.catalogUpdates.current(season.drama).merge(next.drama),
        next.episodes,
        warning: next.warning,
        seasons: detail.seasons,
      );
      _openedIndex = -1;
      _index = 0;
      _online = false;
      _notify();
      await play(0);
    } catch (error) {
      DiaryService.add('[Play] 切换下一季失败：${_diagnostic(error)}');
      if (_current(ticket)) _stop();
      _notify();
    } finally {
      _advancingSeason = false;
    }
  }

  void _clearSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    _sleepMinutes = 0;
    _sleepAtEpisodeEnd = false;
  }

  void setSleepTimer({int minutes = 0, bool episodeEnd = false}) {
    if (_closed) return;
    _clearSleep();
    if (episodeEnd) {
      _sleepAtEpisodeEnd = true;
    } else if (minutes > 0) {
      final after = Duration(minutes: minutes);
      _sleepMinutes = minutes;
      _sleepAt = DateTime.now().add(after);
      _sleepTimer = Timer(after, () {
        _clearSleep();
        if (!_closed) _stop();
        _notify();
      });
    }
    _notify();
  }

  void _queueRecovery(String reason) {
    if (_closed || !_acceptErrors || _error != null) return;
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) return;
    final ticket = _generation;
    final position = player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_current(ticket) || !_foreground || !_acceptErrors) return;
      _pendingError = false;
      final state = player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover(reason));
    });
  }

  /// 取流探活：dead 必须是明确的 listener 退出/connection refused；
  /// timeout 等恢复窗口内的瞬时错误只记为 unknown，不销毁仍可能可用的旧服务。
  Future<_StreamProbe> _probeStream() async {
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 300),
      Duration(milliseconds: 500),
      Duration(milliseconds: 700),
    ];
    for (var attempt = 0; attempt < retryDelays.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(retryDelays[attempt]);
      }
      try {
        final status = await repository.playbackStatus().timeout(
          const Duration(milliseconds: 1200),
        );
        if (!_closed) _streamEpoch = status.epoch;
        if (status.alive || status.state == 'alive') {
          return _StreamProbe.alive;
        }
        if (status.state == 'dead') {
          // 明确 connection refused / Serve 已退出，不需要再等待。
          DiaryService.add('[Play] 本机取流确认失效：${status.detail}');
          return _StreamProbe.dead;
        }
        DiaryService.add('[Play] 本机取流状态待确认 第${attempt + 1}次：${status.detail}');
      } catch (error) {
        DiaryService.add(
          '[Play] 取流探活异常 第${attempt + 1}次：${_diagnostic(error)}',
        );
      }
    }
    // 不确定状态不等于 dead；保留原播放器路径，后续播放错误再触发恢复。
    return _StreamProbe.unknown;
  }

  Future<void> _recover(String reason) async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = currentPosition;
    if (!current.local) {
      // 本机取流监听失效时，换线路只会继续指向同一个死端口。
      final probe = await _probeStream();
      if (_closed || !_usable || !identical(_plan, current)) return;
      final stale = current.streamEpoch != _streamEpoch;
      if (probe == _StreamProbe.dead || stale) {
        DiaryService.add(
          '[Play] 本机取流失效，重建播放器 探活=${probe.name} '
          '代次=${current.streamEpoch}/$_streamEpoch 原因=$reason',
        );
        _acceptErrors = true;
        await _rebuildAndResume(position, _foreground && _playIntent);
        return;
      }
    }
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current, preferRefresh: reason == 'upstream_503');
    DiaryService.add(
      '[Play] 自动恢复 原因=$reason 处理=${action.name} 线路=${current.routeIndex + 1}/${current.routeCount}',
    );
    if (action != PlaybackRecoveryAction.stop) {
      await play(_index, position: position, recovery: action);
      return;
    }
    _resumePosition = position;
    final ticket = _generation;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        try {
          await saveProgress();
          _openedIndex = -1;
          await player.stop();
        } finally {
          await _release(current.session);
        }
      });
    } catch (_) {}
    if (!_current(ticket)) return;
    _loading = false;
    _localFailure = current.local;
    _loginRequired = false;
    final symptom = switch (reason) {
      'position_stalled_20s' => '画面长时间没有进度',
      'early_completion' => '视频提前结束',
      'open_exception' => '视频打开失败',
      _ => '播放器报错',
    };
    _error = current.local
        ? '$symptom，本地视频没能播放。可重试或重新下载，也可以改为在线播放。'
        : '$symptom，自动恢复未成功。可重试、换一集或选择其他清晰度。';
    _notify();
  }

  void _restoreErrorHandling() {
    if (!_closed && _usable && _error == null) {
      _acceptErrors = true;
    }
  }

  Future<void> _release(String session) async {
    if (session.isEmpty) return;
    await repository.release(session).catchError((Object _) {});
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _configure(Player target, PlaybackPlan plan) async {
    final platform = target.platform;
    if (platform is! NativePlayer) return;
    final hwdec = switch (store.playbackPreferences.televisionDecoder) {
      TelevisionDecoder.software => 'no',
      TelevisionDecoder.hardware when Platform.isAndroid => 'mediacodec-copy',
      TelevisionDecoder.hardware when Platform.isIOS || Platform.isMacOS =>
        'videotoolbox-copy',
      _ when Platform.isWindows => 'd3d11va-copy',
      _ when Platform.isAndroid => 'auto-safe',
      _ when Platform.isMacOS => 'auto-safe',
      _ => null,
    };
    if (hwdec != null) await platform.setProperty('hwdec', hwdec);
    if (Platform.isAndroid) {
      await platform.setProperty('hwdec-codecs', 'all');
      await platform.setProperty('vd-lavc-skiploopfilter', 'nonkey');
      await platform.setProperty('vd-lavc-threads', '4');
      await platform.setProperty('vd-lavc-fast', 'yes');
      await platform.setProperty('video-sync', 'audio');
      await platform.setProperty('framedrop', 'vo');
    }
    await platform.setProperty(
      'demuxer-lavf-o',
      [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        plan.local
            ? 'protocol_whitelist=[file,crypto,data]'
            : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (plan.decryptionKey.isNotEmpty)
          'decryption_key=${plan.decryptionKey}',
      ].join(','),
    );
    await platform.setProperty('network-timeout', '20');
  }

  Future<void> play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recovery,
    bool playWhenReady = true,
  }) async {
    if (!_usable || index < 0 || index >= detail.episodes.length) return;
    endBoost();
    _staleAudio = false;
    _cancelResumeWatchdog();
    if (index != _index) _online = false;
    if (recovery == null &&
        position == 0 &&
        _standbyOpen &&
        _standbyIndex == index &&
        !_online &&
        (_standbyPlan == null || _standbyPlan!.streamEpoch == _streamEpoch)) {
      return _swap(index, playWhenReady);
    }
    await _dropStandby();
    final warmed = recovery == null
        ? _preloader.take(
            detail.drama,
            detail.episodes[index],
            quality: _quality,
            online: _online,
          )
        : null;
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _seekWatchdog?.cancel();
    danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recovery == null) {
      _restoreToken++;
      _recovery.reset();
      _playIntent = playWhenReady;
      _resumeIntent = playWhenReady;
    }
    _resumePosition = position;
    _openedAt = position;
    _index = index;
    _loading = true;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loadingMessage = switch (recovery) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      _ => '正在准备播放',
    };
    _notify();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    var installed = false;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        await saveProgress();
        if (!_current(ticket)) return;
        _openedIndex = -1;
        await player.stop();
        final previous = _plan;
        _plan = null;
        if (recovery == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await _release(previous.session);
        }
      });
      if (!_current(ticket)) return;
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              detail.drama,
              detail.episodes[index],
              quality: _quality,
              online: _online,
            );
      if (prepared == null) return;
      final plan = prepared;
      await _serialize(() async {
        if (!_current(ticket)) {
          await _release(plan.session);
          return;
        }
        if (plan.url.isEmpty) throw AppFailure('站源未返回播放地址，请重试');
        await _configure(player, plan);
        await _limitCache(player, !_engaged);
        await _selectAudio(player, true);
        _plan = plan;
        _streamEpoch = plan.streamEpoch;
        installed = true;
        _acceptErrors = true;
        await player
            .open(
              Media(
                plan.url,
                httpHeaders: plan.headers,
                start: position > 0
                    ? Duration(milliseconds: (position * 1000).round())
                    : null,
              ),
              play: _foreground && _playIntent,
            )
            .timeout(const Duration(seconds: 15));
        if (!_current(ticket)) return;
        _openedIndex = index;
        _health.reset();
        await _setRate(_rate);
        if (!_current(ticket)) return;
        _loading = false;
        _notify();
        danmaku.setPlan(plan);
        _syncDanmaku();
      });
    } catch (error) {
      if (_current(ticket)) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _loading = false;
          _notify();
          _queueRecovery('open_exception');
        } else {
          if (prepared != null) await _release(prepared.session);
          if (_current(ticket)) {
            DiaryService.add('[Play] 无法播放：${_diagnostic(error)}');
            _loading = false;
            _localFailure = error is AppFailure && error.code == 'local_media';
            _loginRequired =
                error is AppFailure && error.code == 'source_login';
            _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
            _notify();
          }
        }
      } else if (prepared != null && !installed) {
        await _release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) await _release(warmed.session);
      if (retained != null) await _release(retained!.session);
    }
  }

  Future<void> _swap(int index, bool playWhenReady) async {
    final plan = _standbyPlan!;
    final next = _standby!;
    final previous = _player;
    final previousPlan = _plan;
    final volume = previous.state.volume;
    unawaited(saveProgress());
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _seekWatchdog?.cancel();
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    _recovery.reset();
    _playIntent = playWhenReady;
    _resumePosition = 0;
    _openedAt = 0;
    _index = index;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loading = false;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    _player = next;
    _standby = previous;
    _plan = plan;
    _streamEpoch = plan.streamEpoch;
    _bind();
    _openedIndex = index;
    _acceptErrors = true;
    final stopping = previous.stop().catchError((Object _) {});
    if (previousPlan != null) unawaited(_release(previousPlan.session));
    danmaku.setPlan(plan);
    _notify();
    _syncDanmaku();
    try {
      await _limitCache(next, false);
      await next.setVolume(volume);
      await _setRate(_rate);
      await stopping;
      await _selectAudio(next, true);
      if (_current(ticket) && _foreground && _playIntent) await next.play();
    } catch (_) {
      if (_current(ticket)) _queueRecovery('open_exception');
    }
  }

  void _prime() {
    final standby = _standby;
    final next = _index + 1;
    if (_closed ||
        !_foreground ||
        _lifecycleDormant ||
        _standbyCleaning ||
        standby == null ||
        _standbyIndex >= 0 ||
        !_preloader.ready ||
        next >= detail.episodes.length) {
      return;
    }
    _standbyIndex = next;
    final plan = _preloader.take(
      detail.drama,
      detail.episodes[next],
      quality: _quality,
      online: _online,
    );
    if (plan == null) {
      _standbyIndex = -1;
      return;
    }
    _standbyPlan = plan;
    final opening = _open(standby, plan);
    _standbyOpening = opening;
    unawaited(
      opening.whenComplete(() {
        if (identical(_standbyOpening, opening)) _standbyOpening = null;
      }),
    );
  }

  Future<void> _open(Player standby, PlaybackPlan plan) async {
    try {
      await _configure(standby, plan);
      await _limitCache(standby, true);
      await _selectAudio(standby, false);
      await standby.open(
        Media(plan.url, httpHeaders: plan.headers),
        play: false,
      );
    } catch (_) {
      if (identical(_standbyPlan, plan)) {
        unawaited(_dropStandby(waitForOpening: false));
      }
      return;
    }
    if (_closed || !identical(_standbyPlan, plan)) return;
    _standbyOpen = true;
    _standbyAt = DateTime.now();
    _notify();
  }

  Future<bool> _retireStandbyBeforeRelease(Player target) async {
    try {
      await target.dispose().timeout(const Duration(milliseconds: 1500));
      return true;
    } catch (_) {
      DiaryService.add('[Play] 待播播放器销毁超时，暂缓释放媒体 session');
      return false;
    } finally {
      _onRetired?.call(target);
    }
  }

  Future<void> _dropStandby({
    Player? target,
    bool retire = false,
    bool waitForOpening = true,
  }) {
    _cancelStandbyIdle();
    final plan = _standbyPlan;
    final standby = target ?? _standby;
    final opening = _standbyOpening;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    _standbyOpening = null;

    // Serialize open -> stop/dispose -> release. The Go session must remain
    // alive until media_kit can no longer read its local stream URL.
    final queued = _standbyCleanup.catchError((Object _) {}).then((_) async {
      var safeToRelease = true;
      if (standby != null) {
        if (waitForOpening && plan != null && opening != null) {
          try {
            await opening.timeout(const Duration(milliseconds: 1500));
          } catch (_) {
            safeToRelease = false;
          }
        }
        if (safeToRelease && plan != null) {
          try {
            await standby.stop().timeout(const Duration(milliseconds: 1500));
          } catch (_) {
            safeToRelease = false;
          }
        }
        if (!safeToRelease || retire) {
          if (!retire && identical(_standby, standby)) {
            _standby = _spawnStandby?.call();
          }
          safeToRelease = await _retireStandbyBeforeRelease(standby);
        }
      }
      // If even dispose timed out, leave the session for native idle expiry
      // rather than freeing it while the player may still be reading it.
      if (plan != null && safeToRelease) await _release(plan.session);
    });
    _standbyCleaning = true;
    late final Future<void> tracked;
    tracked = queued.whenComplete(() {
      if (identical(_standbyCleanup, tracked)) _standbyCleaning = false;
    });
    _standbyCleanup = tracked;
    return tracked;
  }

  Future<void> _limitCache(Player target, bool limited) async {
    final platform = target.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty(
      'demuxer-max-bytes',
      '${(limited ? 4 : 32) * 1024 * 1024}',
    );
  }

  Future<int?> networkSpeed() async {
    final platform = player.platform;
    if (_closed || local || platform is! NativePlayer) return null;
    if (_speedReading || _loading || !_foreground || !player.state.playing) {
      return _networkSpeed;
    }
    final resumeAt = _speedResumeAt;
    if (resumeAt != null) {
      final progressed =
          player.state.position > resumeAt + const Duration(milliseconds: 500);
      if (!progressed && DateTime.now().isBefore(_speedResumeDeadline!)) {
        return _networkSpeed;
      }
      _speedResumeAt = null;
      _speedResumeDeadline = null;
    }
    if (player.state.buffering) return _networkSpeed;
    _speedReading = true;
    try {
      final value = await platform.getProperty('cache-speed');
      final speed = double.tryParse(value)?.round();
      if (speed != null) _networkSpeed = speed;
      return _networkSpeed;
    } catch (_) {
      return _networkSpeed;
    } finally {
      _speedReading = false;
    }
  }

  Future<void> _selectAudio(Player target, bool enabled) async {
    final platform = target.platform;
    if (platform is! NativePlayer || !Platform.isIOS) return;
    await platform.setProperty('aid', enabled ? 'auto' : 'no');
  }

  void start(int index, {double position = 0}) {
    if (!_usable) return;
    final wasEngaged = _engaged;
    _engaged = true;
    if (index != _index ||
        (position - _openedAt).abs() > .5 ||
        _error != null) {
      unawaited(play(index, position: position));
      return;
    }
    _playIntent = true;
    if (!wasEngaged) unawaited(_limitCache(player, false));
    if (ready) unawaited(player.play());
  }

  Future<void> retry() =>
      play(_index, position: currentPosition, playWhenReady: true);

  Future<void> switchOnline() {
    _online = true;
    return retry();
  }

  Future<bool> next() async {
    if (!hasNext) return false;
    await play(_index + 1);
    return true;
  }

  Future<bool> previous() async {
    if (!hasPrevious) return false;
    await play(_index - 1);
    return true;
  }

  void togglePlayback() {
    if (!_usable || !ready) return;
    endBoost();
    _restoreToken++;
    _playIntent = !_playIntent;
    _resumeIntent = _playIntent;
    _health.reset();
    if (_playIntent) {
      _cancelStandbyIdle();
      final paused = _takePausedSeconds();
      if (paused >= 5) DiaryService.add('[Play] 恢复播放，已暂停 $paused 秒');
      if (!local && (paused >= 5 || _stalled || player.state.buffering)) {
        _armResumeWatchdog();
      }
      _holdNetworkSpeed();
    } else {
      _cancelResumeWatchdog();
      _pausedSince = DateTime.now();
      _scheduleStandbyIdle();
    }
    if (_playIntent && player.state.completed) {
      unawaited(play(_index));
      return;
    }
    if (_playIntent && _staleAudio) {
      _staleAudio = false;
      final position = player.state.position;
      if (player.state.duration > Duration.zero && position > Duration.zero) {
        unawaited(
          player
              .seek(position)
              .then(
                (_) =>
                    player.state.playing ? Future<void>.value() : player.play(),
              )
              .catchError((Object _) {}),
        );
      } else {
        unawaited(player.play());
      }
    } else if (_playIntent) {
      unawaited(player.play());
    } else {
      unawaited(player.pause());
    }
    if (!_playIntent) unawaited(saveProgress());
    _syncDanmaku();
  }

  int _takePausedSeconds() {
    final since = _pausedSince;
    _pausedSince = null;
    if (since == null) return 0;
    return DateTime.now().difference(since).inSeconds;
  }

  void _armResumeWatchdog() {
    _cancelResumeWatchdog();
    final position = player.state.position;
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      _resumeTimer = null;
      if (_closed || !_playIntent) return;
      if (player.state.position > position) return;
      DiaryService.add('[Play] 恢复后 5 秒没有进展，重新加载当前集');
      unawaited(_reviveCurrent());
    });
  }

  void _cancelResumeWatchdog() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  Future<void> _reviveCurrent() =>
      _reopen(Duration(milliseconds: (_resumePosition * 1000).round()));

  Future<void> _reopen(Duration target) async {
    if (_closed || _loading || _error != null || !_playIntent || !_foreground) {
      return;
    }
    final ticket = _generation;
    final position = target.inMilliseconds / 1000;
    final plan = _plan;
    if (plan == null || plan.local || plan.url.isEmpty) {
      if (!local && _current(ticket)) {
        await play(_index, position: position);
      }
      return;
    }
    try {
      _health.reset();
      _staleAudio = false;
      await player
          .open(
            Media(
              plan.url,
              httpHeaders: plan.headers,
              start: position > 0
                  ? Duration(milliseconds: (position * 1000).round())
                  : null,
            ),
            play: _foreground && _playIntent,
          )
          .timeout(const Duration(seconds: 15));
      if (!_current(ticket) || !identical(_plan, plan)) return;
      _openedIndex = _index;
    } catch (_) {
      if (_closed || !_current(ticket)) return;
      await play(_index, position: position);
    }
  }

  void _scheduleStandbyIdle() {
    _cancelStandbyIdle();
    if (_standby == null) return;
    _standbyIdleTimer = Timer(const Duration(minutes: 1), () {
      _standbyIdleTimer = null;
      if (_closed || _playIntent || _standbyIndex < 0) return;
      unawaited(_dropStandby());
    });
  }

  void _cancelStandbyIdle() {
    _standbyIdleTimer?.cancel();
    _standbyIdleTimer = null;
  }

  Future<bool> seekTo(Duration target) async {
    if (!_usable || !ready) return false;
    _cancelResumeWatchdog();
    final ticket = ++_seekSequence;
    final generation = _generation;
    danmaku.beginSeek();
    var succeeded = false;
    try {
      await player.seek(target);
      succeeded = true;
    } catch (error) {
      DiaryService.add('[Play] 跳转失败 目标=${target.inSeconds}s：$error');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        danmaku.endSeek(succeeded ? target : player.state.position);
      }
    }
    if (succeeded && ticket == _seekSequence) _watchSeek(target);
    return succeeded;
  }

  void _watchSeek(Duration target) {
    _seekWatchdog?.cancel();
    final ticket = _seekSequence;
    Duration? settled;
    _seekWatchdog = Timer(const Duration(milliseconds: 2500), () {
      if (!_seekWatchStillValid(ticket)) return;
      settled = player.state.position;
      _seekWatchdog = Timer(const Duration(milliseconds: 2500), () {
        _seekWatchdog = null;
        if (!_seekWatchStillValid(ticket)) return;
        final position = player.state.position;
        if ((position - target).abs() <= const Duration(seconds: 2)) return;
        if (position > settled! + const Duration(milliseconds: 800)) return;
        DiaryService.add(
          '[Play] 跳转未生效 目标=${target.inSeconds}s '
          '位置=${position.inSeconds}s，重新打开当前线路',
        );
        unawaited(_reopen(target));
      });
    });
  }

  bool _seekWatchStillValid(int ticket) =>
      !_closed &&
      ticket == _seekSequence &&
      _playIntent &&
      _foreground &&
      !_loading &&
      _error == null;

  Duration? seekBy(int seconds) {
    final duration = player.state.duration;
    if (!ready || duration <= Duration.zero) return null;
    final target = Duration(
      milliseconds: (player.state.position.inMilliseconds + seconds * 1000)
          .clamp(0, duration.inMilliseconds),
    );
    unawaited(seekTo(target));
    return target;
  }

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    return _rates.catchError((Object _) {});
  }

  void beginBoost() {
    if (!ready || _boostTimer != null || _boosting) return;
    _boostTimer = Timer(const Duration(milliseconds: 350), () {
      _boostTimer = null;
      if (_closed ||
          !ready ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      unawaited(_setRate(_rate));
      _notify();
    });
  }

  void holdBoost() {
    if (!_usable || _boosting) return;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = true;
    unawaited(_setRate(_rate));
    _notify();
  }

  void setBoostLocked(bool locked) {
    if (_boostLocked == locked) return;
    if (locked) {
      holdBoost();
      _boostLocked = true;
      _notify();
    } else {
      _boostLocked = false;
      endBoost();
      _notify();
    }
  }

  void setLocked(bool locked) {
    if (_locked == locked) return;
    _locked = locked;
    _notify();
  }

  bool endBoost() {
    if (_boostLocked) return false;
    final boosted = _boosting;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(_speed));
      _notify();
    }
    return boosted;
  }

  void setVolume(double value) {
    final volume = value.clamp(0.0, 100.0);
    if (volume > 0) {
      _unmutedVolume = volume;
      _volumeTimer?.cancel();
      _volumeTimer = Timer(const Duration(milliseconds: 500), _saveVolume);
    }
    _applyVolume(volume);
  }

  void _saveVolume() {
    _volumeTimer = null;
    unawaited(store.setPlayerVolume(_unmutedVolume).catchError((Object _) {}));
  }

  void _applyVolume(double volume) {
    if (!player.state.playing) _staleAudio = true;
    unawaited(player.setVolume(volume));
  }

  double changeVolume(double delta) {
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    setVolume(volume);
    return volume;
  }

  double toggleMute() {
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    _applyVolume(target);
    return target;
  }

  Future<void> _savePreferences(PlaybackPreferences preferences) async {
    if (!_usable) throw StateError('当前用户已变更');
    await store.setPlaybackPreferences(preferences);
    if (!_usable) throw StateError('当前用户已变更');
  }

  Future<void> setSpeed(double value) async {
    if (value == _speed) return;
    await _savePreferences(_preferences.copyWith(speed: value));
    _speed = value;
    _notify();
    if (!_boosting) await _setRate(value);
  }

  Future<void> setVideoFit(VideoFit value) async {
    if (value == _videoFit) return;
    final previous = _videoFit;
    _videoFit = value;
    _notify();
    try {
      await _savePreferences(_preferences);
    } catch (_) {
      if (_videoFit == value) {
        _videoFit = previous;
        _notify();
      }
      rethrow;
    }
  }

  Future<void> setQuality(int value) async {
    if (value == _quality) return;
    await _savePreferences(_preferences.copyWith(quality: value));
    _quality = value;
    _preloader.clear();
    _notify();
    if (_plan?.local == true) return;
    await play(
      _index,
      position: currentPosition,
      playWhenReady: _error != null || player.state.playing,
    );
  }

  Future<void> toggleDanmaku() async {
    if (!danmakuSupported) return;
    final enabled = !_danmakuEnabled;
    await _savePreferences(_preferences.copyWith(danmaku: enabled));
    _danmakuEnabled = enabled;
    danmaku.setEnabled(enabled);
    _syncDanmaku();
    _notify();
  }

  Future<void> setDanmakuScale(double value) async {
    final scale = value.clamp(danmakuScaleMin, danmakuScaleMax);
    await _savePreferences(_preferences.copyWith(danmakuScale: scale));
    _notify();
  }

  Future<void> setDanmakuColor(int value) async {
    await _savePreferences(_preferences.copyWith(danmakuColor: value));
    _notify();
  }

  Future<void> setDanmakuOpacity(double value) async {
    final opacity = value.clamp(.1, 1.0);
    await _savePreferences(_preferences.copyWith(danmakuOpacity: opacity));
    _notify();
  }

  Future<void> setDanmakuBold(bool value) async {
    await _savePreferences(_preferences.copyWith(danmakuBold: value));
    _notify();
  }

  Future<void> setDanmakuStroke(double value) async {
    final stroke = value.clamp(danmakuStrokeMin, danmakuStrokeMax);
    await _savePreferences(_preferences.copyWith(danmakuStroke: stroke));
    _notify();
  }

  Future<void> setDanmakuShadow(double value) async {
    final shadow = value.clamp(danmakuShadowMin, danmakuShadowMax);
    await _savePreferences(_preferences.copyWith(danmakuShadow: shadow));
    _notify();
  }

  Future<void> setDanmakuSpeed(double value) async {
    final speed = value.clamp(danmakuSpeedMin, danmakuSpeedMax);
    await _savePreferences(_preferences.copyWith(danmakuSpeed: speed));
    _notify();
  }

  Future<void> setDanmakuCoverage(DanmakuCoverage value) async {
    await _savePreferences(_preferences.copyWith(danmakuCoverage: value));
    _notify();
  }

  Future<void> setDanmakuWords(List<String> words) async {
    final normalized = normalizeDanmakuWords(words);
    await _savePreferences(_preferences.copyWith(danmakuWords: normalized));
    _notify();
  }

  void onLifecycleEvent(AppLifecycleState state, {String source = 'ui'}) {
    if (_closed || _lastLifecycle == state) return;
    _lastLifecycle = state;
    switch (state) {
      case AppLifecycleState.resumed:
        _onResumed(source);
      case AppLifecycleState.inactive:
        _onInactive(source);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _onBackground(state, source);
    }
  }

  void setPictureInPicture(bool active) {
    if (_closed || _pipActive == active) return;
    _pipActive = active;
    DiaryService.add('[Play] 画中画 ${active ? '开启' : '关闭'}');
    if (active) {
      if (!_foreground) {
        _foreground = true;
        _playIntent = _resumeIntent;
        _health.reset();
        _sync();
        if (_resumeIntent && ready) {
          unawaited(_restoreAfterLifecycle(++_restoreToken));
        }
      }
      _notify();
      return;
    }
    final state = _lastLifecycle;
    if (state != null && state != AppLifecycleState.resumed) {
      _onBackground(state, 'pip_exit');
    }
  }

  void _snapshotForBackground() {
    final position = player.state.position;
    if (_openedIndex == _index && position > Duration.zero) {
      _resumePosition = position.inMilliseconds / 1000;
    }
    _resumeIntent = _playIntent;
  }

  /// 进入后台时让待机播放器彻底失效。
  ///
  /// 系统可能在挂起期间回收本机取流监听，待机预开的地址随之失效；
  /// 若继续保留，回前台后切下一集会 swap 到死地址而卡住。
  /// 这里释放旧实例与预开计划，回前台后由新的实例重新预加载。
  void _invalidateStandbyForBackground() {
    final standby = _standby;
    if (standby == null && _standbyPlan == null) return;
    _standby = null;
    unawaited(_dropStandby(target: standby, retire: true));
    _standby = _spawnStandby?.call();
  }

  void _onInactive(String source) {
    if (_foreground) _snapshotForBackground();
    _lifecycleDormant = true;
    // Keep the current player alive for iOS lock-screen audio restoration,
    // but cancel next-episode preparation and retire any opened standby plan.
    _preloader.clear();
    unawaited(_dropStandby());
    DiaryService.add(
      '[Play] 生命周期 inactive 来源=$source 集=${_index + 1} '
      '位置=${_resumePosition.toStringAsFixed(1)} 续播=$_resumeIntent',
    );
    // iOS 锁屏/控制中心可能只发送 inactive→resumed。
    // 此阶段不主动 pause，保留最后一帧与原始播放意图。
    _notify();
  }

  void _onBackground(AppLifecycleState state, String source) {
    if (_pipActive) {
      DiaryService.add('[Play] 生命周期 ${state.name} 但画中画活跃，保持播放');
      return;
    }
    if (!_foreground) return;
    _snapshotForBackground();
    _invalidateStandbyForBackground();
    _foreground = false;
    _playIntent = false;
    _restoreToken++;
    endBoost();
    _health.reset();
    _sync();
    DiaryService.add(
      '[Play] 进入后台 来源=${state.name}:$source 集=${_index + 1} '
      '位置=${_resumePosition.toStringAsFixed(1)} 续播=$_resumeIntent',
    );
    unawaited(player.pause());
    unawaited(saveProgress());
    _notify();
  }

  void _onResumed(String source) {
    final wasForeground = _foreground;
    final dormant = _lifecycleDormant;
    _lifecycleDormant = false;
    DiaryService.add(
      '[Play] 回到前台 来源=$source 原前台=$wasForeground '
      '仅inactive=$dormant 续播=$_resumeIntent',
    );
    if (!wasForeground) {
      // 先恢复播放意图再通知 UI，避免解锁后先闪出暂停图标。
      _foreground = true;
      _playIntent = _resumeIntent;
      _health.reset();
      _sync();
      if (_pendingError) {
        _queueRecovery('foreground_pending_error');
      } else if (_resumeIntent && ready) {
        unawaited(_restoreAfterLifecycle(++_restoreToken));
      }
      _notify();
      return;
    }
    if (dormant && _resumeIntent && ready && !_loading) {
      // 仅 inactive→resumed 的锁屏恢复也要重新激活音频会话并确认位置推进。
      unawaited(_restoreAfterLifecycle(++_restoreToken));
    } else if (_pendingError && _resumeIntent) {
      _queueRecovery('foreground_pending_error');
    }
    _notify();
  }

  bool _lifecycleRestoreValid(int token, int generation) =>
      !_closed &&
      _foreground &&
      _resumeIntent &&
      token == _restoreToken &&
      generation == _generation;

  bool _restorable(int token) =>
      !_closed && _foreground && token == _restoreToken;

  Future<void> _restoreAfterLifecycle(int token) async {
    final generation = _generation;
    final index = _index;
    final before = player.state.position;
    if (Platform.isIOS) {
      final activated = await AppDevice.activateAudio();
      if (!activated) {
        DiaryService.add('[Play] iOS 音频会话激活失败，继续尝试恢复播放');
      }
    }
    if (!_lifecycleRestoreValid(token, generation) || index != _index) return;

    final saved = Duration(milliseconds: (_resumePosition * 1000).round());
    final current = player.state.position;
    if (saved > Duration.zero &&
        (current - saved).inMilliseconds.abs() > 2000) {
      try {
        await player.seek(saved);
      } catch (_) {}
    }
    if (!_lifecycleRestoreValid(token, generation)) return;

    // iOS 挂起期间可能回收本机 HTTP listener。必须在旧播放器 play() 前
    // 探活，否则旧缓冲区可能让画面短暂推进，随后才发现 listener 已失效并闪屏重建。
    final plan = _plan;
    if (_isIOS && plan != null && !plan.local) {
      final probe = await _probeStream();
      if (!_lifecycleRestoreValid(token, generation) || index != _index) return;
      final epochChanged =
          probe == _StreamProbe.alive && plan.streamEpoch != _streamEpoch;
      if (probe == _StreamProbe.dead || epochChanged) {
        final live = currentPosition;
        final resumeAt = live > _resumePosition ? live : _resumePosition;
        DiaryService.add(
          '[Play] 回前台后本机取流失效，直接重建播放器 探活=${probe.name} '
          '代次=${plan.streamEpoch}/$_streamEpoch',
        );
        _resumePosition = resumeAt;
        await _rebuildAndResume(resumeAt, true, token: token);
        return;
      }
      // unknown 不等于 dead：网络探活不确定时，保留旧播放器原地恢复路径。
    }

    _playIntent = true;
    _sync();
    _notify();
    Object? failure;
    try {
      await player.play();
    } catch (error) {
      failure = error;
      DiaryService.add('[Play] 前台恢复 play 失败：${_diagnostic(error)}');
    }
    if (!_lifecycleRestoreValid(token, generation) || index != _index) return;

    if (failure == null) {
      for (var attempt = 0; attempt < 4; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!_lifecycleRestoreValid(token, generation) || index != _index) {
          return;
        }
        final state = player.state;
        if (state.playing &&
            state.position > before + const Duration(milliseconds: 250)) {
          DiaryService.add('[Play] 前台原地恢复成功 位置=${state.position}');
          _resumePosition = state.position.inMilliseconds / 1000;
          _health.reset();
          _notify();
          return;
        }
        if (state.buffering) continue;
        if (!state.playing) {
          try {
            await player.play();
          } catch (_) {
            break;
          }
        }
      }
    }
    if (!_lifecycleRestoreValid(token, generation) || index != _index) return;
    final live = currentPosition;
    final resumeAt = live > _resumePosition ? live : _resumePosition;
    DiaryService.add('[Play] 前台原地恢复失败，重建播放器 位置=${resumeAt.toStringAsFixed(1)}');
    await _rebuildAndResume(resumeAt, true, token: token);
  }

  /// 等待播放位置真的推进：缓冲中不算成功，最多等 [windows] 个窗口。
  Future<bool> _confirmProgress(
    Duration before, {
    int windows = 2,
    bool Function()? alive,
  }) async {
    for (var attempt = 0; attempt < windows; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (_closed || !_foreground || _loading) return false;
      if (alive != null && !alive()) return false;
      final state = player.state;
      if (state.playing &&
          state.position > before + const Duration(milliseconds: 300)) {
        return true;
      }
      // open 刚返回时 mpv 可能短暂处于未播放且未缓冲的过渡态，
      // 一次采样不能判定失败，继续等到窗口用完。
    }
    return false;
  }

  Future<void> _retire(Player target) async {
    try {
      await target.dispose().timeout(const Duration(milliseconds: 1500));
    } catch (_) {
      DiaryService.add('[Play] 旧播放器释放超时，继续恢复');
    } finally {
      _onRetired?.call(target);
    }
  }

  /// 切出/锁屏后回前台原地恢复失败：底层实例已被系统回收，只重开同一
  /// 实例会一直卡住。这里重建 Player 与渲染上下文，再按原位置重新解析打开。
  Future<void> _rebuildAndResume(
    double position,
    bool playWhenReady, {
    int? token,
  }) async {
    if (_rebuilding) {
      // 重建期间又来了恢复请求：记下最新位置与意图，完成后补跑一次。
      _rebuildQueued = true;
      _queuedPosition = position;
      _queuedPlay = playWhenReady;
      _queuedToken = token;
      return;
    }
    if (token != null && !_restorable(token)) return;
    final spawn = _respawn;
    if (spawn == null) {
      await play(_index, position: position, playWhenReady: playWhenReady);
      return;
    }
    final watch = Stopwatch()..start();
    _rebuilding = true;
    final ticket = ++_generation;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        final previous = _player;
        final volume = previous.state.volume;
        final plan = _plan;
        final standbyPlan = _standbyPlan;
        final standby = _standby;
        _standbyPlan = null;
        _standbyIndex = -1;
        _standbyOpen = false;
        _preloader.clear();
        _seekSequence++;
        _acceptErrors = false;
        _pendingError = false;
        _errorTimer?.cancel();
        _plan = null;
        _openedIndex = -1;
        danmaku.setPlan(null);
        final stopped = await previous
            .stop()
            .timeout(const Duration(milliseconds: 1500))
            .then((_) => true, onError: (Object _) => false);
        await _release(plan?.session ?? '');
        if (standbyPlan != null) await _release(standbyPlan.session);
        if (standby != null) {
          unawaited(standby.stop().catchError((Object _) {}));
        }
        _player = spawn();
        _bind();
        // 旧实例释放完成前不打开新媒体，避免音频与渲染资源交叠。
        if (stopped) {
          await _retire(previous);
        } else {
          // stop 挂起时异步释放，避免每轮重建都滞留一个旧实例。
          unawaited(_retire(previous));
        }
        await _player.setVolume(volume);
        await _setRate(_speed);
      });
      if (_closed || !_foreground || !_current(ticket)) return;
      if (token != null && !_restorable(token)) {
        // 重建期间用户已暂停：只恢复画面，不自动播放。
        if (_foreground && !_resumeIntent) {
          await play(_index, position: position, playWhenReady: false);
        }
        return;
      }
      await play(_index, position: position, playWhenReady: playWhenReady);
      if (!playWhenReady) return;
      // play() 内部会自增 generation，必须用新 ticket 判断有效性。
      final liveTicket = _generation;
      if (_closed || !_foreground || !_current(liveTicket)) return;
      final baseline = Duration(milliseconds: (position * 1000).round());
      final playing = await _confirmProgress(
        baseline,
        alive: () => _current(liveTicket),
      );
      if (_closed || !_foreground || !_current(liveTicket)) return;
      if (playing) {
        DiaryService.add(
          '[Play] 重建恢复成功 耗时=${watch.elapsedMilliseconds}ms '
          '位置=${currentPosition.toStringAsFixed(1)}',
        );
        return;
      }
      DiaryService.add(
        '[Play] 重建后仍未播放 耗时=${watch.elapsedMilliseconds}ms '
        '位置=${currentPosition.toStringAsFixed(1)}',
      );
      _queueRecovery('rebuild_no_progress');
    } finally {
      _rebuilding = false;
      if (_rebuildQueued) {
        _rebuildQueued = false;
        final queuedPosition = _queuedPosition;
        final queuedPlay = _queuedPlay;
        final queuedToken = _queuedToken;
        if (!_closed &&
            _foreground &&
            (queuedToken == null || _restorable(queuedToken))) {
          unawaited(
            _rebuildAndResume(queuedPosition, queuedPlay, token: queuedToken),
          );
        }
      }
      _restoreErrorHandling();
    }
  }

  void setForeground(bool visible) {
    if (_closed || _foreground == visible) return;
    DiaryService.add(visible ? '[Play] 应用回到前台' : '[Play] 应用不可见，暂停播放');
    _foreground = visible;
    _health.reset();
    _sync();
    if (!visible) {
      endBoost();
      _playIntent = false;
      _pausedSince = DateTime.now();
      _cancelResumeWatchdog();
      _cancelStandbyIdle();
      unawaited(_dropStandby());
      _preloader.clear();
      unawaited(player.pause());
      unawaited(saveProgress());
    } else {
      _holdNetworkSpeed();
      if (_pendingError) _queueRecovery('foreground_pending_error');
    }
  }

  Future<void> saveProgress({bool quiet = false}) async {
    if (!_engaged || _openedIndex < 0 || store.profileEpoch != _epoch) return;
    final position = player.state.position.inMilliseconds / 1000;
    final duration = player.state.duration.inMilliseconds / 1000;
    if (position < .1) return;
    final key = '${detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == key &&
        _saveWarning == null &&
        (quiet || !_savedQuietly)) {
      return;
    }
    final entry = WatchEntry(
      drama: repository.catalogUpdates.current(detail.drama),
      episode: detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await store.saveWatch(entry, quiet: quiet);
      _savedProgressKey = key;
      _savedQuietly = quiet;
      if (_saveWarning != null) {
        _saveWarning = null;
        _notify();
      }
    } catch (_) {
      if (_saveWarning == null) {
        _saveWarning = '观看进度尚未保存，请检查存储空间后重试。';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    unawaited(saveProgress());
    _closed = true;
    _generation++;
    store.removeListener(_accessChanged);
    store.removeListener(_syncBlockedWords);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _boostTimer?.cancel();
    _stallTimer?.cancel();
    _seekWatchdog?.cancel();
    _volumeTimer?.cancel();
    _sleepTimer?.cancel();
    _standbyIdleTimer?.cancel();
    _resumeTimer?.cancel();
    if (_volumeTimer != null) _saveVolume();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    danmaku.dispose();
    _preloader.dispose();
    final session = _plan?.session ?? '';
    final standby = _standby;
    _standby = null;
    final standbyCleanup = _dropStandby(target: standby, retire: true);
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _rates.catchError((Object _) {});
        await player.dispose();
        await standbyCleanup;
        await _release(session);
      }),
    );
    super.dispose();
  }
}
