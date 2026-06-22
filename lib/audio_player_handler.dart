import 'package:audio_service/audio_service.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import 'models/song.dart';

/// The live MP3 stream of Radio Stadtfilter.
const String kStreamUrl = 'https://streamer.stadtfilter.net/stadtfilter.mp3';

/// The stream server only serves data to browser-like clients — requests with
/// the default Android/ExoPlayer User-Agent are accepted but never sent any
/// bytes (the player hangs in "loading"). A browser UA makes it stream.
const String kStreamUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/148.0.0.0 Mobile Safari/537.36';

/// Station logo used as default media artwork (shown on the lock screen,
/// notification and Android Auto).
final Uri kDefaultArtUri =
    Uri.parse('https://prg.stadtfilter.net/prgimages/musikagogo1.png');

/// Wraps [AudioPlayer] (just_audio) in an [AudioHandler] so playback is
/// controlled through the system media session: notification, lock screen,
/// headset/steering-wheel buttons and Android Auto.
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  // The stream server only answers browser-like clients, and it does NOT
  // respond to media3's native HttpURLConnection request at all (it hangs).
  // just_audio's request-header proxy uses Dart's HttpClient, which the server
  // *does* answer, so we route through it (the default) and let it carry our
  // browser User-Agent. The load control starts playback after a short buffer
  // rather than building a large one first, to keep startup snappy.
  final AudioPlayer _player = AudioPlayer(
    userAgent: kStreamUserAgent,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 5),
        maxBufferDuration: Duration(seconds: 30),
        bufferForPlaybackDuration: Duration(milliseconds: 1500),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
      ),
    ),
  );

  AudioPlayerHandler() {
    // Publish a sensible initial MediaItem so something shows before the
    // first metadata poll completes.
    mediaItem.add(_liveItem(const Song(artist: 'Radio Stadtfilter', title: 'Live')));
    _player.playbackEventStream.listen(_broadcastState, onError: (Object e, _) {
      // Surface fatal errors as an idle/errored state instead of crashing.
      _broadcastState(_player.playbackEvent);
    });
  }

  /// Whether the live stream has been wired up to the player yet. We load
  /// lazily on the first [play] so a stale buffered connection is never torn
  /// down and re-created (which manifests as a "Source error").
  bool _sourceLoaded = false;

  Future<void> _ensureSource() async {
    if (_sourceLoaded) return;
    await _player.setAudioSource(AudioSource.uri(Uri.parse(kStreamUrl)));
    _sourceLoaded = true;
  }

  MediaItem _liveItem(Song song) => MediaItem(
        id: kStreamUrl,
        title: song.title,
        artist: song.artist.isEmpty ? 'Radio Stadtfilter' : song.artist,
        album: 'Radio Stadtfilter',
        isLive: true,
        artUri: kDefaultArtUri,
        playable: true,
      );

  /// Called by the metadata service whenever the now-playing track changes.
  void updateNowPlaying(Song song, {Uri? artUri}) {
    final current = mediaItem.value;
    mediaItem.add(_liveItem(song).copyWith(artUri: artUri ?? current?.artUri));
  }

  // ---- Android Auto: now-playing queue + minimal browse -------------------
  // The recently-played songs are surfaced as the media session *queue*, which
  // Android Auto shows as a track list on the now-playing screen (via the
  // playlist icon) rather than as a separate browse view. The browse tree is
  // trimmed to a single "Live" entry, which Android Auto requires as the root.

  static const Song _liveSong = Song(title: 'Live', artist: '');

  MediaItem get _liveBrowseItem =>
      (mediaItem.value ?? _liveItem(_liveSong)).copyWith(displaySubtitle: 'Live');

  /// Pushed by the metadata service whenever the now-playing / history changes.
  void updateHistory(List<Song> history) {
    // Queue = the live stream (index 0, the active item) followed by the
    // recently-played tracks, newest first.
    queue.add([_liveBrowseItem, ...history.map(_historyItem)]);
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    switch (parentMediaId) {
      case AudioService.browsableRootId:
      case AudioService.recentRootId:
        return [_liveBrowseItem];
      default:
        return const [];
    }
  }

  /// A live stream can't jump to a past track; tapping a queue entry just
  /// keeps the live stream playing.
  @override
  Future<void> skipToQueueItem(int index) => play();

  MediaItem _historyItem(Song song) {
    final time = song.playedAt == null
        ? ''
        : DateFormat('HH:mm').format(song.playedAt!);
    final subtitle = [if (song.artist.isNotEmpty) song.artist, if (time.isNotEmpty) time]
        .join(' · ');
    return MediaItem(
      // A live stream item is not seekable/replayable; the id just needs to be
      // unique and stable enough for the list.
      id: 'history:${song.playedAt?.millisecondsSinceEpoch ?? 0}:${song.title}',
      title: song.title.isEmpty ? song.display : song.title,
      artist: song.artist,
      displaySubtitle: subtitle.isEmpty ? null : subtitle,
      artUri: kDefaultArtUri,
      playable: true,
    );
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async => mediaItem.value;

  @override
  Future<void> playFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      play();

  @override
  Future<void> playMediaItem(MediaItem mediaItem) => play();

  @override
  Future<void> play() async {
    try {
      await _ensureSource();
      await _player.play();
    } catch (_) {
      // A failed connection (e.g. no network) leaves the source unloaded so
      // the next play attempt reconnects from scratch.
      _sourceLoaded = false;
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _sourceLoaded = false;
    await super.stop();
  }

  /// A live stream cannot seek; map seek to a no-op.
  @override
  Future<void> seek(Duration position) async {}

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      // Only play/pause — no stop button.
      controls: [if (playing) MediaControl.pause else MediaControl.play],
      systemActions: const {MediaAction.play, MediaAction.pause},
      androidCompactActionIndices: const [0],
      // Never report `idle`: a live stream that hasn't been tapped yet is
      // "ready to play", not stopped. Reporting an active session makes
      // Android Auto open straight to the now-playing screen instead of the
      // (single-item) browse list.
      processingState: const {
        ProcessingState.idle: AudioProcessingState.ready,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.ready,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
  }

  AudioPlayer get player => _player;
}
