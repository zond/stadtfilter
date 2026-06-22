import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'audio_player_handler.dart';
import 'metadata_service.dart';
import 'models/song.dart';

class HomeScreen extends StatelessWidget {
  final AudioPlayerHandler handler;
  final MetadataService metadata;

  const HomeScreen({super.key, required this.handler, required this.metadata});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio Stadtfilter'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          _NowPlaying(handler: handler, metadata: metadata),
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

class _NowPlaying extends StatelessWidget {
  final AudioPlayerHandler handler;
  final MetadataService metadata;

  const _NowPlaying({required this.handler, required this.metadata});

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
          _PlayButton(handler: handler),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final AudioPlayerHandler handler;

  const _PlayButton({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final processing = state?.processingState;
        final busy = processing == AudioProcessingState.loading ||
            processing == AudioProcessingState.buffering;

        return SizedBox(
          width: 88,
          height: 88,
          child: Material(
            color: Theme.of(context).colorScheme.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => playing ? handler.pause() : handler.play(),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(28),
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: Colors.white),
                    )
                  : Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      size: 52,
                      color: Colors.white,
                    ),
            ),
          ),
        );
      },
    );
  }
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
