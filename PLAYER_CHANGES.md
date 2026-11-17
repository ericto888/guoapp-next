# 播放器定制记录（相对上游需保持不变）

本文件记录本项目（guoapp-next）相对上游 `Xanerix/guoapp` 的播放器相关改动。
上游更新时，以下文件与行为必须保留，不得被上游版本直接覆盖。

- 当前版本：`2.0.2+119`
- 相关提交：
  - `1e4cee0` feat: restore iOS background playback recovery from guoapp
  - `33d2016` feat(player): 横片播放改用 guoapp 横屏页，并补 iOS 切出/锁屏恢复失败后的播放器重建（2.0.0+116）
  - 2026-11-17 合并上游 `f5aac70`（17 个提交）后，手工把上游播放器锁接入本项目横屏信息流和竖屏播放页

## 零、冻结清单（拉取上游更新时不得改动）

以下文件是播放器定制的冻结文件，合并上游时必须保留本项目版本：

- `lib/playback_session.dart`
- `lib/playback_preferences.dart`
- `lib/app_device.dart`
- `lib/ui/player/` 下全部文件
- `ios/Runner/AppDelegate.swift`
- `ios/Runner/Info.plist`
- `test/playback_session_test.dart`

合并上游后的检查（`<合并前提交>` 取合并前 main 的提交）：

```powershell
git diff <合并前提交> -- lib/playback_session.dart lib/playback_preferences.dart `
  lib/app_device.dart lib/ui/player ios/Runner/AppDelegate.swift `
  ios/Runner/Info.plist test/playback_session_test.dart
```

上游也会改动这些文件（例如 2026-11-17 的播放器锁），输出不再一定为空；必须逐项确认本文档描述的行为仍在，不得整文件取上游版本。

`lib/ui/settings/settings_sections.dart` 允许跟随上游重排，但必须保留播放相关设置项（如「横屏底部进度线」），且不得恢复「横屏视频也使用竖屏样式」/ `portraitStyleForWide`。

最近一次验证：2026-11-17 合并上游 17 个提交（`f5aac70`），冻结文件逐项核对，`flutter analyze` 与 `flutter test` 通过；备份分支 `backup/pre-upstream-merge-20261117`。

## 一、iOS 切出 / 锁屏恢复播放

目标：切出 App、锁屏、回前台后能继续播放；系统回收底层实例时自动重建，不卡在旧实例上。

| 文件 | 改动 | 备注 |
|---|---|---|
| `ios/Runner/AppDelegate.swift` | 启动即设置 `AVAudioSession`（`.playback` / `.moviePlayback`）并激活；新增 `activateAudio` 方法通道（失败返回错误码） | 不静默吞异常 |
| `ios/Runner/Info.plist` | `UIBackgroundModes = audio` | 保持锁屏期间进程存活 |
| `lib/app_device.dart` | `AppDevice.activateAudio()`（iOS 限 3s 超时） | Dart 侧统一入口 |
| `lib/playback_session.dart` | `onLifecycleEvent()` / `setPictureInPicture()` / `_onInactive()` / `_onBackground()` / `_onResumed()`：inactive 只存快照不暂停，resumed 统一恢复；`_restoreAfterLifecycle()` 原地恢复失败后调用 `_rebuildAndResume()` | 不要退回各页面各自 `setForeground(playerVisible(state))` |
| `lib/playback_session.dart` | `_rebuildAndResume()`：串行停止旧实例 → 释放旧取流/待机会话 → 重建 Player → 重新解析并按原位置打开 → `_confirmProgress()` 确认推进 | 仅当回前台原地恢复失败时触发；构造参数 `respawn` / `onRetired` |
| `lib/playback_session.dart` | `_retire()`（释放旧实例并移除纹理映射）、`_restorable()`、`_confirmProgress()` | 不要删除 |
| `lib/ui/player/playback_handle.dart` | `_respawnPlayer()` 创建 Player + VideoController；`_retireVideo()` 移除映射；`video()` 缺失时就地补建 | 播放器实例可被替换，UI 必须按 `ValueKey(player)` 重建 |
| `lib/ui/player/{landscape_player_page,portrait_player_page,player_page,television_player_page}.dart` | 生命周期统一上报 `_session.onLifecycleEvent(state, source: ...)` | 不各自解释生命周期 |
| `lib/ui/player/playback_page.dart` | PiP 上报 `_session.setPictureInPicture(shown)` | 画中画期间不按后台处理 |

对应回归测试：`test/playback_session_test.dart` 中
`rebuilds the player when lifecycle resume cannot advance`。

## 二、横片播放改用 guoapp 横屏页

目标：横片统一使用 guoapp 的信息流布局横屏页；移除本项目的「横屏视频也使用竖屏样式」。

| 文件 | 改动 | 备注 |
|---|---|---|
| `lib/ui/player/landscape_player_page.dart` | 整体替换为 guoapp 版本：信息流布局（画面上方、简介/选集在下、底部进度条）、竖屏手持横片单击暂停、横屏真全屏、上下滑换集/跨季、亮度/音量手势 | 上游若改动此文件需逐项核对，不要整文件覆盖 |
| `lib/ui/player/playback_page.dart` | 横片始终进入 `LandscapePlayerPage`；新增 `playbackLayoutIsWide()`，切集首帧未知时沿用当前布局 | 不再有 `portraitStyleForWide` 分支与相关转屏调用 |
| `lib/ui/player/swipe_controls.dart` | 新增 `verticalRegion` 门控（`_GatedVerticalDrag`）：左右区域调亮度/音量，中间上下滑留给翻集 PageView；保留本项目 `episodes` 上下滑切集 | 上游版本缺少该门控时需补回 |
| `lib/playback_session.dart` | 新增 `nextSeason` getter（横屏页跨季滑动使用） | 上游可能已有同名实现，保留即可 |
| `lib/playback_preferences.dart` | 删除 `portraitStyleForWide`（默认值 / 字段 / copyWith / toJson / fromJson） | 旧存档中的该键会被忽略 |
| `lib/ui/settings/settings_sections.dart` | 删除「横屏视频也使用竖屏样式」开关 | 其余播放设置项保持不变 |
| `lib/ui/player/player_lock.dart` | 上游新增的播放器锁按钮与遮罩 | 本项目横屏、竖屏页已接入 |
| `lib/ui/player/landscape_player_page.dart` | 锁定后禁用轻点、长按、上下滑换集与返回，全屏时锁图标在左侧中间 | 不要覆盖本项目信息流布局 |
| `lib/ui/player/portrait_player_page.dart` | 锁定后禁用翻页、播放控制与返回，锁图标在右上角 | 保留本项目下一季占位页与底部手势保护 |

### 与上游组件的兼容适配

本项目共享组件比 guoapp 新，横屏页中做了等价转换，上游更新后仍需保留：

- 切集调用：`session.switchTo(index, reason: ...)` → `session.play(index)`
- 视频铺满：`PlayerVideo(fit: BoxFit.fill)` → `PlayerVideo(fit: VideoFit.stretch)`
- 弹幕：`DanmakuOverlay(aspectRatio:)` → `DanmakuOverlay(video: session.videoSize, fit: session.videoFit)`
- 季集数：`DramaSeason.episodes` → `season.drama.episodes`

## 三、上游同步注意事项

1. 先 `git fetch upstream`，用 `git diff upstream/main --stat` 检查上述文件是否被上游改动。
2. 对 `lib/playback_session.dart`、`lib/ui/player/*` 的冲突逐项保留本文档描述的行为，不要整文件取上游版本。
3. 保留 iOS 原生三项：`AppDelegate.swift` 音频会话、`Info.plist` 后台音频、`activateAudio` 通道。
4. 不要恢复 `portraitStyleForWide` / 「横屏视频也使用竖屏样式」。
5. 同步后执行：
   - `flutter analyze --no-pub`
   - `flutter test`
   - iOS 真机回归：切出、短/长锁屏、返回后切集、横屏/竖屏切换、转屏自动全屏、左右区域亮度/音量与中间上下滑换集
