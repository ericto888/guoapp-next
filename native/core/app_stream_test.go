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
