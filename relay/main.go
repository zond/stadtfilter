// Command relay re-serves the Radio Stadtfilter MP3 stream.
//
// The origin (streamer.stadtfilter.net) refuses to send audio bytes to clients
// that don't look like a browser — native players (ExoPlayer, etc.) connect but
// hang in "loading" forever. This relay fetches the stream with a browser
// User-Agent and re-serves the bytes to anyone, no questions asked.
//
// A single upstream connection is shared (fanned out) across all listeners, so
// the origin only ever sees one browser-like client regardless of how many
// people are tuned in. When the last listener leaves, the upstream fetch is
// kept alive for idleTimeout and then dropped; the next listener revives it.
package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

const (
	// upstreamURL is the real Radio Stadtfilter MP3 stream.
	upstreamURL = "https://streamer.stadtfilter.net/stadtfilter.mp3"

	// userAgent makes the origin treat us as a browser. The same string is used
	// by the Flutter app (see lib/audio_player_handler.dart). Without a
	// browser-like UA the origin accepts the connection but never sends bytes.
	userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

	// idleTimeout is how long the upstream fetch stays open after the last
	// listener disconnects, so brief gaps (skips, reconnects) don't churn the
	// origin connection.
	idleTimeout = 3 * time.Minute

	// chunkSize is how many bytes we read from the origin per broadcast step.
	chunkSize = 16 * 1024

	// subBuffer is how many chunks a listener may fall behind before it is
	// dropped as too slow (chunkSize * subBuffer bytes of slack ~= a few MB).
	subBuffer = 256
)

func main() {
	addr := flag.String("addr", ":8080", "address to listen on")
	flag.Parse()

	h := newHub()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("/", h.serveStream)

	srv := &http.Server{Addr: *addr, Handler: mux}
	log.Printf("relay listening on %s, upstream %s", *addr, upstreamURL)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server: %v", err)
	}
}

// hub holds the shared upstream connection and fans its bytes out to every
// connected listener.
type hub struct {
	client *http.Client

	mu      sync.Mutex
	subs    map[*subscriber]struct{}
	cancel  context.CancelFunc // cancels the running upstream pump, if any
	idle    *time.Timer        // running while there are zero listeners
}

type subscriber struct {
	ch   chan []byte
	once sync.Once
}

func (s *subscriber) close() { s.once.Do(func() { close(s.ch) }) }

func newHub() *hub {
	return &hub{
		// No client-level timeout: the body is an endless live stream. Timeouts
		// below bound only connection setup, not the streaming read.
		client: &http.Client{
			Transport: &http.Transport{
				ResponseHeaderTimeout: 15 * time.Second,
			},
		},
		subs: make(map[*subscriber]struct{}),
	}
}

// subscribe registers a listener and ensures the upstream pump is running.
func (h *hub) subscribe() *subscriber {
	s := &subscriber{ch: make(chan []byte, subBuffer)}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.idle != nil {
		h.idle.Stop()
		h.idle = nil
	}
	h.subs[s] = struct{}{}
	if h.cancel == nil {
		ctx, cancel := context.WithCancel(context.Background())
		h.cancel = cancel
		go h.pump(ctx)
	}
	return s
}

// unsubscribe removes a listener. When the last one leaves, it arms the idle
// timer that will eventually stop the upstream fetch.
func (h *hub) unsubscribe(s *subscriber) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.subs[s]; !ok {
		return
	}
	delete(h.subs, s)
	s.close()
	if len(h.subs) == 0 && h.idle == nil {
		h.idle = time.AfterFunc(idleTimeout, h.stopUpstream)
		log.Printf("no listeners; upstream will stop in %s", idleTimeout)
	}
}

// stopUpstream cancels the pump if (and only if) there are still no listeners.
func (h *hub) stopUpstream() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.idle = nil
	if len(h.subs) > 0 {
		return // someone reconnected during the grace period
	}
	if h.cancel != nil {
		h.cancel()
		h.cancel = nil
		log.Printf("upstream stopped (idle)")
	}
}

// broadcast sends a chunk to every listener, dropping any that have fallen too
// far behind (their handler will notice the closed channel and disconnect).
func (h *hub) broadcast(b []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for s := range h.subs {
		select {
		case s.ch <- b:
		default:
			// Listener too slow; drop it rather than stall everyone else.
			delete(h.subs, s)
			s.close()
		}
	}
}

// pump maintains the single upstream connection for as long as ctx is alive,
// reconnecting with backoff if the origin drops.
func (h *hub) pump(ctx context.Context) {
	const backoff = 2 * time.Second
	for ctx.Err() == nil {
		if err := h.stream(ctx); err != nil && ctx.Err() == nil {
			log.Printf("upstream error: %v (retrying in %s)", err, backoff)
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
			}
		}
	}
}

// stream opens one upstream connection and broadcasts its bytes until the
// origin ends, an error occurs, or ctx is cancelled.
func (h *hub) stream(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, upstreamURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "*/*")

	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("upstream status " + resp.Status)
	}
	log.Printf("upstream connected (%s)", resp.Header.Get("Content-Type"))

	buf := make([]byte, chunkSize)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			// Copy: buf is reused and subscribers read asynchronously.
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			h.broadcast(chunk)
		}
		if err != nil {
			if errors.Is(err, io.EOF) || ctx.Err() != nil {
				return nil
			}
			return err
		}
	}
}

// serveStream sends the live audio to a single listener.
func (h *hub) serveStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "audio/mpeg")
	w.Header().Set("Cache-Control", "no-cache, no-store")
	w.Header().Set("icy-name", "Radio Stadtfilter")
	w.Header().Set("Connection", "close")

	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	sub := h.subscribe()
	defer h.unsubscribe(sub)
	log.Printf("listener connected: %s", r.RemoteAddr)
	defer log.Printf("listener disconnected: %s", r.RemoteAddr)

	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case chunk, ok := <-sub.ch:
			if !ok {
				return // dropped (too slow) or hub shutting down
			}
			if _, err := w.Write(chunk); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}
