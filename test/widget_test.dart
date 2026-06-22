import 'package:flutter_test/flutter_test.dart';
import 'package:stadtfilter/models/song.dart';

void main() {
  group('Song.parse', () {
    test('splits on the first " - " separator', () {
      final s = Song.parse('Indigo De Souza - Take Off Ur Pants');
      expect(s.artist, 'Indigo De Souza');
      expect(s.title, 'Take Off Ur Pants');
    });

    test('keeps later " - " inside the title', () {
      final s = Song.parse('A - B - C');
      expect(s.artist, 'A');
      expect(s.title, 'B - C');
    });

    test('falls back to title-only when there is no separator', () {
      final s = Song.parse('Just A Title');
      expect(s.artist, '');
      expect(s.title, 'Just A Title');
    });

    test('sameTrack compares artist and title', () {
      const a = Song(artist: 'X', title: 'Y');
      const b = Song(artist: 'X', title: 'Y');
      const c = Song(artist: 'X', title: 'Z');
      expect(a.sameTrack(b), isTrue);
      expect(a.sameTrack(c), isFalse);
    });
  });
}
