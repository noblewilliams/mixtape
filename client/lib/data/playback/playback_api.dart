import 'dart:convert';
import '../api/api_client.dart';

class PlaybackApi {
  PlaybackApi(this.client);
  final ApiClient client;
  Future<Map<String, dynamic>> preferences() async =>
      jsonDecode((await client.getJson('/playback/preferences')).body)
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> save(bool enabled) async =>
      jsonDecode(
            (await client.putJson('/playback/preferences', {
              'enabled': enabled,
            })).body,
          )
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> clear(String id, int revision) async =>
      jsonDecode(
            (await client.postJson('/playback/clear', {
              'requestId': id,
              'revision': revision,
            })).body,
          )
          as Map<String, dynamic>;
  Future<void> send(int revision, List<Map<String, dynamic>> events) async {
    await client.postJson('/playback/events', {
      'revision': revision,
      'events': events,
    });
  }
}
