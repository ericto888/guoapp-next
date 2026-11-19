package core

import (
	"errors"
	"net"
	"syscall"
	"time"
)

// nativeProbe 区分明确失效与暂时无法判断。只有 listener 已退出或收到
// connection refused 才判定 dead；超时、网络栈恢复中的其他错误返回 unknown。
func (stream *nativeStreamServer) nativeProbe() (string, string, time.Duration) {
	started := time.Now()
	if stream == nil {
		return "dead", "listener=nil", time.Since(started)
	}
	if stream.failed.Load() {
		return "dead", "serve_returned", time.Since(started)
	}
	listener := stream.listener
	if listener == nil {
		return "dead", "listener=nil", time.Since(started)
	}
	address := listener.Addr().String()
	connection, err := net.DialTimeout("tcp", address, 350*time.Millisecond)
	elapsed := time.Since(started)
	if err == nil {
		_ = connection.Close()
		return "alive", "address="+address, elapsed
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "dead", "address="+address+" error=connection_refused", elapsed
	}
	return "unknown", "address="+address+" error="+nativeStreamError(err), elapsed
}
