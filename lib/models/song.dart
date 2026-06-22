/// A single track, either currently playing or previously played.
class Song {
  final String artist;
  final String title;

  /// When the track started playing, if known. Seeded entries from the
  /// trackservice carry a real timestamp; live-detected changes are stamped
  /// with the moment the change was observed.
  final DateTime? playedAt;

  const Song({required this.artist, required this.title, this.playedAt});

  /// Parses a raw `"Artist - Title"` string. If there is no ` - ` separator
  /// the whole string becomes the title and the artist is left empty.
  factory Song.parse(String raw, {DateTime? playedAt}) {
    final text = raw.trim();
    final idx = text.indexOf(' - ');
    if (idx < 0) {
      return Song(artist: '', title: text, playedAt: playedAt);
    }
    return Song(
      artist: text.substring(0, idx).trim(),
      title: text.substring(idx + 3).trim(),
      playedAt: playedAt,
    );
  }

  /// A display string for the artist/title pair.
  String get display => artist.isEmpty ? title : '$artist - $title';

  bool sameTrack(Song other) =>
      artist == other.artist && title == other.title;

  @override
  String toString() => display;
}
