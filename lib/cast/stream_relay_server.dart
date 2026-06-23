import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../audio_player_handler.dart' show kStreamUrl, kStreamUserAgent;

/// A tiny HTTP server that runs on the phone, pulls the Radio Stadtfilter
/// stream (with the browser User-Agent the origin requires) and re-serves it
/// on the local network so DLNA speakers (Sonos, WiiM, …) can play it.
///
/// The speaker fetches [url]; this server proxies the bytes from the origin.
/// The phone must therefore stay on Wi-Fi (and not be killed) while casting.
class StreamRelayServer {
  static const _path = '/stadtfilter.mp3';

  /// How often (in audio bytes) to inject an ICY metadata block.
  static const _metaInt = 16000;

  HttpServer? _server;
  HttpClient? _client;
  Uri? _url;

  /// Supplies the current "Artist – Title" so speakers that request ICY
  /// metadata (Sonos, WiiM, …) can display the live song. Set by the caller.
  String? Function()? nowPlaying;

  /// The LAN URL a speaker should fetch, or null if not running.
  Uri? get url => _url;
  bool get isRunning => _server != null;

  /// Starts the server (idempotent). Returns the LAN URL, or null if no
  /// suitable local IP could be found.
  Future<Uri?> start() async {
    if (_server != null) return _url;
    final ip = await _lanIp();
    if (ip == null) return null;
    _client = HttpClient();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _url = Uri.parse('http://${ip.address}:${server.port}$_path');
    server.listen(_handle, onError: (_) {});
    return _url;
  }

  /// Stops the relay and **aborts the in-flight upstream fetch**. This is what
  /// makes "pause" responsive when the origin has stalled: closing the client
  /// force-cancels the blocked read so the speaker's connection drops at once,
  /// instead of waiting for a stream that may never resume.
  Future<void> stop() async {
    final s = _server;
    final c = _client;
    _server = null;
    _client = null;
    _url = null;
    c?.close(force: true);
    await s?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path != _path) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final client = _client;
    if (client == null) {
      await res.close();
      return;
    }
    // The speaker asks for ICY metadata so it can show the current song.
    final wantsIcy = req.headers.value('icy-metadata') == '1';
    try {
      final upReq = await client.getUrl(Uri.parse(kStreamUrl));
      upReq.headers.set(HttpHeaders.userAgentHeader, kStreamUserAgent);
      final upstream = await upReq.close();
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType('audio', 'mpeg');
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      res.headers.set('icy-name', 'Radio Stadtfilter');
      if (wantsIcy) res.headers.set('icy-metaint', '$_metaInt');

      if (!wantsIcy) {
        await for (final chunk in upstream) {
          res.add(chunk);
        }
        return;
      }

      // Interleave the audio with ICY metadata blocks every [_metaInt] bytes.
      var counter = 0;
      String lastTitle = '';
      await for (final chunk in upstream) {
        var data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        while (data.isNotEmpty) {
          final remaining = _metaInt - counter;
          if (data.length < remaining) {
            res.add(data);
            counter += data.length;
            break;
          }
          res.add(data.sublist(0, remaining));
          data = data.sublist(remaining);
          counter = 0;
          // Emit the title only when it changes; otherwise a single zero byte.
          final title = nowPlaying?.call() ?? '';
          if (title != lastTitle) {
            lastTitle = title;
            res.add(_icyMeta(title));
          } else {
            res.add(const [0]);
          }
        }
      }
    } catch (_) {
      // Speaker hung up or the origin dropped — just close this connection.
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Builds an ICY metadata block: a length byte (in 16-byte units) followed by
  /// `StreamTitle='…';` padded with NULs to a multiple of 16 bytes.
  List<int> _icyMeta(String title) {
    final safe = title.replaceAll("'", '').replaceAll(';', '');
    final payload = utf8.encode("StreamTitle='$safe';");
    final blocks = (payload.length + 15) ~/ 16;
    final out = Uint8List(1 + blocks * 16);
    out[0] = blocks;
    out.setRange(1, 1 + payload.length, payload);
    return out;
  }

  /// Best-effort private LAN IPv4 of this device (prefers 192.168/10/172.16-31).
  Future<InternetAddress?> _lanIp() async {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    InternetAddress? fallback;
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        fallback ??= addr;
        if (_isPrivate(addr.address)) return addr;
      }
    }
    return fallback;
  }

  bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
}
