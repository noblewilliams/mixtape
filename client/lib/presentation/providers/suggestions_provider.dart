import 'package:flutter_timezone/flutter_timezone.dart';
import 'device_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/suggestions/suggestions_api.dart';
import 'auth_provider.dart';

final suggestionsApiProvider = Provider<SuggestionsApi>((ref) {
  ref.watch(authProvider);
  return SuggestionsApi(ref.watch(apiClientProvider));
});

// A missing zone must not become an invented routine in UTC.
final suggestionTimeZoneProvider = Provider<TimeZoneReader>(
  (ref) => () async {
    final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
    if (zone.isEmpty) throw StateError('Time zone unavailable');
    return zone;
  },
);
