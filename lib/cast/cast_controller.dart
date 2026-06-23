import 'package:flutter/foundation.dart';

import '../audio_player_handler.dart';
import 'dlna.dart';
import 'stream_relay_server.dart';

/// Coordinates "casting" the stream to a network speaker: runs the local relay,
/// discovers DLNA renderers, and drives playback on the chosen device while
/// pausing playback on the phone.
class CastController extends ChangeNotifier {
  final AudioPlayerHandler _handler;
  final DlnaService _dlna = DlnaService();
  final StreamRelayServer _relay = StreamRelayServer();

  /// [nowPlaying] supplies the live "Artist – Title" so the relay can show it
  /// on speakers via ICY metadata.
  CastController(this._handler, {String? Function()? nowPlaying}) {
    _relay.nowPlaying = nowPlaying;
  }

  bool isDiscovering = false;
  List<DlnaRenderer> devices = const [];

  /// The speaker we're currently casting to, or null when playing on the phone.
  DlnaRenderer? device;
  bool deviceIsPlaying = false;
  int? volume; // speaker volume 0–100, if known
  String? error;

  bool get isCasting => device != null;
  bool get supportsVolume => device?.supportsVolume ?? false;

  Future<void> discover() async {
    isDiscovering = true;
    error = null;
    notifyListeners();
    try {
      devices = await _dlna.discover();
      if (devices.isEmpty) error = 'Keine Lautsprecher gefunden';
    } catch (_) {
      devices = const [];
      error = 'Suche fehlgeschlagen';
    }
    isDiscovering = false;
    notifyListeners();
  }

  Future<void> castTo(DlnaRenderer target) async {
    error = null;
    try {
      final url = await _relay.start();
      if (url == null) {
        error = 'Kein WLAN gefunden';
        notifyListeners();
        return;
      }
      await _handler.pause(); // hand audio over to the speaker
      await _dlna.playStream(target, url);
      device = target;
      deviceIsPlaying = true;
      // Route notification/lock-screen controls to the speaker and keep the
      // foreground service (and its wake lock) alive so the relay survives the
      // screen turning off.
      _handler.onCastPlay = () => toggleDevicePlayPause();
      _handler.onCastPause = () => toggleDevicePlayPause();
      _handler.setCasting(active: true, playing: true);
      notifyListeners();
      _loadVolume();
    } catch (_) {
      error = 'Verbindung zu ${target.name} fehlgeschlagen';
      await _relay.stop();
      device = null;
      notifyListeners();
    }
  }

  /// Play/pause on the speaker while casting. Pause tears the relay (and its
  /// upstream HTTP fetch) down — a soft UPnP pause can do nothing when the
  /// stream has stalled — and play restarts it from live.
  Future<void> toggleDevicePlayPause() async {
    final d = device;
    if (d == null) return;
    if (deviceIsPlaying) {
      // Reflect "stopped" immediately so the UI is responsive, then tear down.
      deviceIsPlaying = false;
      _handler.setCasting(active: true, playing: false);
      notifyListeners();
      await _relay.stop(); // aborts the upstream fetch / speaker connection
      try {
        await _dlna.stop(d);
      } catch (_) {}
    } else {
      try {
        final url = await _relay.start();
        if (url == null) {
          error = 'Kein WLAN gefunden';
          notifyListeners();
          return;
        }
        await _dlna.playStream(d, url);
        deviceIsPlaying = true;
        _handler.setCasting(active: true, playing: true);
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> _loadVolume() async {
    final d = device;
    if (d == null || !d.supportsVolume) return;
    try {
      volume = await _dlna.getVolume(d);
      notifyListeners();
    } catch (_) {}
  }

  /// Sets the speaker volume (0–100).
  Future<void> setVolume(int value) async {
    final d = device;
    if (d == null) return;
    volume = value.clamp(0, 100);
    notifyListeners();
    try {
      await _dlna.setVolume(d, volume!);
    } catch (_) {}
  }

  /// Stop casting and return control to the phone.
  Future<void> disconnect() async {
    final d = device;
    device = null;
    deviceIsPlaying = false;
    volume = null;
    _handler.onCastPlay = null;
    _handler.onCastPause = null;
    _handler.setCasting(active: false, playing: false);
    notifyListeners();
    if (d != null) {
      try {
        await _dlna.stop(d);
      } catch (_) {}
    }
    await _relay.stop();
  }

  @override
  void dispose() {
    _relay.stop();
    _dlna.dispose();
    super.dispose();
  }
}
