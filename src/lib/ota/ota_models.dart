/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// ota_models.dart - Data returned by the APRS OTA API (aprsota.org).
//
// APRS OTA is an on-the-air activity: a host goes on the air from wherever
// they are and chasers work them through the `OTA` APRS bot. The website
// scores it and exposes the live state over a small REST API, of which this
// app reads one endpoint: the ops that are on the air right now.
//

/// A decimal-degrees position reported for an op.
class OtaPosition {
  final double latitude;
  final double longitude;

  const OtaPosition({required this.latitude, required this.longitude});

  static OtaPosition? fromJson(Object? json) {
    if (json is! Map) return null;
    final lat = (json['lat'] as num?)?.toDouble();
    final lon = (json['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    if (!lat.isFinite || !lon.isFinite) return null;
    return OtaPosition(latitude: lat, longitude: lon);
  }
}

/// A POTA or SOTA reference the host named when they went on the air.
class OtaReference {
  /// 'pota' or 'sota'.
  final String kind;

  /// The reference as the host gave it, e.g. "US-0072" or "W7U/SL-001".
  final String code;

  const OtaReference({required this.kind, required this.code});

  static OtaReference? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'] as String?;
    final code = json['code'] as String?;
    if (kind == null || code == null || code.isEmpty) return null;
    return OtaReference(kind: kind, code: code);
  }

  /// "POTA US-0072", for display.
  String get label => '${kind.toUpperCase()} $code';
}

/// One op, as `/api/v1/now` reports it.
class OtaOp {
  /// The host's base callsign. This is what a CHASE names.
  final String callsign;

  /// The station running the op, SSID included.
  final String station;

  /// The op's per-host number.
  final int number;

  /// 'on_air' or 'ended'.
  final String state;

  /// What the host typed after HOST, or null.
  final String? description;

  /// The POTA or SOTA reference, or null.
  final OtaReference? reference;

  /// Six-character Maidenhead locator, or null.
  final String? grid;

  /// Where the confirming beacon placed the host.
  final OtaPosition? position;

  /// English country name, or null.
  final String? countryName;

  /// Name of the body of water the op is on, or null on dry land.
  final String? waterName;

  /// When the op went on the air.
  final DateTime? onAirAt;

  /// When the op goes off the air unless extended, or null once ended.
  final DateTime? expiresAt;

  /// Confirmed QSOs.
  final int qsos;

  /// Entries with no QSL yet.
  final int incomplete;

  /// The op's score.
  final int points;

  /// The op's page on aprsota.org.
  final String? url;

  const OtaOp({
    required this.callsign,
    required this.station,
    required this.number,
    required this.state,
    this.description,
    this.reference,
    this.grid,
    this.position,
    this.countryName,
    this.waterName,
    this.onAirAt,
    this.expiresAt,
    this.qsos = 0,
    this.incomplete = 0,
    this.points = 0,
    this.url,
  });

  static DateTime? _time(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static OtaOp? fromJson(Object? json) {
    if (json is! Map) return null;
    final callsign = _text(json['callsign']);
    if (callsign == null) return null;
    final country = json['country'];
    final water = json['water'];
    return OtaOp(
      callsign: callsign.toUpperCase(),
      station: _text(json['station']) ?? callsign.toUpperCase(),
      number: (json['number'] as num?)?.toInt() ?? 0,
      state: _text(json['state']) ?? 'on_air',
      description: _text(json['description']),
      reference: OtaReference.fromJson(json['reference']),
      grid: _text(json['grid']),
      position: OtaPosition.fromJson(json['position']),
      countryName: country is Map ? _text(country['name']) : null,
      waterName: water is Map ? _text(water['name']) : null,
      onAirAt: _time(json['on_air_at']),
      expiresAt: _time(json['expires_at']),
      qsos: (json['qsos'] as num?)?.toInt() ?? 0,
      incomplete: (json['incomplete'] as num?)?.toInt() ?? 0,
      points: (json['points'] as num?)?.toInt() ?? 0,
      url: _text(json['url']),
    );
  }

  /// Whole minutes until this op goes off the air, or null when unknown.
  /// Negative values are clamped away: an expired op reads as 0.
  int? minutesLeft({DateTime? now}) {
    final expires = expiresAt;
    if (expires == null) return null;
    final remaining = expires.difference(now ?? DateTime.now().toUtc());
    if (remaining.isNegative) return 0;
    return remaining.inMinutes;
  }
}

/// The `/api/v1/now` answer: every op on the air at [generatedAt].
class OtaNow {
  final DateTime? generatedAt;
  final List<OtaOp> onAir;

  const OtaNow({this.generatedAt, this.onAir = const []});

  factory OtaNow.fromJson(Map<String, dynamic> json) {
    final raw = json['on_air'];
    final ops = <OtaOp>[];
    if (raw is List) {
      for (final item in raw) {
        final op = OtaOp.fromJson(item);
        if (op != null) ops.add(op);
      }
    }
    return OtaNow(generatedAt: OtaOp._time(json['generated_at']), onAir: ops);
  }
}
