import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'audio_player_handler.dart';
import 'cast/cast_controller.dart';
import 'metadata_service.dart';
import 'models/song.dart';

class HomeScreen extends StatelessWidget {
  final AudioPlayerHandler handler;
  final MetadataService metadata;
  final CastController cast;

  const HomeScreen({
    super.key,
    required this.handler,
    required this.metadata,
    required this.cast,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio Stadtfilter'),
        centerTitle: true,
        actions: [_CastButton(cast: cast)],
      ),
      body: Column(
        children: [
          _NowPlaying(handler: handler, metadata: metadata, cast: cast),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Vorher gespielt',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          Expanded(child: _History(metadata: metadata)),
        ],
      ),
    );
  }
}

class _CastButton extends StatelessWidget {
  final CastController cast;

  const _CastButton({required this.cast});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: cast,
      builder: (context, _) {
        return IconButton(
          tooltip: 'Auf Lautsprecher abspielen',
          icon: Icon(cast.isCasting ? Icons.cast_connected : Icons.cast),
          color: cast.isCasting ? Theme.of(context).colorScheme.primary : null,
          onPressed: () => showCastSheet(context, cast),
        );
      },
    );
  }
}

class _NowPlaying extends StatelessWidget {
  final AudioPlayerHandler handler;
  final MetadataService metadata;
  final CastController cast;

  const _NowPlaying({
    required this.handler,
    required this.metadata,
    required this.cast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        children: [
          // Current track text, driven by the metadata service.
          AnimatedBuilder(
            animation: metadata,
            builder: (context, _) {
              final song = metadata.current;
              return Column(
                children: [
                  Text(
                    song?.title ?? 'Live',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    song == null || song.artist.isEmpty
                        ? 'Radio Stadtfilter'
                        : song.artist,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          _PlayButton(handler: handler, cast: cast),
          _CastingBanner(cast: cast),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final AudioPlayerHandler handler;
  final CastController cast;

  const _PlayButton({required this.handler, required this.cast});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: cast,
      builder: (context, _) {
        // While casting, the button controls the speaker; otherwise the phone.
        if (cast.isCasting) {
          return _circleButton(
            context,
            icon: cast.deviceIsPlaying ? Icons.pause : Icons.play_arrow,
            onTap: cast.toggleDevicePlayPause,
          );
        }
        // Spinner comes from the handler's buffering signal (the media session
        // itself stays at a plain play/pause state for Android Auto's sake).
        return ValueListenableBuilder<bool>(
          valueListenable: handler.buffering,
          builder: (context, busy, _) => StreamBuilder<PlaybackState>(
            stream: handler.playbackState,
            builder: (context, snapshot) {
              final playing = snapshot.data?.playing ?? false;
              return _circleButton(
                context,
                icon: playing ? Icons.pause : Icons.play_arrow,
                busy: busy,
                onTap: () => playing ? handler.pause() : handler.play(),
              );
            },
          ),
        );
      },
    );
  }

  Widget _circleButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
    bool busy = false,
  }) {
    return SizedBox(
      width: 88,
      height: 88,
      child: Material(
        color: Theme.of(context).colorScheme.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          // Stay tappable while buffering so the user can always stop a stalled
          // stream; the spinner is just an overlay ring.
          onTap: onTap,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (busy)
                const SizedBox(
                  width: 78,
                  height: 78,
                  child: CircularProgressIndicator(
                      strokeWidth: 3, color: Colors.white70),
                ),
              Icon(icon, size: 52, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

class _CastingBanner extends StatelessWidget {
  final CastController cast;

  const _CastingBanner({required this.cast});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: cast,
      builder: (context, _) {
        if (!cast.isCasting) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cast_connected,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Über ${cast.device!.name}',
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: cast.disconnect,
                child: const Text('Trennen'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Bottom sheet that discovers speakers and lets the user pick one (or stop).
void showCastSheet(BuildContext context, CastController cast) {
  cast.discover();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => AnimatedBuilder(
      animation: cast,
      builder: (context, _) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Auf Lautsprecher abspielen',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    IconButton(
                      tooltip: 'Erneut suchen',
                      icon: cast.isDiscovering
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh),
                      onPressed: cast.isDiscovering ? null : cast.discover,
                    ),
                  ],
                ),
              ),
              if (cast.isCasting)
                ListTile(
                  leading: Icon(Icons.cast_connected,
                      color: Theme.of(context).colorScheme.primary),
                  title: Text(cast.device!.name),
                  subtitle: const Text('Verbunden'),
                  trailing: TextButton(
                    onPressed: () {
                      cast.disconnect();
                      Navigator.of(context).pop();
                    },
                    child: const Text('Trennen'),
                  ),
                ),
              if (cast.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(cast.error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (cast.isDiscovering && cast.devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('Suche Lautsprecher…')),
                ),
              for (final d in cast.devices)
                ListTile(
                  leading: const Icon(Icons.speaker),
                  title: Text(d.name),
                  selected: cast.device == d,
                  onTap: () {
                    cast.castTo(d);
                    Navigator.of(context).pop();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

class _History extends StatelessWidget {
  final MetadataService metadata;

  const _History({required this.metadata});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: metadata,
      builder: (context, _) {
        final songs = metadata.history;
        if (songs.isEmpty) {
          return const Center(child: Text('Noch keine Titel'));
        }
        return ListView.separated(
          itemCount: songs.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _HistoryTile(song: songs[i]),
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final Song song;

  const _HistoryTile({required this.song});

  @override
  Widget build(BuildContext context) {
    final time = song.playedAt == null
        ? null
        : DateFormat('HH:mm').format(song.playedAt!);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.music_note, size: 20),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: song.artist.isEmpty
          ? null
          : Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: time == null ? null : Text(time),
    );
  }
}
