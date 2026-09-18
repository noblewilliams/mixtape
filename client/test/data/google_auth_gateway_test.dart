import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';

class FakeGoogleSdk implements GoogleNativeSdk {
  int initialized = 0;
  int requests = 0;
  String? client;
  String? audience;
  Future<String?> Function()? onToken;
  @override
  Future<void> initialize({
    required String clientId,
    required String serverClientId,
  }) async {
    initialized++;
    client = clientId;
    audience = serverClientId;
  }

  @override
  Future<String?> authenticateIdentityToken() async {
    requests++;
    return onToken == null ? 'google-identity' : onToken!();
  }
}

const configured = GoogleAuthConfiguration(
  iosClientId: 'ios.apps.googleusercontent.com',
  serverClientId: 'server.apps.googleusercontent.com',
  callbackConfigured: true,
);

void main() {
  // Diagnosis 2026-09-18: the commonest native Google failure is a build run
  // without `--dart-define-from-file=config/google-ios.json`. These tests pin
  // both halves of that contract: the defines the gateway reads, and the file
  // and Info.plist that supply them.
  group('build-time configuration', () {
    test('a build with no dart-defines reports no configuration at all', () {
      // This suite runs without defines, so the defaults are the empty
      // environment — exactly what a plain `flutter run` compiles in.
      const config = GoogleAuthConfiguration();
      expect(config.iosClientId, isEmpty);
      expect(config.serverClientId, isEmpty);
      expect(config.callbackConfigured, isFalse);
      expect(config.isConfigured, isFalse);
      expect(
        RealGoogleAuthGateway(
          configuration: config,
          supportedPlatform: true,
        ).isAvailable,
        isFalse,
      );
    });

    test('config/google-ios.json carries all three defines as strings', () {
      final file = File('config/google-ios.json');
      expect(file.existsSync(), isTrue, reason: 'the define file must exist');
      final values = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      expect(values['GOOGLE_IOS_CLIENT_ID'], isA<String>());
      expect(values['GOOGLE_SERVER_CLIENT_ID'], isA<String>());
      // `bool.fromEnvironment` reads the literal string, so only 'true' arms
      // the callback flag.
      expect(values['GOOGLE_IOS_CALLBACK_CONFIGURED'], 'true');
      expect(
        GoogleAuthConfiguration(
          iosClientId: values['GOOGLE_IOS_CLIENT_ID']! as String,
          serverClientId: values['GOOGLE_SERVER_CLIENT_ID']! as String,
          callbackConfigured:
              values['GOOGLE_IOS_CALLBACK_CONFIGURED'] == 'true',
        ).isConfigured,
        isTrue,
      );
    });

    test('Info.plist registers the reversed iOS client id as a URL scheme', () {
      final ios =
          (jsonDecode(File('config/google-ios.json').readAsStringSync())
                  as Map)['GOOGLE_IOS_CLIENT_ID']
              as String;
      const suffix = '.apps.googleusercontent.com';
      expect(ios, endsWith(suffix));
      final scheme =
          'com.googleusercontent.apps.'
          '${ios.substring(0, ios.length - suffix.length)}';
      expect(
        File('ios/Runner/Info.plist').readAsStringSync(),
        contains('<string>$scheme</string>'),
      );
    });
  });

  test(
    'missing public configuration is unavailable before calling the SDK',
    () async {
      final sdk = FakeGoogleSdk();
      final gateway = RealGoogleAuthGateway(sdk: sdk, supportedPlatform: true);
      expect(gateway.isAvailable, false);
      await expectLater(
        gateway.getIdentityToken(),
        throwsA(isA<GoogleSignInUnavailable>()),
      );
      expect(sdk.initialized, 0);
      expect(sdk.requests, 0);
    },
  );
  test('iOS callback setup and supported platform are required', () {
    expect(
      RealGoogleAuthGateway(
        configuration: configured,
        supportedPlatform: false,
      ).isAvailable,
      false,
    );
    expect(
      RealGoogleAuthGateway(
        configuration: const GoogleAuthConfiguration(
          iosClientId: 'ios',
          serverClientId: 'server',
        ),
        supportedPlatform: true,
      ).isAvailable,
      false,
    );
  });
  test(
    'initializes with backend audience once and returns verified SDK token',
    () async {
      final sdk = FakeGoogleSdk();
      final gateway = RealGoogleAuthGateway(
        sdk: sdk,
        configuration: configured,
        supportedPlatform: true,
      );
      expect(await gateway.getIdentityToken(), 'google-identity');
      expect(await gateway.getIdentityToken(), 'google-identity');
      expect(sdk.initialized, 1);
      expect(sdk.client, configured.iosClientId);
      expect(sdk.audience, configured.serverClientId);
      expect(sdk.requests, 2);
    },
  );
  test(
    'maps cancellation quietly and does not expose provider diagnostics',
    () async {
      final sdk = FakeGoogleSdk()
        ..onToken = () async => throw const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
          description: 'private-sentinel',
        );
      final gateway = RealGoogleAuthGateway(
        sdk: sdk,
        configuration: configured,
        supportedPlatform: true,
      );
      await expectLater(
        gateway.getIdentityToken(),
        throwsA(isA<GoogleSignInCancelled>()),
      );
      sdk.onToken = () async => throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
        details: 'private-sentinel',
      );
      await expectLater(
        gateway.getIdentityToken(),
        throwsA(
          isA<GoogleSignInFailed>().having(
            (e) => e.toString(),
            'safe description',
            isNot(contains('private-sentinel')),
          ),
        ),
      );
    },
  );
  test(
    'missing ID token fails and parallel native sheets are rejected',
    () async {
      final pending = Completer<String?>();
      final sdk = FakeGoogleSdk()..onToken = () => pending.future;
      final gateway = RealGoogleAuthGateway(
        sdk: sdk,
        configuration: configured,
        supportedPlatform: true,
      );
      final first = gateway.getIdentityToken();
      await expectLater(
        gateway.getIdentityToken(),
        throwsA(isA<GoogleSignInBusy>()),
      );
      pending.complete(null);
      await expectLater(first, throwsA(isA<GoogleSignInFailed>()));
      expect(sdk.requests, 1);
    },
  );
}
