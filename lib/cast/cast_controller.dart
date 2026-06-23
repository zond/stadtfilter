import 'package:flutter/foundation.dart';

import '../audio_player_handler.dart';
import 'dlna.dart';

/// Coordinates "casting" the stream to a network speaker: discovers DLNA
/// renderers and tells the chosen one to play the relay URL directly, while
/// pausing playback on the phone.
///
/// Because the speaker streams straight from the relay (not via the phone), the
/// phone is not in the audio path — it only sends control commands. It can even
/// sleep; the speaker keeps playing.
class CastController extends ChangeNotifier {
  final AudioPlayerHandler _handler;
  final DlnaService _dlna = DlnaService();

  CastController(this._handler);

  static final Uri _streamUri = Uri.parse(kStreamUrl);

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
      debugPrint('[cast] discover: ${devices.length} device(s) '
          '${devices.map((d) => "${d.name}${d.supportsVolume ? "+vol" : ""}").toList()}');
      if (devices.isEmpty) error = 'Keine Lautsprecher gefunden';
    } catch (e) {
      debugPrint('[cast] discover error: $e');
      devices = const [];
      error = 'Suche fehlgeschlagen';
    }
    isDiscovering = false;
    notifyListeners();
  }

  Future<void> castTo(DlnaRenderer target) async {
    error = null;
    try {
      debugPrint('[cast] castTo "${target.name}" control=${target.controlUrl}');
      await _handler.pause(); // hand audio over to the speaker
      await _dlna.playStream(target, _streamUri);
      debugPrint('[cast] playStream ok on "${target.name}"');
      device = target;
      deviceIsPlaying = true;
      // Keep the media session active and route its controls to the speaker, so
      // the notification/lock-screen buttons control the cast.
      _handler.onCastPlay = () => toggleDevicePlayPause();
      _handler.onCastPause = () => toggleDevicePlayPause();
      _handler.setCasting(active: true, playing: true);
      notifyListeners();
      _loadVolume();
    } catch (e) {
      debugPrint('[cast] castTo error: $e');
      error = 'Verbindung zu ${target.name} fehlgeschlagen';
      device = null;
      notifyListeners();
    }
  }

  /// Play/pause on the speaker while casting. For a live stream we stop on pause
  /// and re-point the speaker at the relay on play (so it resumes at "live").
  Future<void> toggleDevicePlayPause() async {
    final d = device;
    if (d == null) return;
    if (deviceIsPlaying) {
      deviceIsPlaying = false;
      _handler.setCasting(active: true, playing: false);
      notifyListeners();
      try {
        await _dlna.stop(d);
      } catch (_) {}
    } else {
      try {
        await _dlna.playStream(d, _streamUri);
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
  }

  @override
  void dispose() {
    _dlna.dispose();
    super.dispose();
  }
}
