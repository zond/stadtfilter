import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'audio_player_handler.dart';
import 'models/song.dart';

/// Polls Radio Stadtfilter's (undocumented) web-player endpoints to provide
/// the currently playing track and a history of previously played tracks.
///
/// All HTML/text parsing lives here, so if the station changes its response
/// format this is the only file that needs to change.
class MetadataService extends ChangeNotifier {
  static const _songUrl = 'https://stream.stadtfilter.ch/song.php';
  static const _currentProgramUrl = 'https://stream.stadtfilter.ch/currentP.php';
  static const _trackserviceUrl =
      'https://api.stadtfilter.net/api/trackservice.php';

  static const _pollInterval = Duration(seconds: 15);

  final AudioPlayerHandler _handler;
  final http.Client _client;

  Song? _current;
  Uri? _currentArt;
  final List<Song> _history = [];
  Timer? _timer;
  int _seededYmd = 0;

  MetadataService(this._handler, {http.Client? client})
      : _client = client ?? http.Client();

  Song? get current => _current;
  Uri? get currentArt => _currentArt;

  /// Previously played tracks, newest first.
  List<Song> get history => List.unmodifiable(_history);

  /// Notify the in-app UI and push the history to the audio handler so the
  /// Android Auto "recently played" browse list refreshes too.
  void _emitChanged() {
    notifyListeners();
    _handler.updateHistory(List.unmodifiable(_history));
  }

  /// Begin seeding + polling. Safe to call once.
  Future<void> start() async {
    await _seedFromTrackservice();
    await _poll();
    _timer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }

  // ---- Seeding -------------------------------------------------------------

  /// Loads today's broadcast-day playlist (with timestamps) into the history.
  Future<void> _seedFromTrackservice() async {
    final now = DateTime.now();
    final ymd = int.parse(DateFormat('yyyyMMdd').format(now));
    try {
      final res = await _client.post(
        Uri.parse(_trackserviceUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'Datum': ymd.toString(), 'submit': 'submit'},
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return;
      final seeded = _parseTrackservice(res.body);
      if (seeded.isEmpty) return;
      // Trackservice is chronological (oldest first); we want newest first.
      _history
        ..clear()
        ..addAll(seeded.reversed);
      _seededYmd = ymd;
      _emitChanged();
    } catch (_) {
      // Best effort: history simply starts empty and grows live.
    }
  }

  /// Parses lines of the form `2026-06-22 03:42  Artist - Title<br>`.
  List<Song> _parseTrackservice(String html) {
    final re = RegExp(
      r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+?)\s*<br',
      caseSensitive: false,
    );
    final out = <Song>[];
    for (final m in re.allMatches(html)) {
      final date = m.group(1)!;
      final time = m.group(2)!;
      final track = _unescape(m.group(3)!);
      final ts = DateTime.tryParse('$date $time:00');
      out.add(Song.parse(track, playedAt: ts));
    }
    return out;
  }

  // ---- Live polling --------------------------------------------------------

  Future<void> _poll() async {
    // Re-seed once per broadcast day so timestamps stay correct over midnight.
    final ymd = int.parse(DateFormat('yyyyMMdd').format(DateTime.now()));
    if (ymd != _seededYmd && _seededYmd != 0) {
      await _seedFromTrackservice();
    }

    final raw = await _fetchSong();
    if (raw == null || raw.isEmpty) return;
    final next = Song.parse(raw, playedAt: DateTime.now());

    if (_current == null) {
      _current = next;
      // Avoid showing the current track twice if it's already at the top.
      if (_history.isNotEmpty && _history.first.sameTrack(next)) {
        _history.removeAt(0);
      }
      _updateArt();
      _handler.updateNowPlaying(next, artUri: _currentArt);
      _emitChanged();
      return;
    }

    if (!_current!.sameTrack(next)) {
      // The previous track just finished — push it onto the history.
      _history.insert(0, _current!);
      _current = next;
      _updateArt();
      _handler.updateNowPlaying(next, artUri: _currentArt);
      _emitChanged();
    }
  }

  Future<String?> _fetchSong() async {
    try {
      final res =
          await _client.get(Uri.parse(_songUrl)).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      return res.body.trim();
    } catch (_) {
      return null;
    }
  }

  /// Best-effort fetch of the current programme image for use as artwork.
  Future<void> _updateArt() async {
    try {
      final res = await _client
          .get(Uri.parse(_currentProgramUrl))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final m = RegExp(r'src="([^"]+)"').firstMatch(res.body);
      if (m != null) _currentArt = Uri.tryParse(m.group(1)!);
    } catch (_) {
      // Keep whatever art we had (or the default).
    }
  }

  String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&apos;', "'")
      .trim();
}
