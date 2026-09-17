import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/history/mix_history_api.dart';
import 'auth_provider.dart';

final mixHistoryApiProvider = Provider<MixHistoryApi>((ref) {
  ref.watch(authProvider);
  return MixHistoryApi(ref.watch(apiClientProvider));
});

