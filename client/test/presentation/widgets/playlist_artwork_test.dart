import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/playlist_artwork.dart';

void main() {
  test('expands Apple artwork templates at the requested size', () {
    expect(
      playlistArtworkUrl(
        'https://is1-ssl.mzstatic.com/image/thumb/Music/{w}x{h}.{f}',
        size: 240,
      ),
      'https://is1-ssl.mzstatic.com/image/thumb/Music/240x240.jpg',
    );
  });

  test('rejects non-https artwork and parses the stored background color', () {
    expect(playlistArtworkUrl('http://example.com/cover.jpg'), isNull);
    expect(playlistArtworkColor('544451'), const Color(0xFF544451));
    expect(playlistArtworkColor('#544451'), isNull);
  });

  testWidgets('the artwork exposes one image semantic', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaylistArtwork(urlTemplate: null, bgColor: '544451'),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Playlist artwork'), findsOneWidget);
  });
}
