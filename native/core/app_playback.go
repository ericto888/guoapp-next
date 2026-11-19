package core

import (
	"context"
	"strconv"
	"time"
)

func (engine *nativeEngine) nativeBeginPlayback(ctx context.Context, sequence int64) (context.Context, func(), error) {
	engine.playbackMu.Lock()
	defer engine.playbackMu.Unlock()
	if sequence <= engine.playbackSequence {
		return nil, nil, context.Canceled
	}
	if engine.playbackCancel != nil {
		engine.playbackCancel()
	}
	engine.playbackSequence = sequence
	playback, cancel := context.WithCancel(ctx)
	engine.playbackCancel = cancel
	finish := func() {
		cancel()
		engine.playbackMu.Lock()
		if engine.playbackSequence == sequence {
			engine.playbackCancel = nil
		}
		engine.playbackMu.Unlock()
	}
	return playback, finish, nil
}

func (engine *nativeEngine) nativeCancelPlayback(sequence int64) {
	engine.playbackMu.Lock()
	defer engine.playbackMu.Unlock()
	if sequence <= engine.playbackSequence {
		return
	}
	engine.playbackSequence = sequence
	if engine.playbackCancel != nil {
		engine.playbackCancel()
		engine.playbackCancel = nil
	}
}

// nativePlaybackStatus 返回监听状态、代次和探活细节。unknown 不等于 dead，
// 交由 Dart 端在恢复窗口内重试，避免把 iOS 网络栈恢复延迟误判成 listener 退出。
func (engine *nativeEngine) nativePlaybackStatus() (bool, int64, string, string) {
	// 探活不能只报告 dead：iOS 从后台恢复时，播放器仍持有旧地址。
	// 在同一把 streamMu 下先确保 listener 可用；若旧 listener 已失效，
	// 立即创建新 listener 并递增 epoch，让 Dart 丢弃旧会话并重新解析。
	stream, epoch, err := engine.nativeEnsureStreamLocked()
	if err != nil {
		detail := "listener_recreate_failed"
		if err.Error() != "" {
			detail += " error=" + err.Error()
		}
		return false, epoch, "dead", detail
	}
	state, detail, elapsed := stream.nativeProbe()
	if state != "alive" {
		stream.nativeLog(nativeStreamDiagnostic{}, "listener_probe", stream.address,
			"state="+state+" elapsed_ms="+strconv.FormatInt(elapsed.Milliseconds(), 10)+" "+detail, 0, "")
	}
	return state == "alive", epoch, state, detail
}

// nativeEnsureStreamLocked 串行确认并替换监听，避免并发解析请求同时重建。
// 只有明确 dead 才关闭旧 listener；unknown 时保留它，避免探活瞬时异常造成误杀。
func (engine *nativeEngine) nativeEnsureStreamLocked() (*nativeStreamServer, int64, error) {
	engine.streamMu.Lock()
	defer engine.streamMu.Unlock()

	engine.mu.Lock()
	current := engine.stream
	epoch := engine.streamEpoch
	engine.mu.Unlock()

	if current != nil {
		state, detail, elapsed := current.nativeProbe()
		if state == "unknown" {
			for attempt, delay := range []time.Duration{250 * time.Millisecond, 500 * time.Millisecond, 750 * time.Millisecond} {
				time.Sleep(delay)
				state, detail, elapsed = current.nativeProbe()
				if state != "unknown" {
					break
				}
				current.nativeLog(nativeStreamDiagnostic{}, "listener_probe", current.address,
					"attempt="+strconv.Itoa(attempt+2)+" state="+state+" elapsed_ms="+strconv.FormatInt(elapsed.Milliseconds(), 10)+" "+detail, 0, "")
			}
		}
		if state == "alive" || state == "unknown" {
			if state == "unknown" {
				current.nativeLog(nativeStreamDiagnostic{}, "listener_probe_deferred", current.address,
					"state=unknown "+detail, 0, "")
			}
			return current, epoch, nil
		}

		closed := current.nativeClose()
		engine.mu.Lock()
		if engine.stream == current {
			engine.stream = nil
			// 旧会话随监听一起作废，指向它们的播放记录必须清掉。
			engine.playbacks = map[string]nativePlaybackChoice{}
		}
		engine.mu.Unlock()

		stream, err := newNativeStreamServer(engine.downloader)
		if err != nil {
			return nil, epoch, err
		}
		engine.mu.Lock()
		engine.stream = stream
		engine.streamEpoch++
		epoch = engine.streamEpoch
		engine.mu.Unlock()
		stream.nativeLog(nativeStreamDiagnostic{}, "listener_recreated", stream.address,
			"reason="+detail+" closed_sessions="+strconv.Itoa(closed), 0, "")
		return stream, epoch, nil
	}

	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		return nil, epoch, err
	}
	engine.mu.Lock()
	engine.stream = stream
	engine.streamEpoch++
	epoch = engine.streamEpoch
	engine.mu.Unlock()
	stream.nativeLog(nativeStreamDiagnostic{}, "listener_created", stream.address, "epoch="+strconv.FormatInt(epoch, 10), 0, "")
	return stream, epoch, nil
}
