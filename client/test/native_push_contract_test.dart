import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/push/push_service.dart';

void main() {
  final push = File('ios/Runner/PushChannel.swift').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final project = File(
    'ios/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();

  test('the channel speaks the mixtape/push contract', () {
    expect(push, contains('"${MethodPushChannel.channelName}"'));
    for (final method in [
      'status',
      'requestAuthorization',
      'register',
      'appVersion',
      'environment',
      'setVisibleSession',
      'initialTap',
      'onTap',
    ]) {
      expect(push, contains('"$method"'), reason: '$method is handled');
    }
    for (final status in PushStatus.values) {
      expect(push, contains('"${status.name}"'));
    }
  });

  test('the token callbacks reach the channel', () {
    expect(
      appDelegate,
      contains('didRegisterForRemoteNotificationsWithDeviceToken'),
    );
    expect(
      appDelegate,
      contains('didFailToRegisterForRemoteNotificationsWithError'),
    );
    expect(appDelegate, contains('pushChannel.'));
  });

  test('the delegate is chained, never replaced', () {
    // Installed before launch finishes (a cold-start tap goes to whatever
    // delegate is set then), and re-chained once the plugins registered.
    expect(appDelegate, contains('pushChannel.install('));
    expect(push, contains('forwardingTarget(for'));
    expect(push, contains('UNPushNotificationTrigger'));
  });

  test('foreground: only our push is presented, nothing else is forwarded', () {
    // Before the proxy there was no delegate, so iOS presented no local
    // notification in the foreground. willPresent keeps that: it never
    // forwards to the plugin, whose defaults would show a banner.
    final start = push.indexOf('willPresent notification: UNNotification');
    final end = push.indexOf('didReceive response: UNNotificationResponse');
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final willPresent = push.substring(start, end);
    expect(willPresent, isNot(contains('forwardTarget')));
    expect(willPresent, contains('completionHandler([])'));
    final didReceive = push.substring(end);
    expect(didReceive, contains('forwardTarget?.userNotificationCenter?('));
  });

  test('PushChannel.swift is in the Runner target', () {
    expect(project, contains('PushChannel.swift in Sources'));
    expect(
      RegExp(
        r'PushChannel\.swift \*/ = \{isa = PBXFileReference',
      ).hasMatch(project),
      isTrue,
    );
  });

  // One entitlements file for every configuration, at `development`: Xcode
  // rewrites aps-environment to production when it exports for the App
  // Store / TestFlight, and a separate production file would fail to sign
  // against the automatic development profile used for archiving.
  test('aps-environment: one development file for every configuration', () {
    final entitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(
      entitlements,
      contains('<key>aps-environment</key>\n\t<string>development</string>'),
    );
    expect(entitlements, contains('com.apple.developer.applesignin'));
    expect(entitlements, contains('applinks:miixtape.netlify.app'));
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'
          .allMatches(project)
          .length,
      3,
    );
    expect(project, isNot(contains('RunnerRelease.entitlements')));
  });
}
