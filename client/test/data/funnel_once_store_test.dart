import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';

void main() {
  test('a milestone reads back only for the account that reached it, per type', () async {
    final store = InMemoryFunnelOnceStore();
    expect(await store.has('a', FunnelEventType.firstOutput), isFalse);

    await store.mark('a', FunnelEventType.firstOutput);
    expect(await store.has('a', FunnelEventType.firstOutput), isTrue);
    expect(await store.has('a', FunnelEventType.firstPersonalMix), isFalse);
    expect(await store.has('b', FunnelEventType.firstOutput), isFalse);

    // Unlike the service flag, two accounts on one device keep their own.
    await store.mark('b', FunnelEventType.firstPersonalMix);
    expect(await store.has('a', FunnelEventType.firstOutput), isTrue);
    expect(await store.has('b', FunnelEventType.firstPersonalMix), isTrue);

    await store.clear();
    expect(await store.has('a', FunnelEventType.firstOutput), isFalse);
    expect(await store.has('b', FunnelEventType.firstPersonalMix), isFalse);
  });

  test('the keychain key is funnel:<type>:<userId>', () {
    expect(funnelOnceKey(FunnelEventType.firstOutput, 'user-1'), 'funnel:first_output:user-1');
    expect(
      funnelOnceKey(FunnelEventType.firstPersonalMix, 'x:y'),
      'funnel:first_personal_mix:x:y',
    );
    expect(isFunnelOnceKey('funnel:first_output:user-1'), isTrue);
    expect(isFunnelOnceKey('service_chosen'), isFalse);
  });
}
