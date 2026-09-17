import 'dart:async';

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
