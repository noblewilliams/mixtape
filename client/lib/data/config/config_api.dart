import 'dart:convert';

import '../api/api_client.dart';

/// The server flags the first run needs before any session exists, from the
/// unauthenticated `GET /health` (`{ ok, service, neverRefuse }`: no session,
/// no database).
class FirstRunFlags {
  const FirstRunFlags({required this.neverRefuse});

  static const FirstRunFlags off = FirstRunFlags(neverRefuse: false);

  /// `NEVER_REFUSE`: a listener with no music still gets a mix, so "Skip for
  /// now" can go straight to the prompt page.
  final bool neverRefuse;
}

class ConfigApi {
  const ConfigApi(this._client);

  final ApiClient _client;

  /// Never throws: any failure, a 404 included, reads as every flag off.
  Future<FirstRunFlags> flags() async {
    try {
      final value = jsonDecode((await _client.getJson('/health')).body);
      if (value is! Map<String, dynamic>) return FirstRunFlags.off;
      return FirstRunFlags(neverRefuse: value['neverRefuse'] == true);
    } catch (_) {
      return FirstRunFlags.off;
    }
  }
}
