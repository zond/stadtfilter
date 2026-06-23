import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import 'models/song.dart';

/// The live MP3 stream, served by our relay (see the `relay/` directory).
///
/// The relay fetches the origin (`streamer.stadtfilter.net`) with a browser
/// User-Agent — which the origin requires — and re-serves the bytes to anyone.
/// That means the app can play this URL natively: no per-request User-Agent,
/// no just_audio proxy, and speakers can fetch it directly when casting.
const String kStreamUrl = 'http://micro.oort.se:8080/';

/// Station logo used as default media artwork (shown on the lock screen,
/// notification and Android Auto).
final Uri kDefaultArtUri =
    Uri.parse('https://prg.stadtfilter.net/prgimages/musikagogo1.png');

/// Wraps [AudioPlayer] (just_audio) in an [AudioHandler] so playback is
/// controlled through the system media session: notification, lock screen,
/// headset/steering-wheel buttons and Android Auto.
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  // The relay serves a plain stream, so the player connects natively (no
  // User-Agent / proxy needed). The load control starts playback after a short
  // buffer rather than building a large one first, to keep startup snappy.
  final AudioPlayer _player = AudioPlayer(
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
    _player.playbackEventStream.listen((_) => _emitState(), onError: (_, _) {
      _emitState();
    });
  }

  /// Whether the user currently wants playback. The button/notification reflect
  /// this intent immediately, so taps feel instant even when the stream is
  /// stalling and the player isn't emitting timely state events.
  bool _wantPlaying = false;

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
    if (_casting) return onCastPlay?.call() ?? Future.value();
    _wantPlaying = true;
    _emitState(); // instant: pause icon + buffering spinner
    try {
      await _ensureSource();
      await _player.play();
    } catch (_) {
      // A failed connection (e.g. no network) leaves the source unloaded so
      // the next play attempt reconnects from scratch.
      _sourceLoaded = false;
      _wantPlaying = false;
      _emitState();
    }
  }

  @override
  Future<void> pause() async {
    if (_casting) return onCastPause?.call() ?? Future.value();
    // For a live stream, "pause" tears the connection down. A soft pause can
    // hang when the stream has stalled (there's nothing buffered to pause);
    // stopping releases the player and kills the HTTP connection immediately.
    // Resuming reconnects to live via [play] -> [_ensureSource].
    _wantPlaying = false;
    _sourceLoaded = false;
    _emitState(); // instant: play icon, no spinner
    await _player.stop();
  }

  @override
  Future<void> stop() async {
    if (_casting) return onCastPause?.call() ?? Future.value();
    await _player.stop();
    _sourceLoaded = false;
    await super.stop();
  }

  /// A live stream cannot seek; map seek to a no-op.
  @override
  Future<void> seek(Duration position) async {}

  // ---- Casting -------------------------------------------------------------
  // While casting to a speaker, the phone's own player is paused, but we still
  // report a *playing* state to audio_service. That keeps the media session
  // active so the notification/lock-screen controls (via [onCastPlay] /
  // [onCastPause]) and the phone's hardware volume buttons (via
  // [onCastAdjustVolume] / [onCastSetVolume]) drive the speaker.

  bool _casting = false;
  Future<void> Function()? onCastPlay;
  Future<void> Function()? onCastPause;

  /// Called when the hardware volume buttons are pressed while casting.
  /// [direction] is -1 (down), 0 or +1 (up).
  void Function(int direction)? onCastAdjustVolume;

  /// Called when the system sets an absolute remote volume (0–100).
  void Function(int volume)? onCastSetVolume;

  void setCasting({required bool active, required bool playing}) {
    _casting = active;
    if (active) {
      buffering.value = false;
      playbackState.add(playbackState.value.copyWith(
        controls: [if (playing) MediaControl.pause else MediaControl.play],
        systemActions: const {MediaAction.play, MediaAction.pause},
        androidCompactActionIndices: const [0],
        processingState: AudioProcessingState.ready,
        playing: playing,
      ));
    } else {
      // Resume reflecting the local player's real state.
      _emitState();
    }
  }

  /// Switches the media session between phone (local) volume and speaker
  /// (remote) volume, so the hardware volume buttons control whichever is
  /// actually playing.
  void setRemoteVolume({required bool active, int volume = 50}) {
    androidPlaybackInfo.add(active
        ? RemoteAndroidPlaybackInfo(
            volumeControlType: AndroidVolumeControlType.absolute,
            maxVolume: 100,
            volume: volume.clamp(0, 100),
          )
        : LocalAndroidPlaybackInfo());
  }

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) async {
    onCastAdjustVolume?.call(direction.index);
  }

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) async {
    onCastSetVolume?.call(volumeIndex);
  }

  /// True while we want to play but the player isn't producing audio yet.
  /// The phone UI uses this for its spinner. We deliberately do NOT report
  /// STATE_BUFFERING to the media session, because Android Auto renders that as
  /// a non-tappable spinner — keeping the session at a plain play/pause state
  /// means the Auto button stays tappable so a slow connect can be cancelled.
  final ValueNotifier<bool> buffering = ValueNotifier<bool>(false);

  void _emitState() {
    // While casting, the playback state is driven by [setCasting] instead.
    if (_casting) return;
    final ready = _player.processingState == ProcessingState.ready ||
        _player.processingState == ProcessingState.completed;
    buffering.value = _wantPlaying && !ready;
    playbackState.add(playbackState.value.copyWith(
      // Only play/pause — no stop button.
      controls: [if (_wantPlaying) MediaControl.pause else MediaControl.play],
      systemActions: const {MediaAction.play, MediaAction.pause},
      androidCompactActionIndices: const [0],
      // Always a settled play/pause state (never STATE_BUFFERING) so the Auto
      // button stays tappable while connecting.
      processingState: AudioProcessingState.ready,
      playing: _wantPlaying,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
  }

  AudioPlayer get player => _player;
}
