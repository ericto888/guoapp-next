package core

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type nativeStreamAsset struct {
	kind        string
	address     string
	data        []byte
	contentType string
	total       int64
	etag        string
	modified    string
}

type nativeStreamSession struct {
	credentials  *MediaCredentials
	mu           sync.Mutex
	assets       map[string]nativeStreamAsset
	referer      string
	key          []byte
	ctx          context.Context
	cancel       context.CancelFunc
	lastUsed     time.Time
	diagnosticID string
	cencKey      []byte
	cencMu       sync.Mutex
	cenc         *cencLayout
}

type nativeStreamServer struct {
	mu         sync.Mutex
	downloader *Downloader
	address    string
	sessions   map[string]*nativeStreamSession
	server     *http.Server
	listener   net.Listener
	lan        *http.Server
	lanPort    int
	// 系统可能在应用挂起后回收监听套接字，Serve 返回即视为失效。
	failed     atomic.Bool
	serveError string // protected by mu
}

func (stream *nativeStreamServer) lanOrigin(device string) (string, error) {
	if _, _, err := net.SplitHostPort(device); err != nil {
		device = net.JoinHostPort(device, "80")
	}
	probe, err := net.Dial("udp4", device)
	if err != nil {
		return "", fmt.Errorf("无法确定本机在局域网中的地址：%w", err)
	}
	host := probe.LocalAddr().(*net.UDPAddr).IP.String()
	_ = probe.Close()
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if stream.lan == nil {
		listener, err := net.Listen("tcp4", ":0")
		if err != nil {
			return "", fmt.Errorf("无法开启局域网投屏服务：%w", err)
		}
		stream.lan = &http.Server{Handler: stream.server.Handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
		stream.lanPort = listener.Addr().(*net.TCPAddr).Port
		go func(server *http.Server) { _ = server.Serve(listener) }(stream.lan)
	}
	return "http://" + net.JoinHostPort(host, strconv.Itoa(stream.lanPort)), nil
}

func (stream *nativeStreamServer) lanClose() {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if stream.lan != nil {
		_ = stream.lan.Close()
		stream.lan = nil
	}
}

func (stream *nativeStreamServer) lanPlaylist(request *http.Request, body string) string {
	if origin := "http://" + request.Host; origin != stream.address {
		return strings.ReplaceAll(body, stream.address+"/", origin+"/")
	}
	return body
}

func (stream *nativeStreamServer) nativeRequest(request *http.Request) (*http.Response, error) {
	client := *stream.downloader.client
	client.Timeout = 0
	info, _ := request.Context().Value(nativeStreamDiagnosticKey{}).(nativeStreamDiagnostic)
	response, err := stream.downloader.doMediaRequestWithClient(request, &client)
	if err != nil {
		stream.nativeLogError(info, "upstream_error", request.URL.String(), err, "")
		return response, err
	}
	address := request.URL.String()
	if response.Request != nil && response.Request.URL != nil {
		address = response.Request.URL.String()
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		stream.nativeLog(info, "upstream_status", address, "", response.StatusCode, response.Header.Get("Content-Type"))
	}
	response.Body = &nativeDiagnosticBody{ReadCloser: response.Body, stream: stream, info: info, address: address}
	return response, nil
}

var nativePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

func newNativeStreamServer(d *Downloader) (*nativeStreamServer, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("无法初始化本机播放器")
	}
	stream := &nativeStreamServer{downloader: d, address: "http://" + listener.Addr().String(), sessions: map[string]*nativeStreamSession{}, listener: listener}
	server := &http.Server{Handler: http.HandlerFunc(stream.nativeServe), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.server = server
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			stream.mu.Lock()
			stream.serveError = err.Error()
			stream.failed.Store(true)
			stream.mu.Unlock()
			stream.nativeLog(nativeStreamDiagnostic{}, "listener_error", stream.address, err.Error(), 0, "")
		}
	}()
	return stream, nil
}

// nativeProbe 区分明确失效与暂时无法判断。只有 listener 已退出或收到
// connection refused 才判定 dead；超时、网络栈恢复中的其他错误返回 unknown。
func (stream *nativeStreamServer) nativeProbe() (state, detail string, elapsed time.Duration) {
	started := time.Now()
	defer func() { elapsed = time.Since(started) }()
	if stream == nil {
		return "dead", "listener=nil", 0
	}
	stream.mu.Lock()
	listener := stream.listener
	failed := stream.failed.Load()
	serveError := stream.serveError
	stream.mu.Unlock()
	if listener == nil {
		return "dead", "listener=nil", 0
	}
	if failed {
		return "dead", "serve_error="+serveError, 0
	}
	address := listener.Addr().String()
	connection, err := net.DialTimeout("tcp", address, 350*time.Millisecond)
	if err == nil {
		_ = connection.Close()
		return "alive", "address="+address, 0
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "dead", "address="+address+" error=connection_refused", 0
	}
	return "unknown", "address="+address+" error="+nativeStreamError(err), 0
}

// nativeAlive 保留给不需要诊断细节的内部调用。
func (stream *nativeStreamServer) nativeAlive() bool {
	state, _, _ := stream.nativeProbe()
	return state == "alive"
}

// nativeClose 关闭监听与所有会话，返回关闭前仍在跟踪的会话数量。
func (stream *nativeStreamServer) nativeClose() int {
	stream.mu.Lock()
	stream.failed.Store(true)
	sessions := stream.sessions
	stream.sessions = map[string]*nativeStreamSession{}
	server := stream.server
	stream.mu.Unlock()
	for _, session := range sessions {
		session.cancel()
	}
	if server != nil {
		_ = server.Close()
	}
	return len(sessions)
}

func (stream *nativeStreamServer) nativeOpen(media ProviderMedia) (string, string) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(tokenBytes)
	ctx, cancel := context.WithCancel(providerMediaContext(context.Background(), media.Credentials))
	session := &nativeStreamSession{assets: map[string]nativeStreamAsset{}, referer: media.Referer, key: media.HLSKey, ctx: ctx, cancel: cancel, lastUsed: time.Now(), credentials: media.Credentials, diagnosticID: nativeStreamID(token)}
	stream.mu.Lock()
	for id, old := range stream.sessions {
		if time.Since(old.lastUsed) > 10*time.Minute {
			stream.nativeCancel(old, "idle_expired")
			delete(stream.sessions, id)
		}
	}
	if len(stream.sessions) >= 8 {
		oldest := ""
		for id, old := range stream.sessions {
			if oldest == "" || old.lastUsed.Before(stream.sessions[oldest].lastUsed) {
				oldest = id
			}
		}
		stream.nativeCancel(stream.sessions[oldest], "capacity_eviction")
		delete(stream.sessions, oldest)
	}
	stream.sessions[token] = session
	stream.mu.Unlock()
	entry := nativeStreamAsset{kind: "media", address: media.URL, contentType: "video/mp4"}
	parsedURL, parseErr := url.Parse(media.URL)
	isHLS := media.Playlist != "" || (parseErr == nil && strings.HasSuffix(strings.ToLower(parsedURL.Path), ".m3u8"))
	if isHLS {
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if media.Playlist != "" {
		entry.data = []byte(media.Playlist)
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if isHLS || strings.Contains(entry.contentType, "mpegurl") {
		entry.kind = "entry_playlist"
	}
	return stream.nativeAsset(token, session, entry), token
}

func (stream *nativeStreamServer) nativeCancel(session *nativeStreamSession, reason string) {
	if reason != "release" {
		stream.nativeLog(nativeStreamDiagnostic{session: session.diagnosticID}, "session_cancel", "", "reason="+reason, 0, "")
	}
	session.cancel()
}

func (stream *nativeStreamServer) nativeRelease(token string) {
	stream.mu.Lock()
	if session := stream.sessions[token]; session != nil {
		stream.nativeCancel(session, "release")
		delete(stream.sessions, token)
	}
	stream.mu.Unlock()
}

func (stream *nativeStreamServer) nativeAsset(token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	digest := sha256.Sum256([]byte(asset.address + "\x00" + asset.contentType))
	extension := ".ts"
	if parsed, err := url.Parse(asset.address); err == nil {
		switch candidate := strings.ToLower(path.Ext(parsed.Path)); candidate {
		case ".m3u8", ".ts", ".m4s", ".mp4", ".aac", ".m4a", ".mp3", ".vtt", ".webvtt", ".key":
			extension = candidate
		}
	}
	switch asset.contentType {
	case "application/vnd.apple.mpegurl":
		extension = ".m3u8"
	case "application/octet-stream":
		extension = ".key"
	case "video/mp4":
		extension = ".mp4"
	}
	id := hex.EncodeToString(digest[:12]) + extension
	session.mu.Lock()
	if previous, found := session.assets[id]; !found || len(previous.data) == 0 || len(asset.data) > 0 {
		session.assets[id] = asset
	}
	session.mu.Unlock()
	return stream.address + "/" + token + "/" + id
}

func (stream *nativeStreamServer) nativeRewrite(token string, session *nativeStreamSession, body, base string) (string, error) {
	var output []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		rewrite := func(reference string, key bool, contentType string) string {
			if strings.HasPrefix(reference, "data:") {
				return reference
			}
			parsed, err := url.Parse(base)
			if err != nil {
				return ""
			}
			relative, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			address := parsed.ResolveReference(relative).String()
			if !IsProviderHTTPMediaURL(address) {
				return ""
			}
			kind := "segment"
			switch contentType {
			case "application/vnd.apple.mpegurl":
				kind = "child_playlist"
			case "application/octet-stream":
				kind = "key"
			case "video/mp4":
				kind = "map"
			}
			asset := nativeStreamAsset{kind: kind, address: address, contentType: contentType}
			if key && len(session.key) == 16 {
				asset.data = append([]byte{}, session.key...)
				asset.contentType = "application/octet-stream"
			}
			return stream.nativeAsset(token, session, asset)
		}
		if text != "" && !strings.HasPrefix(text, "#") {
			contentType := ""
			if nextPlaylist {
				contentType = "application/vnd.apple.mpegurl"
			}
			line = rewrite(text, false, contentType)
			nextPlaylist = false
			if line == "" {
				return "", errors.New("播放列表中的媒体地址无效")
			}
		} else if strings.Contains(text, "URI=") {
			invalid := false
			line = nativePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := nativePlaylistURI.FindStringSubmatch(match)[1]
				key := strings.HasPrefix(text, "#EXT-X-KEY:") || strings.HasPrefix(text, "#EXT-X-SESSION-KEY:")
				contentType := ""
				switch {
				case key:
					contentType = "application/octet-stream"
				case strings.HasPrefix(text, "#EXT-X-MAP:"):
					contentType = "video/mp4"
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"), strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"), strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					contentType = "application/vnd.apple.mpegurl"
				}
				updated := rewrite(reference, key, contentType)
				if updated == "" {
					invalid = true
				}
				return "URI=\"" + updated + "\""
			})
			if invalid {
				return "", errors.New("播放列表中的附属地址无效")
			}
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	return strings.Join(output, "\n"), nil
}

func (stream *nativeStreamServer) nativeServe(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 2 {
		http.NotFound(writer, request)
		return
	}
	stream.mu.Lock()
	session := stream.sessions[parts[0]]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	session.mu.Lock()
	asset, found := session.assets[parts[1]]
	session.mu.Unlock()
	info := nativeStreamDiagnostic{session: session.diagnosticID, asset: asset.kind, role: "playback"}
	if !found {
		stream.nativeLog(info, "asset_missing", "", "", 0, "")
		http.NotFound(writer, request)
		return
	}
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	ctx = context.WithValue(ctx, nativeStreamDiagnosticKey{}, info)
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	if len(asset.data) > 0 && asset.total > int64(len(asset.data)) {
		if stream.nativeServePrefix(ctx, writer, request, session, asset) {
			return
		}
		asset.data = nil
	}
	if len(asset.data) > 0 {
		if strings.Contains(asset.contentType, "mpegurl") {
			body, err := stream.nativeRewrite(parts[0], session, string(asset.data), asset.address)
			if err != nil {
				stream.nativeLog(info, "playlist_rewrite", asset.address, "kind="+nativePlaylistKind(string(asset.data))+" error="+nativeStreamError(err), 0, "")
				http.Error(writer, err.Error(), http.StatusBadGateway)
				return
			}
			writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			if request.Method == http.MethodGet {
				_, _ = io.WriteString(writer, stream.lanPlaylist(request, body))
			}
		} else {
			writer.Header().Set("Content-Type", asset.contentType)
			if asset.etag != "" {
				writer.Header().Set("ETag", asset.etag)
			}
			http.ServeContent(writer, request, parts[1], time.Time{}, bytes.NewReader(asset.data))
		}
		return
	}
	if len(session.cencKey) > 0 && asset.kind == "media" {
		stream.nativeServeDecrypted(ctx, writer, request, session, asset)
		return
	}
	upstream, err := http.NewRequestWithContext(ctx, request.Method, asset.address, nil)
	if err != nil {
		http.Error(writer, "媒体地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", UserAgent)
	upstream.Header.Set("Referer", session.referer)
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		err := stream.downloader.catalogResponseError(upstream, response, body)
		http.Error(writer, err.Error(), response.StatusCode)
		return
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	finalURL := upstream.URL
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL
	}
	contentIsMP4 := strings.Contains(contentType, "video/mp4")
	playlist := strings.Contains(contentType, "mpegurl") ||
		(strings.HasSuffix(strings.ToLower(finalURL.Path), ".m3u8") && !contentIsMP4)
	reader := bufio.NewReader(response.Body)
	if request.Method == http.MethodGet {
		peek, _ := reader.Peek(512)
		bodyIsPlaylist := strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(string(peek), "\ufeff")), "#EXTM3U")
		if bodyIsPlaylist {
			playlist = true
		} else if contentIsMP4 {
			playlist = false
		}
	}
	if playlist && request.Method == http.MethodHead {
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.WriteHeader(http.StatusOK)
		return
	}
	if playlist && request.Method == http.MethodGet {
		body, err := io.ReadAll(io.LimitReader(reader, 4<<20+1))
		if err != nil || len(body) > 4<<20 {
			stream.nativeLogError(info, "playlist_read_failed", finalURL.String(), err, contentType)
			http.Error(writer, "播放列表过大或读取失败", http.StatusBadGateway)
			return
		}
		text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
		if !strings.HasPrefix(text, "#EXTM3U") {
			stream.nativeLog(info, "playlist_invalid", finalURL.String(), "", 0, contentType)
			http.Error(writer, "播放列表无效", http.StatusBadGateway)
			return
		}
		rewritten, err := stream.nativeRewrite(parts[0], session, text, finalURL.String())
		if err != nil {
			stream.nativeLog(info, "playlist_rewrite", finalURL.String(), "kind="+nativePlaylistKind(text)+" error="+nativeStreamError(err), 0, contentType)
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(writer, stream.lanPlaylist(request, rewritten))
		return
	}
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, reader)
	}
}
