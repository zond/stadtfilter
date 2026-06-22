import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'audio_player_handler.dart';
import 'home_screen.dart';
import 'metadata_service.dart';

late final AudioPlayerHandler audioHandler;
late final MetadataService metadataService;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'net.stadtfilter.stadtfilter.audio',
      androidNotificationChannelName: 'Radio Stadtfilter',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );

  metadataService = MetadataService(audioHandler);
  // Fire-and-forget; the UI listens for updates.
  metadataService.start();

  runApp(StadtfilterApp(
    handler: audioHandler,
    metadata: metadataService,
  ));
}

class StadtfilterApp extends StatelessWidget {
  final AudioPlayerHandler handler;
  final MetadataService metadata;

  const StadtfilterApp({
    super.key,
    required this.handler,
    required this.metadata,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radio Stadtfilter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE2001A), // Stadtfilter red
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(handler: handler, metadata: metadata),
    );
  }
}
