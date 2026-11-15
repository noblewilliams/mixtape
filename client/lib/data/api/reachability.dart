/// Whether the internet answers at all, asked of somewhere other than
/// Mixtape: a timeout or DNS failure on our own API cannot tell "this phone
/// is offline" from "our server is down", and a phone on captive-portal or
/// dead Wi-Fi still reports a network interface as up.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// True when the internet answers.
typedef ReachabilityProbe = Future<bool> Function();

/// Apple's own connectivity check: a fixed page whose body is "Success".
/// A captive portal answers with its sign-in page instead, and no internet
/// answers with nothing, so only the real page counts. Nothing about the
/// listener is sent.
final Uri reachabilityUrl = Uri.parse(
  'https://www.apple.com/library/test/success.html',
);

/// The real probe: a single GET, given [timeout] in all.
Future<bool> probeInternet({
  Duration timeout = const Duration(seconds: 3),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await () async {
      final request = await client.getUrl(reachabilityUrl);
      request.followRedirects = false;
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 && body.contains('Success');
    }().timeout(timeout);
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
