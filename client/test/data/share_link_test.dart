import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/core/config.dart';
import 'package:mixtape/data/share/share_link.dart';

const _token = 'AbCdEfGhIjKlMnOpQrStUv';
const _base = 'https://miixtape.netlify.app';

void main() {
  group('shareUrlFor', () {
    test('builds the share URL from the configured base', () {
      expect(shareUrlFor(_token), '${AppConfig.shareBaseUrl}/m/$_token');
    });

    test('tolerates a base with a trailing slash', () {
      expect(shareUrlFor(_token, base: '$_base/'), '$_base/m/$_token');
    });
  });

  group('shareTokenFrom', () {
    String? parse(String url) => shareTokenFrom(Uri.parse(url), base: _base);

    test('the default base is the configured one', () {
      expect(
        shareTokenFrom(Uri.parse('${AppConfig.shareBaseUrl}/m/$_token')),
        _token,
      );
    });

    test('accepts the share host and path', () {
      expect(parse('$_base/m/$_token'), _token);
    });

    test('accepts a trailing slash', () {
      expect(parse('$_base/m/$_token/'), _token);
    });

    test('accepts any query (and a fragment)', () {
      expect(parse('$_base/m/$_token?utm_source=imessage&x=1'), _token);
      expect(parse('$_base/m/$_token/?a=b#c'), _token);
    });

    test('rejects another host', () {
      expect(parse('https://example.com/m/$_token'), isNull);
      expect(parse('https://evil.miixtape.netlify.app/m/$_token'), isNull);
    });

    test('rejects http', () {
      expect(parse('http://miixtape.netlify.app/m/$_token'), isNull);
    });

    test('rejects a token of the wrong length or alphabet', () {
      expect(parse('$_base/m/${_token.substring(1)}'), isNull);
      expect(parse('$_base/m/${_token}A'), isNull);
      expect(parse('$_base/m/AbCdEfGhIjKlMnOpQrSt-_'), isNull);
    });

    test('rejects extra or missing segments', () {
      expect(parse('$_base/m/$_token/extra'), isNull);
      expect(parse('$_base/x/m/$_token'), isNull);
      expect(parse('$_base/m'), isNull);
      expect(parse('$_base/m/'), isNull);
      expect(parse('$_base/$_token'), isNull);
      expect(parse('$_base/m//$_token'), isNull);
    });

    test('rejects another port or user info', () {
      expect(parse('https://miixtape.netlify.app:8443/m/$_token'), isNull);
      expect(parse('https://a@miixtape.netlify.app/m/$_token'), isNull);
    });
  });
}
