/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// ota_client.dart - Reads the APRS OTA (aprsota.org) REST API.
//
// Only `/api/v1/now` is used: the ops on the air right now. The API asks
// callers to poll no more than once a minute, to send If-None-Match, and to
// honour the Cache-Control it returns (private, max-age=30). This client does
// all three, so the UI can call [fetchNow] freely and get the cached answer
// back until a real refresh is due.
//
// Authentication is a per-developer bearer token, minted by hand by the site.
// It is therefore NOT shipped with the app: the user pastes their own token,
// which is kept on device 0 as `OtaApiToken`.
//

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../services/data_broker_client.dart';
import 'ota_models.dart';

/// Why a fetch did not return ops.
enum OtaFetchStatus {
  ok,

  /// No API token has been configured.
  noToken,

  /// The server rejected the token.
  unauthorized,

  /// The server asked us to slow down.
  rateLimited,

  /// Network failure, timeout, or an unparseable answer.
  error,
}

/// The outcome of a [OtaClient.fetchNow] call.
class OtaFetchResult {
  final OtaFetchStatus status;
  final OtaNow? now;

  /// Server or network detail, for display when [status] is not ok.
  final String? message;

  /// True when [now] came from the cache rather than the network.
  final bool fromCache;

  const OtaFetchResult({
    required this.status,
    this.now,
    this.message,
    this.fromCache = false,
  });

  bool get isOk => status == OtaFetchStatus.ok;
}

class OtaClient {
  OtaClient._();

  static final OtaClient instance = OtaClient._();

  static const String _host = 'aprsota.org';
  static const String _nowPath = '/api/v1/now';

  /// Where the site mints API tokens.
  static const String handbookUrl = 'https://aprsota.org/handbook/api';

  /// The handbook page explaining how to host an op.
  static const String hostHandbookUrl =
      'https://aprsota.org/handbook/host-an-op';

  /// The APRS callsign of the OTA bot. Commands are sent to it as ordinary
  /// addressed APRS messages.
  static const String botCallsign = 'OTA';

  /// Settings key (device 0) holding the user's bearer token.
  static const String tokenSettingKey = 'OtaApiToken';

  /// Settings key (device 0) holding the opaque per-install identifier sent as
  /// the `OTA-User` header for the site's usage ledger. Never a callsign.
  static const String userIdSettingKey = 'OtaUserId';

  /// The API asks for no more than one poll a minute.
  static const Duration minPollInterval = Duration(seconds: 60);

  final DataBrokerClient _broker = DataBrokerClient();
  final http.Client _http = http.Client();

  String? _etag;
  OtaNow? _cached;
  DateTime? _lastFetch;

  /// The configured bearer token, or null when the user has not set one.
  String? get token {
    final value = (_broker.getValue<String>(0, tokenSettingKey, '') ?? '')
        .trim();
    return value.isEmpty ? null : value;
  }

  set token(String? value) {
    _broker.dispatch(
      deviceId: 0,
      name: tokenSettingKey,
      data: (value ?? '').trim(),
      store: true,
    );
    // A different token is a different caller: drop anything cached under the
    // old one so the next fetch really goes out.
    _etag = null;
    _cached = null;
    _lastFetch = null;
  }

  bool get hasToken => token != null;

  /// When the next network poll is allowed, given [minPollInterval].
  DateTime? get nextAllowedFetch => _lastFetch?.add(minPollInterval);

  /// Whether a forced refresh would respect the API's one-a-minute request.
  bool get canFetchNow {
    final next = nextAllowedFetch;
    return next == null || !DateTime.now().isBefore(next);
  }

  /// An opaque, stable, per-install identifier for the usage ledger. Created
  /// on first use. Deliberately random: it must not identify the operator.
  String _otaUser() {
    final existing = (_broker.getValue<String>(0, userIdSettingKey, '') ?? '')
        .trim();
    if (existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final id = List<String>.generate(
      16,
      (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _broker.dispatch(
      deviceId: 0,
      name: userIdSettingKey,
      data: id,
      store: true,
    );
    return id;
  }

  /// Fetches the ops on the air.
  ///
  /// Returns the cached answer without touching the network when the last
  /// fetch was less than [minPollInterval] ago, unless [force] is set — and
  /// even then the conditional request usually costs only a 304.
  Future<OtaFetchResult> fetchNow({bool force = false}) async {
    final bearer = token;
    if (bearer == null) {
      return const OtaFetchResult(status: OtaFetchStatus.noToken);
    }

    final cached = _cached;
    final last = _lastFetch;
    if (!force &&
        cached != null &&
        last != null &&
        DateTime.now().difference(last) < minPollInterval) {
      return OtaFetchResult(
        status: OtaFetchStatus.ok,
        now: cached,
        fromCache: true,
      );
    }

    final headers = <String, String>{
      'Authorization': 'Bearer $bearer',
      'Accept': 'application/json',
      'OTA-User': _otaUser(),
    };
    final etag = _etag;
    if (etag != null && cached != null) headers['If-None-Match'] = etag;

    try {
      final response = await _http
          .get(Uri.https(_host, _nowPath), headers: headers)
          .timeout(const Duration(seconds: 20));

      // Record the attempt either way so a failing server is not hammered.
      _lastFetch = DateTime.now();

      switch (response.statusCode) {
        case 200:
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) {
            return const OtaFetchResult(
              status: OtaFetchStatus.error,
              message: 'Unexpected response from aprsota.org.',
            );
          }
          final now = OtaNow.fromJson(decoded);
          _cached = now;
          _etag = response.headers['etag'];
          return OtaFetchResult(status: OtaFetchStatus.ok, now: now);
        case 304:
          // Nothing changed; the cache is still correct.
          return OtaFetchResult(
            status: OtaFetchStatus.ok,
            now: cached,
            fromCache: true,
          );
        case 401:
        case 403:
          return OtaFetchResult(
            status: OtaFetchStatus.unauthorized,
            message: _serverMessage(response.body),
          );
        case 429:
          return OtaFetchResult(
            status: OtaFetchStatus.rateLimited,
            message: _serverMessage(response.body),
          );
        default:
          return OtaFetchResult(
            status: OtaFetchStatus.error,
            message:
                _serverMessage(response.body) ??
                'aprsota.org returned ${response.statusCode}.',
          );
      }
    } catch (e) {
      _lastFetch = DateTime.now();
      return OtaFetchResult(status: OtaFetchStatus.error, message: '$e');
    }
  }

  /// Pulls `error.message` out of an API error body, when there is one.
  String? _serverMessage(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // Not JSON; fall through.
    }
    return null;
  }

  /// The message body that chases [hostCallsign] through the OTA bot.
  static String chaseCommand(String hostCallsign) =>
      'CHASE ${hostCallsign.trim().toUpperCase()}';
}
