// Names and status labels for connected sources, driven by which packages
// actually landed (`MusicSource.packages`): a source row alone proves
// nothing. Same rules as the web's `lib/onboarding.ts`.
import '../../data/listening/listening_models.dart';

const String extendedPackage = 'spotify_extended';
const String accountPackage = 'spotify_account';

class SpotifyPackages {
  const SpotifyPackages({required this.extended, required this.account});

  final bool extended;
  final bool account;

  int get count => (extended ? 1 : 0) + (account ? 1 : 0);
}

MusicSource? spotifySource(OnboardingState onboarding) {
  for (final source in onboarding.sources) {
    if (source.source == 'spotify_export') return source;
  }
  return null;
}

SpotifyPackages spotifyPackages(OnboardingState onboarding) => packagesOf(spotifySource(onboarding));

SpotifyPackages packagesOf(MusicSource? source) {
  final packages = source?.packages ?? const [];
  return SpotifyPackages(
    extended: packages.contains(extendedPackage),
    account: packages.contains(accountPackage),
  );
}

/// The waiting card's chip and the sources row's status.
String spotifyStatusLabel(OnboardingState onboarding) {
  final packages = spotifyPackages(onboarding);
  if (packages.count == 2) return 'Both in';
  if (packages.count == 1) return '1 of 2 in';
  return onboarding.markedRequestedAt != null ? 'Waiting' : 'Not requested';
}

String sourceName(MusicSource source) {
  switch (source.source) {
    case 'spotify_export':
      final packages = packagesOf(source);
      if (packages.extended && packages.account) return 'Spotify · both packages';
      if (packages.extended) return 'Spotify · extended history';
      if (packages.account) return 'Spotify · account data';
      return 'Spotify';
    case 'apple_live':
      return 'Apple Music';
    case 'apple_export':
      return 'Apple Music · export';
    default:
      return source.source;
  }
}
