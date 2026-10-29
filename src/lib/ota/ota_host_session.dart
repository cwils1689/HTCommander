/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// ota_host_session.dart - Tracks the op this station is hosting on APRS OTA.
//
// Hosting is a conversation with the `OTA` bot and nothing else: HOST goes out,
// a position report follows, and the bot answers with the state of the op.
// There is no API for the host side, so the only source of truth available to
// the app is what the bot says over the air. This class reads those replies as
// they arrive, keeps the resulting op state, and hands the UI the command
// strings to send back.
//
// The state is persisted (device 0, `OtaHostOpState`) because an op can run for
// two hours and the app may well be restarted inside one. Nothing here
// transmits: the caller owns the radio, so it does the sending and calls
// [noteCommandSent] with whatever it put on the air.
//

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/data_broker.dart';
import '../services/data_broker_client.dart';
import 'ota_client.dart';

/// Where an op is in its life.
enum OtaHostPhase {
  /// Not hosting.
  idle,

  /// HOST has gone out; the bot wants a position report within five minutes.
  awaitingBeacon,

  /// The bot confirmed the op.
  onAir,

  /// The op is over, by DONE or by timer.
  ended,
}

/// A chaser the bot has relayed to us who has not been QSLed yet.
class OtaChaser {
  /// The chaser's station, SSID included, as the bot named it.
  final String station;

  /// The chaser's grid subsquare, when the relay carried one.
  final String? grid;

  /// What the chaser sent with their CHASE, or null.
  final String? message;

  /// When the relay reached us.
  final DateTime at;

  const OtaChaser({
    required this.station,
    this.grid,
    this.message,
    required this.at,
  });

  /// The callsign without its SSID. A QSL may name either.
  String get callsign {
    final dash = station.indexOf('-');
    return dash < 0 ? station : station.substring(0, dash);
  }

  Map<String, Object?> toJson() => {
    'station': station,
    'grid': grid,
    'message': message,
    'at': at.toUtc().toIso8601String(),
  };

  static OtaChaser? fromJson(Object? json) {
    if (json is! Map) return null;
    final station = json['station'];
    if (station is! String || station.isEmpty) return null;
    return OtaChaser(
      station: station,
      grid: json['grid'] as String?,
      message: json['message'] as String?,
      at: DateTime.tryParse('${json['at']}')?.toUtc() ?? DateTime.now().toUtc(),
    );
  }
}

/// The commands a host sends while running an op. Each carries the bot's rate
/// limit so the UI can hold a button back rather than get a silent refusal:
/// when a host trips a limit the bot simply stops answering.
enum OtaHostCommand {
  host(Duration(seconds: 30)),
  stay(Duration(minutes: 3)),
  time(Duration(minutes: 3)),
  info(Duration(minutes: 3)),
  chasers(Duration(minutes: 3)),
  blast(Duration(seconds: 150)),

  /// QSL and DONE are self-limiting, so the bot sets no interval on them.
  qsl(Duration.zero),
  done(Duration.zero);

  const OtaHostCommand(this.minInterval);

  /// The shortest gap the bot accepts between two of these.
  final Duration minInterval;
}

/// The op this station is hosting, as far as the OTA bot has told us.
///
/// Listen to it for UI updates. Everything on it is what the bot said, not what
/// the app assumes, with one exception: [phase] goes to
/// [OtaHostPhase.awaitingBeacon] the moment HOST is sent, before any reply.
class OtaHostSession extends ChangeNotifier {
  OtaHostSession._();

  static final OtaHostSession instance = OtaHostSession._();

  /// Settings key (device 0) holding the serialized op state.
  static const String stateSettingKey = 'OtaHostOpState';

  /// How long the bot gives a host to beacon after HOST.
  static const Duration beaconWindow = Duration(minutes: 5);

  /// No op can run longer than this, whatever the host sends.
  static const Duration maxOpDuration = Duration(minutes: 120);

  final DataBrokerClient _broker = DataBrokerClient();
  bool _attached = false;

  OtaHostPhase _phase = OtaHostPhase.idle;
  String? _station;
  String? _description;
  DateTime? _hostSentAt;
  DateTime? _onAirAt;
  DateTime? _endedAt;
  String? _location;
  String? _url;
  String? _summary;
  String? _notice;
  DateTime? _noticeAt;
  String? _lastBotMessage;
  DateTime? _lastBotMessageAt;
  DateTime? _beaconPromptAt;

  int? _minutesLeft;
  DateTime? _minutesLeftAt;
  int? _minutesToCap;
  int? _stayAdds;
  int? _qsos;
  int? _points;
  int? _chasing;

  final List<OtaChaser> _chasers = <OtaChaser>[];
  final Map<OtaHostCommand, DateTime> _lastSent = {};

  /// Set while a CHASERS reply is plausible, so a bare list of callsigns is
  /// only read as one when we actually asked.
  DateTime? _chasersAskedAt;

  // --- State ---------------------------------------------------------------

  OtaHostPhase get phase => _phase;

  bool get isHosting =>
      _phase == OtaHostPhase.awaitingBeacon || _phase == OtaHostPhase.onAir;

  /// The station the op is run from, as it was when HOST went out. Every other
  /// command has to come from this same callsign and SSID.
  String? get station => _station;

  /// What the host typed after HOST, or null.
  String? get description => _description;

  DateTime? get hostSentAt => _hostSentAt;
  DateTime? get onAirAt => _onAirAt;
  DateTime? get endedAt => _endedAt;

  /// Where the confirming beacon placed us, as the bot phrased it ("DN40fb").
  String? get location => _location;

  /// The op's page on aprsota.org, from the confirmation.
  String? get url => _url;

  /// The bot's end-of-op summary, once the op is over.
  String? get summary => _summary;

  /// A hint or refusal worth showing the user, or null.
  String? get notice => _notice;
  DateTime? get noticeAt => _noticeAt;

  /// When the bot last asked for the position report that starts the op. The
  /// UI watches this so the beacon can follow the prompt as well as the HOST.
  DateTime? get beaconPromptAt => _beaconPromptAt;

  /// The last thing the bot said to us, whether or not it was understood.
  String? get lastBotMessage => _lastBotMessage;
  DateTime? get lastBotMessageAt => _lastBotMessageAt;

  /// Minutes the bot said were left, counted down from when it said it.
  /// Null until TIME, INFO or STAY has been answered.
  int? get minutesLeft {
    final minutes = _minutesLeft;
    final at = _minutesLeftAt;
    if (minutes == null || at == null) return null;
    final elapsed = DateTime.now().difference(at).inMinutes;
    final remaining = minutes - elapsed;
    return remaining < 0 ? 0 : remaining;
  }

  /// Minutes to the two hour ceiling, counted down the same way.
  int? get minutesToCap {
    final minutes = _minutesToCap;
    final at = _minutesLeftAt;
    if (minutes == null || at == null) return null;
    final remaining = minutes - DateTime.now().difference(at).inMinutes;
    return remaining < 0 ? 0 : remaining;
  }

  /// What a STAY would really add, which shrinks near the ceiling. Null when
  /// the bot stopped offering it, meaning the op is at the maximum.
  int? get stayAdds => _stayAdds;

  /// True once the bot has said the op cannot be extended any further.
  bool get atCap => _stayAdds == null && _minutesToCap != null;

  int? get qsos => _qsos;
  int? get points => _points;

  /// Chasers calling, as INFO last reported.
  int? get chasing => _chasing;

  /// Chasers waiting on a QSL, longest wait first.
  List<OtaChaser> get chasers => List.unmodifiable(_chasers);

  /// Seconds left of the five minutes the bot allows for the beacon, or null
  /// when we are not waiting on one.
  int? get beaconSecondsLeft {
    if (_phase != OtaHostPhase.awaitingBeacon) return null;
    final sent = _hostSentAt;
    if (sent == null) return null;
    final left = beaconWindow - DateTime.now().difference(sent);
    return left.isNegative ? 0 : left.inSeconds;
  }

  /// Whether [command] may be sent now without tripping the bot's rate limit.
  bool canSend(OtaHostCommand command) => cooldown(command) == Duration.zero;

  /// How long until [command] may be sent again.
  Duration cooldown(OtaHostCommand command) {
    final last = _lastSent[command];
    if (last == null) return Duration.zero;
    final left = command.minInterval - DateTime.now().difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  // --- Commands ------------------------------------------------------------

  /// `HOST <description>`, which goes on the air once a beacon follows it.
  static String hostCommand(String description) {
    final text = _collapse(description);
    return text.isEmpty ? 'HOST' : 'HOST $text';
  }

  /// `QSL <callsign> <message>`, which logs the contact and relays [message].
  static String qslCommand(String callsign, [String message = '']) {
    final text = _collapse(message);
    final call = callsign.trim().toUpperCase();
    return text.isEmpty ? 'QSL $call' : 'QSL $call $text';
  }

  /// `BLAST <text>`: one message to everyone on the op.
  static String blastCommand(String text) => 'BLAST ${_collapse(text)}';

  /// `DONE <signoff>`, which ends the op and keeps [signoff] with the log.
  static String doneCommand([String signoff = '']) {
    final text = _collapse(signoff);
    return text.isEmpty ? 'DONE' : 'DONE $text';
  }

  static const String stayCommand = 'STAY';
  static const String timeCommand = 'TIME';
  static const String infoCommand = 'INFO';
  static const String chasersCommand = 'CHASERS';

  /// The station the op will run from: the global callsign and SSID. Hosting
  /// needs one, and every command has to come from the same one.
  String? localStation() {
    final callsign = (_broker.getValue<String>(0, 'CallSign', '') ?? '').trim();
    if (callsign.isEmpty) return null;
    final ssid = _broker.getValue<int>(0, 'StationId', 0) ?? 0;
    return ssid == 0
        ? callsign.toUpperCase()
        : '${callsign.toUpperCase()}-$ssid';
  }

  // --- Lifecycle -----------------------------------------------------------

  /// Starts reading the bot's replies and restores any op still running.
  /// Idempotent, so every entry point into the feature can call it.
  void attach() {
    if (_attached) return;
    _attached = true;
    _restore();
    _broker.subscribe(
      deviceId: DataBroker.allDevices,
      name: 'AprsMessageReceived',
      callback: _onAprsMessage,
    );
  }

  /// Records a command the caller has just put on the air. [text] is the whole
  /// message body, as sent.
  void noteCommandSent(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final keyword = trimmed.split(RegExp(r'\s+')).first.toUpperCase();
    final rest = trimmed.substring(keyword.length).trim();

    switch (keyword) {
      case 'HOST':
      case 'QRV':
        _lastSent[OtaHostCommand.host] = DateTime.now();
        _beginHosting(rest);
      case 'STAY':
        _lastSent[OtaHostCommand.stay] = DateTime.now();
      case 'TIME':
      case 'QRT?':
        _lastSent[OtaHostCommand.time] = DateTime.now();
      case 'INFO':
        _lastSent[OtaHostCommand.info] = DateTime.now();
      case 'CHASERS':
        _lastSent[OtaHostCommand.chasers] = DateTime.now();
        _chasersAskedAt = DateTime.now();
      case 'BLAST':
      case 'QST':
        _lastSent[OtaHostCommand.blast] = DateTime.now();
      case 'QSL':
        _lastSent[OtaHostCommand.qsl] = DateTime.now();
        // The bot relays the QSL to the chaser, not to us, so the only sign
        // the contact is answered is that we sent it.
        final target = rest.split(RegExp(r'\s+')).first;
        if (target.isNotEmpty) _dropChaser(target);
      case 'DONE':
      case 'QRT':
        _lastSent[OtaHostCommand.done] = DateTime.now();
        // The bot's "Op complete" confirms this; don't pre-empt it, so a DONE
        // that never reached the bot does not look like a finished op.
        break;
      default:
        break;
    }
    _save();
    notifyListeners();
  }

  /// Clears a finished op so the UI returns to its starting state.
  void reset() {
    _phase = OtaHostPhase.idle;
    _station = null;
    _description = null;
    _hostSentAt = null;
    _onAirAt = null;
    _endedAt = null;
    _location = null;
    _url = null;
    _summary = null;
    _notice = null;
    _noticeAt = null;
    _minutesLeft = null;
    _minutesLeftAt = null;
    _minutesToCap = null;
    _stayAdds = null;
    _qsos = null;
    _points = null;
    _chasing = null;
    _chasers.clear();
    _chasersAskedAt = null;
    _beaconPromptAt = null;
    _save();
    notifyListeners();
  }

  /// Dismisses the current hint or refusal.
  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    _noticeAt = null;
    _save();
    notifyListeners();
  }

  void _beginHosting(String description) {
    _phase = OtaHostPhase.awaitingBeacon;
    _station = localStation();
    _description = description.isEmpty ? null : description;
    _hostSentAt = DateTime.now();
    _onAirAt = null;
    _endedAt = null;
    _location = null;
    _url = null;
    _summary = null;
    _notice = null;
    _noticeAt = null;
    _minutesLeft = null;
    _minutesLeftAt = null;
    _minutesToCap = null;
    _stayAdds = null;
    _qsos = null;
    _points = null;
    _chasing = null;
    _chasers.clear();
    _beaconPromptAt = null;
  }

  // --- Reading the bot -----------------------------------------------------

  void _onAprsMessage(int deviceId, String name, Object? data) {
    if (data is! Map) return;
    final source = '${data['source'] ?? ''}'.trim().toUpperCase();
    // The bot answers from OTA, with or without an SSID.
    final base = source.split('-').first;
    if (base != OtaClient.botCallsign) return;
    final text = '${data['text'] ?? ''}'.trim();
    if (text.isEmpty) return;

    final millis = data['time'];
    final at = millis is int
        ? DateTime.fromMillisecondsSinceEpoch(millis)
        : DateTime.now();
    ingestBotMessage(text, at: at);
  }

  /// Applies one message from the OTA bot. Public so the parsing can be tested
  /// without a radio.
  @visibleForTesting
  void ingestBotMessage(String text, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _lastBotMessage = text;
    _lastBotMessageAt = now;

    // A relayed chase: "DE W1XYZ-5 DN40fb greetings from mike".
    final relay = RegExp(
      r'^DE\s+([A-Z0-9]{3,7}(?:-\d{1,2})?)\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (relay != null) {
      _addChaser(relay.group(1)!.toUpperCase(), relay.group(2) ?? '', now);
      _save();
      notifyListeners();
      return;
    }

    // "Send a position report within 5 mins to go on the air".
    if (RegExp(
      r'position report within .* to go on the air',
      caseSensitive: false,
    ).hasMatch(text)) {
      if (_phase != OtaHostPhase.onAir) {
        _phase = OtaHostPhase.awaitingBeacon;
        // The bot's prompt, not our send, starts the five minutes it counts.
        _hostSentAt = now;
        _beaconPromptAt = now;
      }
      _finish();
      return;
    }

    // "K7ABC-6 is on the air from DN40fb. aprsota.org/K7ABC".
    final onAir = RegExp(
      r'^([A-Z0-9]{3,7}(?:-\d{1,2})?) is on the air\s*([^.]*)\.?\s*(\S+)?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (onAir != null) {
      _phase = OtaHostPhase.onAir;
      _station = onAir.group(1)!.toUpperCase();
      _onAirAt = now;
      _endedAt = null;
      final where = (onAir.group(2) ?? '').trim();
      _location = where.isEmpty
          ? null
          : where.replaceFirst(RegExp(r'^from\s+', caseSensitive: false), '');
      final url = onAir.group(3);
      _url = (url == null || url.isEmpty)
          ? null
          : (url.startsWith('http') ? url : 'https://$url');
      _notice = null;
      _noticeAt = null;
      _finish();
      return;
    }

    // "Op complete: 12 QSOs, 11 pts. aprsota.org/K7ABC".
    if (RegExp(r'^Op complete:', caseSensitive: false).hasMatch(text)) {
      _phase = OtaHostPhase.ended;
      _endedAt = now;
      _summary = text;
      _readTotals(text);
      _minutesLeft = null;
      _minutesLeftAt = null;
      _minutesToCap = null;
      _stayAdds = null;
      _finish();
      return;
    }

    // The beacon never arrived, or arrived unusable. The op did not start.
    if (RegExp(
      r'^(No beacon received|Beacons? (arrived|had|has) )',
      caseSensitive: false,
    ).hasMatch(text)) {
      if (_phase != OtaHostPhase.onAir) _phase = OtaHostPhase.idle;
      _notice = text;
      _noticeAt = now;
      _finish();
      return;
    }

    // Refusals and hints, which leave the op exactly as it was.
    if (RegExp(
      r'^(Must transmit via RF|You already have an op|Going quiet for maintenance|Your op is run by|[A-Z0-9-]+ is waiting on your QSL|No chase from|QSL needs|STAY needs|DONE needs|BLAST needs|A blast needs|You have sent all your blasts|This op has taken all|Too many stations)',
      caseSensitive: false,
    ).hasMatch(text)) {
      _notice = text;
      _noticeAt = now;
      // "You already have an op on the air" answers a HOST we sent while
      // already hosting: the earlier op is the live one, so stop waiting on a
      // beacon for the one that was refused.
      if (_phase == OtaHostPhase.awaitingBeacon &&
          RegExp(
            r'^(Must transmit via RF|Going quiet for maintenance)',
            caseSensitive: false,
          ).hasMatch(text)) {
        _phase = OtaHostPhase.idle;
      }
      _finish();
      return;
    }

    // "At the 2 hour max. Off the air in 12 minutes."
    final atCap = RegExp(
      r'At the 2 hour max\.\s*Off the air in (\d+) minutes?',
      caseSensitive: false,
    ).firstMatch(text);
    if (atCap != null) {
      _phase = OtaHostPhase.onAir;
      _minutesLeft = int.parse(atCap.group(1)!);
      _minutesToCap = _minutesLeft;
      _minutesLeftAt = now;
      _stayAdds = null;
      _finish();
      return;
    }

    // TIME and STAY: "Off the air in 35 minutes, max 95 minutes. STAY adds 30 mins".
    final timing = RegExp(
      r'Off the air in (\d+) minutes?,\s*max (\d+) minutes?',
      caseSensitive: false,
    ).firstMatch(text);
    if (timing != null) {
      _phase = OtaHostPhase.onAir;
      _minutesLeft = int.parse(timing.group(1)!);
      _minutesToCap = int.parse(timing.group(2)!);
      _minutesLeftAt = now;
      _stayAdds = _readStayAdds(text);
      _finish();
      return;
    }

    // INFO: "3 chasing, 12 QSOs, 11 pts, 22 min left. STAY adds 30 mins".
    final info = RegExp(
      r'^(\d+) chasing,\s*(\d+) QSOs?,\s*(\d+) pts?,\s*(\d+) min left',
      caseSensitive: false,
    ).firstMatch(text);
    if (info != null) {
      _phase = OtaHostPhase.onAir;
      _chasing = int.parse(info.group(1)!);
      _qsos = int.parse(info.group(2)!);
      _points = int.parse(info.group(3)!);
      _minutesLeft = int.parse(info.group(4)!);
      _minutesLeftAt = now;
      _stayAdds = _readStayAdds(text);
      _finish();
      return;
    }

    // CHASERS: a bare list of callsigns, longest wait first. Only read as one
    // when we asked, since nothing else in the message says what it is.
    final asked = _chasersAskedAt;
    if (asked != null &&
        now.difference(asked) < const Duration(minutes: 5) &&
        RegExp(
          r'^[A-Z0-9]{3,7}(-\d{1,2})?( +[A-Z0-9]{3,7}(-\d{1,2})?)*$',
          caseSensitive: false,
        ).hasMatch(text)) {
      _replaceChasers(text.split(RegExp(r'\s+')), now);
      _chasersAskedAt = null;
      _finish();
      return;
    }

    _finish();
  }

  /// Pulls "STAY adds 30 mins" off a reply, or null when the bot left it off
  /// because there is no room left to add.
  int? _readStayAdds(String text) {
    final match = RegExp(
      r'STAY adds (\d+) mins?',
      caseSensitive: false,
    ).firstMatch(text);
    return match == null ? null : int.parse(match.group(1)!);
  }

  /// Reads "12 QSOs, 11 pts" out of an end-of-op summary.
  void _readTotals(String text) {
    final qsos = RegExp(r'(\d+) QSOs?', caseSensitive: false).firstMatch(text);
    if (qsos != null) _qsos = int.parse(qsos.group(1)!);
    final points = RegExp(r'(\d+) pts?', caseSensitive: false).firstMatch(text);
    if (points != null) _points = int.parse(points.group(1)!);
  }

  void _addChaser(String station, String rest, DateTime at) {
    // The relay puts the grid subsquare before any text the chaser sent.
    String? grid;
    var message = rest.trim();
    final gridMatch = RegExp(
      r'^([A-R]{2}\d{2}[a-x]{2})\b\s*',
      caseSensitive: false,
    ).firstMatch(message);
    if (gridMatch != null) {
      grid = gridMatch.group(1);
      message = message.substring(gridMatch.end).trim();
    }

    final chaser = OtaChaser(
      station: station,
      grid: grid,
      message: message.isEmpty ? null : message,
      at: at,
    );
    final existing = _chasers.indexWhere((c) => c.station == station);
    if (existing >= 0) {
      // A chaser who called again is still one entry, kept at their original
      // place in the queue so the order stays "longest wait first".
      _chasers[existing] = OtaChaser(
        station: station,
        grid: grid ?? _chasers[existing].grid,
        message: chaser.message ?? _chasers[existing].message,
        at: _chasers[existing].at,
      );
    } else {
      _chasers.add(chaser);
    }
  }

  /// Rebuilds the waiting list from a CHASERS reply, which is authoritative:
  /// anyone missing from it has been answered, including from another app.
  void _replaceChasers(List<String> stations, DateTime at) {
    final kept = <OtaChaser>[];
    for (final raw in stations) {
      final station = raw.trim().toUpperCase();
      if (station.isEmpty) continue;
      final known = _chasers.firstWhere(
        (c) => c.station == station,
        orElse: () => OtaChaser(station: station, at: at),
      );
      kept.add(known);
    }
    _chasers
      ..clear()
      ..addAll(kept);
  }

  /// Drops a chaser we have QSLed. The SSID is optional on a QSL, so a bare
  /// callsign answers whichever SSID of it is waiting.
  void _dropChaser(String target) {
    final wanted = target.trim().toUpperCase();
    if (wanted.isEmpty) return;
    final hasSsid = wanted.contains('-');
    _chasers.removeWhere(
      (c) => hasSsid ? c.station == wanted : c.callsign == wanted,
    );
  }

  void _finish() {
    _save();
    notifyListeners();
  }

  // --- Persistence ---------------------------------------------------------

  void _save() {
    _broker.dispatch(
      deviceId: 0,
      name: stateSettingKey,
      data: jsonEncode({
        'phase': _phase.name,
        'station': _station,
        'description': _description,
        'hostSentAt': _hostSentAt?.toIso8601String(),
        'onAirAt': _onAirAt?.toIso8601String(),
        'endedAt': _endedAt?.toIso8601String(),
        'location': _location,
        'url': _url,
        'summary': _summary,
        'notice': _notice,
        'noticeAt': _noticeAt?.toIso8601String(),
        'minutesLeft': _minutesLeft,
        'minutesLeftAt': _minutesLeftAt?.toIso8601String(),
        'minutesToCap': _minutesToCap,
        'stayAdds': _stayAdds,
        'qsos': _qsos,
        'points': _points,
        'chasing': _chasing,
        'chasers': _chasers.map((c) => c.toJson()).toList(),
        'lastSent': {
          for (final entry in _lastSent.entries)
            entry.key.name: entry.value.millisecondsSinceEpoch,
        },
      }),
      store: true,
    );
  }

  void _restore() {
    final raw = (_broker.getValue<String>(0, stateSettingKey, '') ?? '').trim();
    if (raw.isEmpty) return;
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      json = decoded;
    } catch (_) {
      return;
    }

    DateTime? time(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;

    _phase = OtaHostPhase.values.firstWhere(
      (p) => p.name == json['phase'],
      orElse: () => OtaHostPhase.idle,
    );
    _station = json['station'] as String?;
    _description = json['description'] as String?;
    _hostSentAt = time(json['hostSentAt']);
    _onAirAt = time(json['onAirAt']);
    _endedAt = time(json['endedAt']);
    _location = json['location'] as String?;
    _url = json['url'] as String?;
    _summary = json['summary'] as String?;
    _notice = json['notice'] as String?;
    _noticeAt = time(json['noticeAt']);
    _minutesLeft = (json['minutesLeft'] as num?)?.toInt();
    _minutesLeftAt = time(json['minutesLeftAt']);
    _minutesToCap = (json['minutesToCap'] as num?)?.toInt();
    _stayAdds = (json['stayAdds'] as num?)?.toInt();
    _qsos = (json['qsos'] as num?)?.toInt();
    _points = (json['points'] as num?)?.toInt();
    _chasing = (json['chasing'] as num?)?.toInt();

    final chasers = json['chasers'];
    if (chasers is List) {
      for (final item in chasers) {
        final chaser = OtaChaser.fromJson(item);
        if (chaser != null) _chasers.add(chaser);
      }
    }

    final lastSent = json['lastSent'];
    if (lastSent is Map) {
      for (final command in OtaHostCommand.values) {
        final millis = lastSent[command.name];
        if (millis is num) {
          _lastSent[command] = DateTime.fromMillisecondsSinceEpoch(
            millis.toInt(),
          );
        }
      }
    }

    _expireStaleState();
  }

  /// An op the app was not running for may well be over. The bot is the only
  /// authority on that, so rather than show a stale op as live, time it out on
  /// the limits the bot itself enforces.
  void _expireStaleState() {
    final now = DateTime.now();
    switch (_phase) {
      case OtaHostPhase.awaitingBeacon:
        final sent = _hostSentAt;
        if (sent == null || now.difference(sent) > beaconWindow) {
          _phase = OtaHostPhase.idle;
        }
      case OtaHostPhase.onAir:
        final started = _onAirAt ?? _hostSentAt;
        if (started == null || now.difference(started) > maxOpDuration) {
          _phase = OtaHostPhase.ended;
          _endedAt ??= started?.add(maxOpDuration);
        }
      case OtaHostPhase.idle:
      case OtaHostPhase.ended:
        break;
    }
  }

  /// Squeezes a free-text argument into one APRS-friendly line.
  static String _collapse(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');
}
