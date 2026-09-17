import 'dart:convert';

import '../api/api_client.dart';

enum AccountProvider { apple, google }

class AccountModelException implements Exception {
  const AccountModelException();

  @override
  String toString() => 'Invalid account response';
}

class AccountApiException extends ApiException {
  AccountApiException(super.statusCode, super.body, this.code);

  final String? code;

  @override
  String toString() => 'AccountApiException($statusCode)';
}

class LinkedAccount {
  const LinkedAccount({
    required this.id,
    required this.accountId,
    required this.providerId,
  });

  factory LinkedAccount.fromJson(Map<String, dynamic> json) => LinkedAccount(
    id: _identifier(json['id']),
    accountId: _identifier(json['accountId']),
    providerId: _identifier(json['providerId']),
  );

  /// Better Auth's row identity, used for unlinking.
  final String id;

  /// The provider's subject identity, not the unlink target.
  final String accountId;
  final String providerId;
}

class AccountApi {
  const AccountApi(this._client);

  // The caller owns the authenticated client and refreshes canonical account
  // state after mutations, including responses whose outcome is uncertain.
  final ApiClient _client;

  Future<List<LinkedAccount>> list() async {
    final value = await _request(
      () async => (await _client.getJson('/api/auth/list-accounts')).body,
    );
    if (value is! List) throw const AccountModelException();
    return List<LinkedAccount>.unmodifiable(
      value.map((entry) => LinkedAccount.fromJson(_object(entry))),
    );
  }

  /// Explicit linking never signs in or replaces the existing session token.
  Future<void> link({
    required AccountProvider provider,
    required String token,
  }) async {
    _identifier(token);
    final value = _object(
      await _request(
        () async => (await _client.postJson('/api/auth/link-social', {
          'provider': provider.name,
          'idToken': {'token': token},
        })).body,
      ),
    );
    if (value['status'] != true || value['redirect'] != false) {
      throw const AccountModelException();
    }
  }

  Future<void> unlink(LinkedAccount account) async {
    final value = _object(
      await _request(
        () async => (await _client.postJson('/api/auth/unlink-account', {
          'accountId': _identifier(account.id),
        })).body,
      ),
    );
    if (value['status'] != true) throw const AccountModelException();
  }

  Future<Object?> _request(Future<String> Function() call) async {
    late String body;
    try {
      body = await call();
    } on ApiException catch (error) {
      String? code;
      try {
        final value = jsonDecode(error.body);
        if (value is Map<String, dynamic> && value['code'] is String) {
          code = value['code'] as String;
        }
      } on FormatException {
        // Keep the HTTP status even when the server returns a non-JSON error.
      }
      throw AccountApiException(error.statusCode, error.body, code);
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const AccountModelException();
    }
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) throw const AccountModelException();
  return value;
}

String _identifier(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const AccountModelException();
  }
  return value;
}
