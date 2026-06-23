# Radio Stadtfilter relay

A tiny Go service that re-serves the Radio Stadtfilter MP3 stream.

The origin (`streamer.stadtfilter.net`) only sends audio bytes to clients that
look like a browser — native players connect but hang in "loading" forever.
This relay fetches the stream with a browser `User-Agent` and re-serves the
bytes to anyone, no questions asked.

A **single** upstream connection is shared (fanned out) across all listeners,
so the origin only ever sees one browser-like client regardless of how many
people are tuned in. When the last listener disconnects, the upstream fetch is
kept open for a few minutes (`idleTimeout`) and then dropped; the next listener
revives it. If the origin drops mid-stream while listeners are present, the
relay reconnects automatically (exponential backoff + jitter, so a throttling
origin is never hammered). It tries multiple upstream endpoints in order and
sticks with whichever works, falling back to the next on failure. New listeners
get a short burst of recent audio on connect so playback starts immediately.
Shuts down cleanly on SIGTERM.

## Endpoints

- `GET /` (any path) — the live `audio/mpeg` stream.
- `GET /healthz` — liveness; reports the current listener count and whether the
  upstream is delivering bytes, without touching the origin. Example:

  ```
  ok
  listeners 3
  upstream up
  ```

## Build

```sh
cd relay
go build -o stadtfilter-relay .
```

## Run

```sh
./stadtfilter-relay -addr :8080
```

Then point a player at `http://micro.oort.se:8080/`.

## Install as a systemd service

Build and install the binary, then enable the unit:

```sh
cd relay
go build -o stadtfilter-relay .
sudo install -m 0755 stadtfilter-relay /usr/local/bin/stadtfilter-relay

sudo cp stadtfilter-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now stadtfilter-relay
```

Check status and logs:

```sh
systemctl status stadtfilter-relay
journalctl -u stadtfilter-relay -f
```

After rebuilding the binary, reinstall it and restart:

```sh
sudo install -m 0755 stadtfilter-relay /usr/local/bin/stadtfilter-relay
sudo systemctl restart stadtfilter-relay
```
