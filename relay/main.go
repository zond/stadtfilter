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
//
// ICY metadata: the relay reads the origin's StreamTitle metadata and strips it
// from the shared audio, then re-injects it only for listeners that request
// `Icy-MetaData: 1` (players, Sonos/WiiM). Listeners that don't ask get pure
// audio, since interleaved metadata bytes would corrupt playback for them.
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// upstreamURLs are the Radio Stadtfilter MP3 stream endpoints, tried in order.
// The pump sticks with whichever one is working and falls back to the next on
// failure, so an outage or throttle on one mount doesn't take the relay down.
var upstreamURLs = []string{
	"https://streamer.stadtfilter.net/stadtfilter.mp3",
	"http://streamer1.stadtfilter.net:8406/stadtfilter.mp3",
}

const (
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

	// burstMax is how much recent audio we keep to "burst" to a newly connected
	// listener, so playback starts immediately instead of waiting for the next
	// upstream bytes. Mirrors Icecast's burst-on-connect behaviour.
	burstMax = 256 * 1024
)

func main() {
	addr := flag.String("addr", ":8080", "address to listen on")
	flag.Parse()

	h := newHub()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		listeners, connected := h.stats()
		upstream := "down"
		if connected {
			upstream = "up"
		}
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "ok\nlisteners %d\nupstream %s\n", listeners, upstream)
	})
	mux.HandleFunc("/", h.serveStream)

	srv := &http.Server{Addr: *addr, Handler: mux}

	// Shut down cleanly on SIGINT/SIGTERM (systemd sends SIGTERM on stop).
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("relay listening on %s, upstreams %v", *addr, upstreamURLs)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutting down")
	h.shutdown() // disconnect listeners so their streaming handlers return

	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Printf("graceful shutdown timed out: %v", err)
		_ = srv.Close()
	}
}

// hub holds the shared upstream connection and fans its bytes out to every
// connected listener.
type hub struct {
	client *http.Client

	mu        sync.Mutex
	subs      map[*subscriber]struct{}
	cancel    context.CancelFunc // cancels the running upstream pump, if any
	idle      *time.Timer        // running while there are zero listeners
	connected bool               // true while the upstream is delivering bytes
	burst     [][]byte           // recent chunks replayed to new listeners
	burstSize int                // total bytes currently held in burst
	title     string             // current ICY StreamTitle from the origin
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
	// Burst-on-connect: prime the listener with recent audio so playback starts
	// right away. The channel capacity (subBuffer) far exceeds the burst size,
	// so these sends never block.
	for _, b := range h.burst {
		select {
		case s.ch <- b:
		default:
		}
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
		// Drop the burst: after an idle gap it is stale audio that would make a
		// reviving listener start minutes in the past before jumping to live.
		h.burst = nil
		h.burstSize = 0
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
	// Keep the most recent bytes for burst-on-connect, trimming from the front.
	h.burst = append(h.burst, b)
	h.burstSize += len(b)
	for h.burstSize > burstMax && len(h.burst) > 1 {
		h.burstSize -= len(h.burst[0])
		h.burst[0] = nil // let the dropped chunk be collected
		h.burst = h.burst[1:]
	}
}

// setConnected records whether the upstream is currently delivering bytes,
// for reporting on /healthz.
func (h *hub) setConnected(v bool) {
	h.mu.Lock()
	h.connected = v
	h.mu.Unlock()
}

// stats returns the current listener count and upstream state for /healthz.
func (h *hub) stats() (listeners int, connected bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs), h.connected
}

// setTitle records the current ICY StreamTitle parsed from the origin.
func (h *hub) setTitle(t string) {
	h.mu.Lock()
	changed := t != h.title
	h.title = t
	h.mu.Unlock()
	if changed {
		log.Printf("now playing: %s", t)
	}
}

// currentTitle returns the latest ICY StreamTitle.
func (h *hub) currentTitle() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.title
}

// shutdown stops the upstream fetch and disconnects every listener so their
// (otherwise indefinitely blocked) handlers return. Used on SIGINT/SIGTERM.
func (h *hub) shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.idle != nil {
		h.idle.Stop()
		h.idle = nil
	}
	if h.cancel != nil {
		h.cancel()
		h.cancel = nil
	}
	for s := range h.subs {
		delete(h.subs, s)
		s.close()
	}
}

// pump maintains the single upstream connection for as long as ctx is alive.
//
// The first attempt is immediate (so listeners don't wait), but every
// reconnect is paused with exponential backoff + jitter, capped at maxDelay.
// This matters: an Icecast-style origin throttles an IP that reconnects to the
// audio mount too quickly, answering further requests with a tarpit (accept,
// never respond). A tight retry loop both triggers that throttle and keeps it
// alive, so backing off gently is what lets the origin's cooldown clear.
func (h *hub) pump(ctx context.Context) {
	const (
		baseDelay = 5 * time.Second
		maxDelay  = 2 * time.Minute
	)
	fails := 0
	idx := 0
	for ctx.Err() == nil {
		url := upstreamURLs[idx]
		connected, err := h.stream(ctx, url)
		if ctx.Err() != nil {
			return
		}
		if connected {
			fails = 0 // stay on this upstream; it works
		} else {
			fails++
			idx = (idx + 1) % len(upstreamURLs) // fall back to the next upstream
		}
		if err != nil {
			log.Printf("upstream error (%s): %v", url, err)
		}
		// Pause before the next attempt. After a successful connection the
		// pause is just baseDelay (avoids a tight loop if the origin keeps
		// dropping us); after consecutive failures it grows exponentially.
		delay := baseDelay
		if fails > 0 {
			delay = baseDelay * time.Duration(1<<min(fails-1, 5))
			if delay > maxDelay {
				delay = maxDelay
			}
		}
		delay += time.Duration(rand.Int63n(int64(baseDelay)))
		log.Printf("reconnecting in %s", delay.Round(time.Second))
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return
		}
	}
}

// stream opens one upstream connection and broadcasts its bytes until the
// origin ends, an error occurs, or ctx is cancelled. The bool reports whether
// the connection got as far as a 200 response (used to reset retry backoff).
func (h *hub) stream(ctx context.Context, url string) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "*/*")
	// Ask for ICY metadata so we can track the current song title.
	req.Header.Set("Icy-MetaData", "1")

	resp, err := h.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, errors.New("upstream status " + resp.Status)
	}
	metaint := 0
	if v := resp.Header.Get("icy-metaint"); v != "" {
		metaint, _ = strconv.Atoi(v)
	}
	log.Printf("upstream connected: %s (%s, icy-metaint=%d)", url,
		resp.Header.Get("Content-Type"), metaint)
	h.setConnected(true)
	defer h.setConnected(false)

	// De-interleave: strip the origin's metadata blocks so the fan-out carries
	// pure audio, updating the current title as it changes. When the origin
	// sends no ICY metadata (metaint == 0) this is a plain copy.
	reader := bufio.NewReaderSize(resp.Body, 64*1024)
	buf := make([]byte, chunkSize)
	audioLeft := metaint
	for {
		if metaint > 0 && audioLeft == 0 {
			lenByte, err := reader.ReadByte()
			if err != nil {
				return true, ignoreExpected(err, ctx)
			}
			if mlen := int(lenByte) * 16; mlen > 0 {
				meta := make([]byte, mlen)
				if _, err := io.ReadFull(reader, meta); err != nil {
					return true, ignoreExpected(err, ctx)
				}
				if title := parseStreamTitle(meta); title != "" {
					h.setTitle(title)
				}
			}
			audioLeft = metaint
		}
		toRead := len(buf)
		if metaint > 0 && audioLeft < toRead {
			toRead = audioLeft
		}
		n, err := reader.Read(buf[:toRead])
		if n > 0 {
			// Copy: buf is reused and subscribers read asynchronously.
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			h.broadcast(chunk)
			if metaint > 0 {
				audioLeft -= n
			}
		}
		if err != nil {
			return true, ignoreExpected(err, ctx)
		}
	}
}

// ignoreExpected maps EOF / a cancelled context to a nil error (a normal end),
// and returns anything else unchanged.
func ignoreExpected(err error, ctx context.Context) error {
	if errors.Is(err, io.EOF) || ctx.Err() != nil {
		return nil
	}
	return err
}

// serveStream sends the live audio to a single listener.
func (h *hub) serveStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Only listeners that ask for ICY get metadata interleaved; everyone else
	// gets pure audio (metadata bytes would corrupt playback for them).
	const serveMetaint = 16000
	wantsIcy := r.Header.Get("Icy-MetaData") == "1"

	w.Header().Set("Content-Type", "audio/mpeg")
	w.Header().Set("Cache-Control", "no-cache, no-store")
	w.Header().Set("icy-name", "Radio Stadtfilter")
	w.Header().Set("Connection", "close")
	if wantsIcy {
		w.Header().Set("icy-metaint", strconv.Itoa(serveMetaint))
	}

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
	log.Printf("listener connected: %s (icy=%v)", r.RemoteAddr, wantsIcy)
	defer log.Printf("listener disconnected: %s", r.RemoteAddr)

	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// Per-connection ICY re-interleaving state.
	counter := 0
	lastTitle := ""

	for {
		select {
		case <-r.Context().Done():
			return
		case chunk, ok := <-sub.ch:
			if !ok {
				return // dropped (too slow) or hub shutting down
			}
			if !wantsIcy {
				if _, err := w.Write(chunk); err != nil {
					return
				}
				flusher.Flush()
				continue
			}
			// Emit a metadata block every serveMetaint bytes of audio.
			data := chunk
			for len(data) > 0 {
				take := serveMetaint - counter
				if len(data) < take {
					take = len(data)
				}
				if _, err := w.Write(data[:take]); err != nil {
					return
				}
				data = data[take:]
				counter += take
				if counter < serveMetaint {
					continue
				}
				counter = 0
				title := h.currentTitle()
				block := []byte{0} // 0 = no change
				if title != lastTitle {
					lastTitle = title
					block = icyMetaBlock(title)
				}
				if _, err := w.Write(block); err != nil {
					return
				}
			}
			flusher.Flush()
		}
	}
}

var streamTitleRe = regexp.MustCompile(`StreamTitle='(.*?)';`)

// parseStreamTitle extracts the StreamTitle value from an ICY metadata block.
func parseStreamTitle(meta []byte) string {
	m := streamTitleRe.FindSubmatch(bytes.TrimRight(meta, "\x00"))
	if m == nil {
		return ""
	}
	return strings.TrimSpace(string(m[1]))
}

// icyMetaBlock builds an ICY metadata block: a length byte (in 16-byte units)
// followed by StreamTitle='…'; padded with NULs to a multiple of 16 bytes.
func icyMetaBlock(title string) []byte {
	safe := strings.NewReplacer("'", "", ";", "").Replace(title)
	payload := []byte("StreamTitle='" + safe + "';")
	blocks := (len(payload) + 15) / 16
	out := make([]byte, 1+blocks*16)
	out[0] = byte(blocks)
	copy(out[1:], payload)
	return out
}
