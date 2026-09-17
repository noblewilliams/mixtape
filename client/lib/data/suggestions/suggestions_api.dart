import 'dart:convert';
import '../api/api_client.dart';

class RoutineSuggestion {
  const RoutineSuggestion({
    required this.id,
    required this.title,
    required this.reason,
  });
  final String id, title, reason;
  factory RoutineSuggestion.fromJson(Map<String, dynamic> json) =>
      RoutineSuggestion(
        id: json['id'] as String,
        title: json['title'] as String,
        reason: json['reason'] as String,
      );
}

class SuggestionsData {
  const SuggestionsData({
    required this.enabled,
    required this.dismissed,
    this.suggestion,
  });
  final bool enabled, dismissed;
  final RoutineSuggestion? suggestion;
  factory SuggestionsData.fromJson(Map<String, dynamic> json) =>
      SuggestionsData(
        enabled: json['enabled'] as bool,
        dismissed: json['dismissed'] as bool,
        suggestion: json['suggestion'] == null
            ? null
            : RoutineSuggestion.fromJson(
                json['suggestion'] as Map<String, dynamic>,
              ),
      );
}

class SuggestionsApi {
  SuggestionsApi(this._client);
  final ApiClient _client;
  Future<SuggestionsData> load(String zone) async => SuggestionsData.fromJson(
    jsonDecode(
          (await _client.getJson(
            '/suggestions?timeZone=${Uri.encodeComponent(zone)}',
          )).body,
        )
        as Map<String, dynamic>,
  );
  Future<String> select(String id, String zone) async =>
      (jsonDecode(
                (await _client.postJson('/suggestions/select', {
                  'id': id,
                  'timeZone': zone,
                })).body,
              )
              as Map<String, dynamic>)['prompt']
          as String;
  Future<void> dismiss(String id, String zone) async {
    await _client.postJson('/suggestions/dismiss', {
      'id': id,
      'timeZone': zone,
    });
  }

  Future<void> save(bool enabled) async {
    await _client.postJson('/suggestions/preferences', {'enabled': enabled});
  }
}
