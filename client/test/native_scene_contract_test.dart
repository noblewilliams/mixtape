// iOS 27 traps at launch any app built with its SDK that has not adopted the
// UIScene lifecycle (1.1.0 (7), the first Xcode 27 build, died on open). These
// pin the adoption: the scene manifest, registration on the implicit engine
// (there is no window or root view controller at didFinishLaunching under
// scenes), and the scene paths that now carry a cold-start or warm ZIP.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

  test('Info.plist declares one Flutter window scene from Main', () {
    final manifest = RegExp(
      r'<key>UIApplicationSceneManifest</key>\s*<dict>([\s\S]*?)\n\t</dict>',
    ).firstMatch(plist);
    expect(manifest, isNotNull, reason: 'no UIApplicationSceneManifest');
    final body = manifest!.group(1)!;
    expect(
      body,
      matches(
        RegExp(r'<key>UIApplicationSupportsMultipleScenes</key>\s*<false/>'),
      ),
    );
    expect(body, contains('<key>UIWindowSceneSessionRoleApplication</key>'));
    expect(
      body,
      matches(
        RegExp(
          r'<key>UISceneDelegateClassName</key>\s*'
          r'<string>FlutterSceneDelegate</string>',
        ),
      ),
    );
    expect(
      body,
      matches(RegExp(r'<key>UISceneStoryboardFile</key>\s*<string>Main</string>')),
    );
  });

  test('channels, platform views and plugins register on the implicit engine', () {
    expect(appDelegate, contains('FlutterImplicitEngineDelegate'));
    expect(appDelegate, contains('func didInitializeImplicitFlutterEngine('));
    expect(
      appDelegate,
      contains('GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)'),
    );
    // Nothing may reach for the window's root view controller at launch:
    // under scenes there is no window yet.
    expect(appDelegate, isNot(contains('window?.rootViewController')));
  });

  test('ZIPs arrive through the scene: cold start and while running', () {
    expect(appDelegate, contains('FlutterSceneLifeCycleDelegate'));
    expect(appDelegate, contains('addSceneDelegate('));
    expect(appDelegate, contains('connectionOptions?.urlContexts'));
    expect(appDelegate, contains('openURLContexts URLContexts'));
    // Only file URLs are ours; links stay with app_links and Google.
    expect(appDelegate, contains('isFileURL'));
  });

  test('the dock is installed on the scene window once it connects', () {
    expect(appDelegate, contains('@objc(scene:willConnectToSession:options:)'));
    expect(appDelegate, contains('FlutterSceneDelegate)?.window'));
  });
}
