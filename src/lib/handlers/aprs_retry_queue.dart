/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// aprs_retry_queue.dart - Resends addressed APRS messages until they are acked.
//
// APRS gives an addressed message a sequence id so the far end can acknowledge
// it. Nothing requires a sender to do anything with that acknowledgement, and
// until now this app did not: a message lost to a collision or a missed
// digipeat was silently gone.
//
// Yaesu handhelds retransmit instead, and this emulates them. From the FT1DR
// manual, which the FT3DR and FT5DR follow:
//
//   "If ACK data is not sent from the other station after 1 minute, the same
//    message is retransmitted to the other station."
//   "If ACK data is not sent from the other station after 5 attempts, the
//    message is displayed to be TX OUT."
//
// So five transmissions a minute apart, then the message is given up on. The
// radio shows the remaining count while it waits and offers a way to cancel;
// so does the APRS tab.
//
// This class holds only the schedule and the state. It does not know how to
// build or transmit anything: [AprsHandler] passes in [onTransmit] (which
// rebuilds and re-signs the message, since the auth code is time-based) and
// [onStateChanged], which reports to the UI.
//

import 'dart:async';
import 'dart:convert';

/// Where a sent message stands.
enum AprsDeliveryState {
  /// Transmitted, waiting on an ack, more attempts to come.
  pending,

  /// The addressee acked it.
  acked,

  /// The addressee rejected it.
  rejected,

  /// Every attempt went unanswered: the radio's "TX OUT".
  failed,

  /// The user stopped it retrying (the radio's TX CLR).
  cancelled,
}

/// One message waiting on an ack.
class AprsPendingMessage {
  /// The APRS sequence id, as sent. Every retry reuses it, so the far end can
  /// recognise the retransmissions and collapse them.
  final int msgId;

  /// The station the message is addressed to.
  final String destination;

  /// The message body, without the id or any auth code.
  final String message;

  /// The radio to transmit on, or negative for APRS-IS only.
  final int radioDeviceId;

  /// The APRS route, in the form [name, dest, digi1, ...], or null.
  final List<String>? route;

  /// Transmissions left after the ones already made.
  int attemptsLeft;

  /// When the next transmission is due.
  DateTime nextDueAt;

  /// When to give up even if attempts remain, which covers attempts skipped
  /// while there was no radio to send them on.
  final DateTime deadline;

  AprsPendingMessage({
    required this.msgId,
    required this.destination,
    required this.message,
    required this.radioDeviceId,
    this.route,
    required this.attemptsLeft,
    required this.nextDueAt,
    required this.deadline,
  });

  /// The addressee's callsign without its SSID. An ack may come from a
  /// different SSID of the same station, so matching is done on this.
  String get destinationCallsign {
    final dash = destination.indexOf('-');
    return dash < 0 ? destination : destination.substring(0, dash);
  }

  Map<String, Object?> toJson() => {
    'msgId': msgId,
    'destination': destination,
    'message': message,
    'radioDeviceId': radioDeviceId,
    'route': route,
    'attemptsLeft': attemptsLeft,
    'nextDueAt': nextDueAt.toIso8601String(),
    'deadline': deadline.toIso8601String(),
  };

  static AprsPendingMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final msgId = (json['msgId'] as num?)?.toInt();
    final destination = json['destination'];
    final message = json['message'];
    final nextDueAt = DateTime.tryParse('${json['nextDueAt']}');
    final deadline = DateTime.tryParse('${json['deadline']}');
    if (msgId == null ||
        destination is! String ||
        message is! String ||
        nextDueAt == null ||
        deadline == null) {
      return null;
    }
    final rawRoute = json['route'];
    return AprsPendingMessage(
      msgId: msgId,
      destination: destination,
      message: message,
      radioDeviceId: (json['radioDeviceId'] as num?)?.toInt() ?? -1,
      route: rawRoute is List
          ? rawRoute.map((e) => '$e').toList(growable: false)
          : null,
      attemptsLeft: (json['attemptsLeft'] as num?)?.toInt() ?? 0,
      nextDueAt: nextDueAt,
      deadline: deadline,
    );
  }
}

/// The result of one transmission attempt.
enum AprsTransmitOutcome {
  /// It went out.
  sent,

  /// There was no way to transmit just now (no radio, no APRS channel). The
  /// attempt is not counted against the message: it is tried again.
  unavailable,
}

/// Resends unacked addressed messages, Yaesu style.
class AprsRetryQueue {
  /// Transmissions per message, the first one included.
  static const int maxAttempts = 5;

  /// Gap between transmissions.
  static const Duration retryInterval = Duration(minutes: 1);

  /// Hard stop, whatever attempts remain. Four retries a minute apart need
  /// four minutes; the rest is room for attempts skipped off the air.
  static const Duration deadline = Duration(minutes: 10);

  /// How often the queue looks for work. Due times are compared against the
  /// clock rather than counted in ticks, so a device that slept catches up.
  static const Duration tickInterval = Duration(seconds: 5);

  /// Sends one attempt. Called for retries only: the first transmission is the
  /// caller's, which is what puts the message in the queue.
  final AprsTransmitOutcome Function(AprsPendingMessage message) onTransmit;

  /// Reports a change the UI should show.
  final void Function(AprsPendingMessage message, AprsDeliveryState state)
  onStateChanged;

  /// Persists the queue. Called whenever it changes.
  final void Function(String json) onPersist;

  /// The clock, injectable so the schedule can be tested without waiting.
  final DateTime Function() now;

  final List<AprsPendingMessage> _pending = [];
  Timer? _timer;
  bool _disposed = false;

  AprsRetryQueue({
    required this.onTransmit,
    required this.onStateChanged,
    required this.onPersist,
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now;

  /// The messages still waiting on an ack.
  List<AprsPendingMessage> get pending => List.unmodifiable(_pending);

  /// Whether [msgId] is waiting on an ack.
  bool isPending(int msgId) => _pending.any((m) => m.msgId == msgId);

  /// Starts watching for due retries. Idempotent.
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(tickInterval, (_) => tick());
  }

  /// Takes on a message that has just been transmitted for the first time.
  void add({
    required int msgId,
    required String destination,
    required String message,
    required int radioDeviceId,
    List<String>? route,
  }) {
    if (_disposed) return;
    // A reused id can only mean the old message is long gone: ids wrap at 999.
    _pending.removeWhere((m) => m.msgId == msgId);
    final at = now();
    final entry = AprsPendingMessage(
      msgId: msgId,
      destination: destination.trim().toUpperCase(),
      message: message,
      radioDeviceId: radioDeviceId,
      route: route,
      attemptsLeft: maxAttempts - 1,
      nextDueAt: at.add(retryInterval),
      deadline: at.add(deadline),
    );
    _pending.add(entry);
    _persist();
    onStateChanged(entry, AprsDeliveryState.pending);
    start();
  }

  /// Resolves the message [msgId] when [from] acks or rejects it.
  ///
  /// The ack comes from the station we addressed, which may answer from
  /// another SSID, so callsigns are compared without them. Returns true when a
  /// pending message was resolved.
  bool resolve(int msgId, String from, {required bool rejected}) {
    final index = _pending.indexWhere((m) => m.msgId == msgId);
    if (index < 0) return false;
    final entry = _pending[index];
    final fromCallsign = _callsignOf(from);
    if (fromCallsign != entry.destinationCallsign) return false;
    _pending.removeAt(index);
    _persist();
    onStateChanged(
      entry,
      rejected ? AprsDeliveryState.rejected : AprsDeliveryState.acked,
    );
    return true;
  }

  /// Stops retrying [msgId] at the user's request. The message stays sent and
  /// unacked; it is only the retransmissions that end.
  bool cancel(int msgId) {
    final index = _pending.indexWhere((m) => m.msgId == msgId);
    if (index < 0) return false;
    final entry = _pending.removeAt(index);
    _persist();
    onStateChanged(entry, AprsDeliveryState.cancelled);
    return true;
  }

  /// Transmits whatever is due and gives up on whatever has run out. Public so
  /// a test can drive the schedule without a timer.
  void tick() {
    if (_disposed || _pending.isEmpty) return;
    final at = now();

    // Copied, because handlers below mutate the list.
    for (final entry in List<AprsPendingMessage>.from(_pending)) {
      if (!_pending.contains(entry)) continue;

      if (!at.isBefore(entry.deadline) ||
          (entry.attemptsLeft <= 0 && !at.isBefore(entry.nextDueAt))) {
        _pending.remove(entry);
        _persist();
        onStateChanged(entry, AprsDeliveryState.failed);
        continue;
      }

      if (at.isBefore(entry.nextDueAt)) continue;

      final outcome = onTransmit(entry);
      if (outcome == AprsTransmitOutcome.unavailable) {
        // Nothing went out, so the attempt is not spent: try again next due
        // time, until the deadline catches it.
        entry.nextDueAt = at.add(retryInterval);
        _persist();
        continue;
      }

      entry.attemptsLeft -= 1;
      entry.nextDueAt = at.add(retryInterval);
      _persist();
      // Still pending even with no attempts left: the last transmission has
      // gone out and has until its due time to be answered, so an ack arriving
      // in that final minute still counts. The tick after that gives up.
      onStateChanged(entry, AprsDeliveryState.pending);
    }
  }

  /// Restores a persisted queue.
  ///
  /// A message whose deadline passed while the app was closed is reported
  /// failed rather than resumed: the far end stopped waiting long ago, and
  /// transmitting it now would be a surprise on the air.
  void restore(String json) {
    if (json.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return;
    }
    if (decoded is! List) return;

    // Replace rather than append, so restoring twice cannot double the queue.
    _pending.clear();
    final at = now();
    final expired = <AprsPendingMessage>[];
    for (final item in decoded) {
      final entry = AprsPendingMessage.fromJson(item);
      if (entry == null) continue;
      if (!at.isBefore(entry.deadline) || entry.attemptsLeft <= 0) {
        expired.add(entry);
        continue;
      }
      _pending.add(entry);
    }
    _persist();
    for (final entry in expired) {
      onStateChanged(entry, AprsDeliveryState.failed);
    }
    for (final entry in _pending) {
      onStateChanged(entry, AprsDeliveryState.pending);
    }
    if (_pending.isNotEmpty) start();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  void _persist() => onPersist(
    jsonEncode(_pending.map((m) => m.toJson()).toList(growable: false)),
  );

  static String _callsignOf(String station) {
    final trimmed = station.trim().toUpperCase();
    final dash = trimmed.indexOf('-');
    return dash < 0 ? trimmed : trimmed.substring(0, dash);
  }
}
