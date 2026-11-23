import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app_device.dart';
import 'window_on_top.dart';

typedef MiniWindowFrame = ({double left, double top, double extent});

const desktopMinimumSize = Size(960, 640);
const _miniExtent = 480.0;

double _clampRatio(double aspectRatio) =>
    aspectRatio.isFinite && aspectRatio > 0
    ? aspectRatio.clamp(1 / 2.39, 2.39)
    : 16 / 9;

Map<String, int> _ratio(double aspectRatio) {
  final ratio = _clampRatio(aspectRatio);
  return ratio >= 1
      ? {'width': (1000 * ratio).round(), 'height': 1000}
      : {'width': 1000, 'height': (1000 / ratio).round()};
}

Size _miniSize(double ratio, double extent) =>
    ratio >= 1 ? Size(extent, extent / ratio) : Size(extent * ratio, extent);

class MiniWindowController extends ChangeNotifier {
  static final instance = MiniWindowController._();

  bool _window = false;
  double? _windowRatio;
  ({Rect bounds, bool maximized, bool fullScreen})? _macRestore;

  bool get available =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;
  bool get shown => _window;
  bool get window => _window;

  Future<void> enter(double aspectRatio, {MiniWindowFrame? frame}) async {
    if (_window || !available) return;
    final ratio = _clampRatio(aspectRatio);
    _window = true;
    _windowRatio = ratio;
    notifyListeners();
    await WidgetsBinding.instance.endOfFrame;
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await AppDevice.channel.invokeMethod<void>('setMiniWindow', {
          'enabled': true,
          'aspect': ratio,
          if (frame != null) ...{
            'left': frame.left.round(),
            'top': frame.top.round(),
            'extent': frame.extent.round(),
          },
        });
      } else {
        await _enterMac(ratio, frame);
      }
    } catch (_) {
      _window = false;
      _windowRatio = null;
      notifyListeners();
    }
  }

  Future<void> _enterMac(double ratio, MiniWindowFrame? frame) async {
    final fullScreen = await windowManager.isFullScreen();
    if (fullScreen) {
      await windowManager.setFullScreen(false);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    final maximized = await windowManager.isMaximized();
    _macRestore = (
      bounds: await windowManager.getBounds(),
      maximized: maximized,
      fullScreen: fullScreen,
    );
    if (maximized) await windowManager.unmaximize();
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setMinimumSize(const Size(120, 120));
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setAspectRatio(ratio);
    final size = _miniSize(ratio, frame?.extent ?? _miniExtent);
    if (frame != null) {
      await windowManager.setBounds(
        Rect.fromLTWH(frame.left, frame.top, size.width, size.height),
      );
    } else {
      await windowManager.setSize(size);
      await windowManager.setAlignment(Alignment.bottomRight);
    }
  }

  void resize(double aspectRatio) {
    final ratio = _clampRatio(aspectRatio);
    if (!_window || ratio == _windowRatio) return;
    _windowRatio = ratio;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(
        AppDevice.channel
            .invokeMethod<void>('setMiniWindow', {
              'enabled': true,
              'aspect': ratio,
            })
            .catchError((Object _) {}),
      );
      return;
    }
    unawaited(() async {
      try {
        final size = await windowManager.getSize();
        await windowManager.setAspectRatio(ratio);
        await windowManager.setSize(
          _miniSize(ratio, math.max(size.width, size.height)),
        );
      } catch (_) {}
    }());
  }

  Future<MiniWindowFrame?> exit() async {
    if (!_window) return null;
    MiniWindowFrame? frame;
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final values = await AppDevice.channel.invokeMapMethod<String, dynamic>(
          'setMiniWindow',
          {'enabled': false},
        );
        if (values case {
          'left': final int left,
          'top': final int top,
          'extent': final int extent,
        }) {
          frame = (
            left: left.toDouble(),
            top: top.toDouble(),
            extent: extent.toDouble(),
          );
        }
      } else {
        frame = await _exitMac();
      }
    } catch (_) {}
    await applyWindowOnTop();
    await WidgetsBinding.instance.endOfFrame;
    _window = false;
    _windowRatio = null;
    notifyListeners();
    return frame;
  }

  Future<MiniWindowFrame> _exitMac() async {
    final bounds = await windowManager.getBounds();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setAspectRatio(0);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setMinimumSize(desktopMinimumSize);
    if (_macRestore case final restore?) {
      await windowManager.setBounds(restore.bounds);
      if (restore.maximized) await windowManager.maximize();
      if (restore.fullScreen) await windowManager.setFullScreen(true);
    }
    _macRestore = null;
    return (
      left: bounds.left,
      top: bounds.top,
      extent: math.max(bounds.width, bounds.height),
    );
  }
}
