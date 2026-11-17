import 'dart:async';

import 'package:mixtape/presentation/widgets/foundation/idea_marquee.dart';

/// Runs before every test file. Home's idea row drifts forever, which would
/// keep `pumpAndSettle` from ever settling; tests see it as a still row
/// unless one turns the drift back on.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  IdeaMarquee.animate = false;
  await testMain();
}
