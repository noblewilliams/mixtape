import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';

void main() {
  test('session accepts a persisted case colour and older summaries', () {
    final json = <String, dynamic>{
      'id': 'mix',
      'title': 'Morning',
      'status': 'active',
      'queueVersion': 0,
      'updatedAt': '2026-09-25T00:00:00Z',
    };
    expect(
      DjSession.fromJson({...json, 'caseColor': '#88c9b3'}).caseColor,
      '#88c9b3',
    );
    expect(DjSession.fromJson(json).caseColor, isNull);
  });
}
