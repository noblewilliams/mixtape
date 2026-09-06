import 'dart:async';

import 'package:flutter/services.dart';

import 'musickit_bridge.dart';

enum PlaylistApplyOutcome { success, partial, unknown }

class PlaylistApplyReceipt {
  const PlaylistApplyReceipt({
    required this.operationId,
    required this.outcome,
    required this.added,
    required this.failed,
    this.appleLibraryId,
    this.resultingFingerprint,
  });

  final String operationId;
  final PlaylistApplyOutcome outcome;
  final String? appleLibraryId;
  final int added;
  final int failed;
  final String? resultingFingerprint;
}

/// Small, write-specific MusicKit boundary for applying a reviewed playlist
/// draft. Keeping it separate from [MusicKitBridge] prevents ordinary playback
/// and read-only library fakes from gaining mutation responsibilities.
class PlaylistApplyBridge {
  PlaylistApplyBridge({Duration callTimeout = const Duration(minutes: 3)})
    : _callTimeout = callTimeout;

  static const _channel = MethodChannel('mixtape/musickit');
  static final _opaqueId = RegExp(r'^[A-Za-z0-9._~-]{1,512}$');
  static final _catalogId = RegExp(r'^[A-Za-z0-9._~-]{1,128}$');
  static final _fingerprint = RegExp(r'^[0-9a-f]{64}$');
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final Duration _callTimeout;

  Future<String> fetchPlaylistFingerprint(String appleLibraryId) async {
    if (!_opaqueId.hasMatch(appleLibraryId)) {
      throw MusicKitException('invalid playlist apply request');
    }
    final dynamic raw = await _invoke('fetchPlaylistFingerprint', {
      'appleLibraryId': appleLibraryId,
    });
    if (raw is! String || !_fingerprint.hasMatch(raw)) {
      throw MusicKitException('malformed playlist apply receipt');
    }
    return raw;
  }

  Future<PlaylistApplyReceipt> createRevisedPlaylist({
    required String operationId,
    required String name,
    required String description,
    required List<String> appleCatalogIds,
    required String desiredFingerprint,
  }) async {
    if (!_uuid.hasMatch(operationId) ||
        name.isEmpty ||
        name.length > 500 ||
        description.length > 10000 ||
        appleCatalogIds.isEmpty ||
        appleCatalogIds.any((id) => !_catalogId.hasMatch(id)) ||
        !_fingerprint.hasMatch(desiredFingerprint)) {
      throw MusicKitException('invalid playlist apply request');
    }

    final dynamic raw = await _invoke('createRevisedPlaylist', {
      'operationId': operationId,
      'name': name,
      'description': description,
      'appleCatalogIds': List<String>.unmodifiable(appleCatalogIds),
      'desiredFingerprint': desiredFingerprint,
    }, mutationOutcomeMayBeUnknown: true);
    if (raw is! Map) {
      throw MusicKitException('malformed playlist apply receipt');
    }

    final receiptOperationId = raw['operationId'];
    final rawOutcome = raw['outcome'];
    final libraryId = raw['appleLibraryId'];
    final added = raw['added'];
    final failed = raw['failed'];
    final resultingFingerprint = raw['resultingFingerprint'];
    final outcome = switch (rawOutcome) {
      'success' => PlaylistApplyOutcome.success,
      'partial' => PlaylistApplyOutcome.partial,
      'unknown' => PlaylistApplyOutcome.unknown,
      _ => null,
    };
    final validOptionalLibraryId =
        libraryId == null ||
        (libraryId is String && _opaqueId.hasMatch(libraryId));
    final validOptionalFingerprint =
        resultingFingerprint == null ||
        (resultingFingerprint is String &&
            _fingerprint.hasMatch(resultingFingerprint));
    if (receiptOperationId != operationId ||
        outcome == null ||
        !validOptionalLibraryId ||
        added is! int ||
        added < 0 ||
        failed is! int ||
        failed < 0 ||
        added + failed > appleCatalogIds.length ||
        !validOptionalFingerprint ||
        (outcome == PlaylistApplyOutcome.success &&
            (libraryId == null ||
                resultingFingerprint != desiredFingerprint)) ||
        (outcome == PlaylistApplyOutcome.partial &&
            (libraryId == null || resultingFingerprint == null))) {
      throw MusicKitException('malformed playlist apply receipt');
    }

    return PlaylistApplyReceipt(
      operationId: operationId,
      outcome: outcome,
      appleLibraryId: libraryId as String?,
      added: added,
      failed: failed,
      resultingFingerprint: resultingFingerprint as String?,
    );
  }

  Future<dynamic> _invoke(
    String method,
    Map<String, dynamic> arguments, {
    bool mutationOutcomeMayBeUnknown = false,
  }) async {
    try {
      return await _channel
          .invokeMethod<dynamic>(method, arguments)
          .timeout(_callTimeout);
    } on PlatformException catch (error) {
      // Never carry provider details or response bodies across this boundary.
      throw MusicKitException(
        mutationOutcomeMayBeUnknown && error.code != 'unresolved_catalog'
            ? 'playlist apply result is unknown'
            : 'playlist apply failed',
      );
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      throw MusicKitException('playlist apply result is unknown');
    }
  }
}
