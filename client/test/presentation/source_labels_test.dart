import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/format/source_labels.dart';

import '../helpers/fake_listening_api.dart';

void main() {
  test('sourceName reads the packages that landed', () {
    expect(sourceName(musicSource(packages: ['spotify_account', 'spotify_extended'])),
        'Spotify · both packages');
    expect(sourceName(musicSource(packages: ['spotify_extended'])), 'Spotify · extended history');
    expect(sourceName(musicSource(packages: ['spotify_account'])), 'Spotify · account data');
    expect(sourceName(musicSource()), 'Spotify');
    expect(sourceName(musicSource(source: 'apple_live')), 'Apple Music');
    expect(sourceName(musicSource(source: 'apple_export')), 'Apple Music · export');
  });

  test('spotifyPackages counts what landed, from the Spotify row only', () {
    expect(spotifyPackages(onboardingState()).count, 0);
    expect(
      spotifyPackages(onboardingState(sources: [musicSource(source: 'apple_live', packages: ['x'])])).count,
      0,
    );
    final one = spotifyPackages(onboardingState(sources: [musicSource(packages: ['spotify_extended'])]));
    expect(one.extended, isTrue);
    expect(one.account, isFalse);
    expect(one.count, 1);
    final both = spotifyPackages(
      onboardingState(sources: [musicSource(packages: ['spotify_account', 'spotify_extended'])]),
    );
    expect(both.count, 2);
  });

  test('spotifyStatusLabel: Not requested, Waiting, 1 of 2 in, Both in', () {
    expect(spotifyStatusLabel(onboardingState(chosenService: 'spotify')), 'Not requested');
    expect(
      spotifyStatusLabel(onboardingState(chosenService: 'spotify', markedRequestedAt: DateTime(2026))),
      'Waiting',
    );
    expect(
      spotifyStatusLabel(onboardingState(sources: [musicSource(packages: ['spotify_account'])])),
      '1 of 2 in',
    );
    expect(
      spotifyStatusLabel(
        onboardingState(sources: [musicSource(packages: ['spotify_account', 'spotify_extended'])]),
      ),
      'Both in',
    );
  });
}
