package core

import "testing"

func TestNativeStreamProbeDistinguishesAliveAndClosedListener(t *testing.T) {
	stream, err := newNativeStreamServer(nil)
	if err != nil {
		t.Fatalf("create stream server: %v", err)
	}
	defer stream.nativeClose()

	state, detail, _ := stream.nativeProbe()
	if state != "alive" {
		t.Fatalf("expected live listener, got state=%q detail=%q", state, detail)
	}

	if err := stream.listener.Close(); err != nil {
		t.Fatalf("close listener: %v", err)
	}
	state, detail, _ = stream.nativeProbe()
	if state != "dead" {
		t.Fatalf("expected closed listener to be dead, got state=%q detail=%q", state, detail)
	}
}

func TestNativePlaybackStatusRecreatesDeadListener(t *testing.T) {
	engine := &nativeEngine{downloader: &Downloader{}}
	old, epoch, err := engine.nativeEnsureStreamLocked()
	if err != nil {
		t.Fatalf("create initial stream: %v", err)
	}
	if epoch != 1 {
		t.Fatalf("expected initial epoch 1, got %d", epoch)
	}
	if err := old.listener.Close(); err != nil {
		t.Fatalf("close initial listener: %v", err)
	}

	alive, nextEpoch, state, detail := engine.nativePlaybackStatus()
	if !alive || state != "alive" {
		t.Fatalf("expected status probe to recreate listener, got alive=%v state=%q detail=%q", alive, state, detail)
	}
	if nextEpoch != epoch+1 {
		t.Fatalf("expected listener epoch to advance from %d to %d, got %d", epoch, epoch+1, nextEpoch)
	}
	engine.mu.Lock()
	current := engine.stream
	engine.mu.Unlock()
	if current == nil || current == old {
		t.Fatal("expected a new listener instance after recreation")
	}
	defer current.nativeClose()
}
