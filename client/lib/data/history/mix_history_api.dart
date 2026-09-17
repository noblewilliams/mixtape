import 'dart:convert';
import '../api/api_client.dart';

class MixHistoryApi {
  MixHistoryApi(this.client);
  final ApiClient client;
  Future<Map<String, dynamic>> list(String id, {int? before}) async =>
      jsonDecode(
            (await client.getJson(
              '/sessions/${Uri.encodeComponent(id)}/versions${before == null ? '' : '?before=$before'}',
            )).body,
          )
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> read(String id, int version) async =>
      jsonDecode(
            (await client.getJson(
              '/sessions/${Uri.encodeComponent(id)}/versions/$version',
            )).body,
          )
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> restore(
    String id,
    Map<String, dynamic> input,
  ) async =>
      jsonDecode(
            (await client.postJson(
              '/sessions/${Uri.encodeComponent(id)}/versions/restore',
              input,
            )).body,
          )
          as Map<String, dynamic>;
}
