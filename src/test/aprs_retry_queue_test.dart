/*
Copyright 2026 Ylian Saint-Hilaire

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/aprs_retry_queue.dart';

void main() {
  late DateTime clock;
  late List<AprsPendingMessage> transmissions;
  late List<(int, AprsDeliveryState)> states;
  late String persisted;
  late AprsRetryQueue queue;
  late AprsTransmitOutcome outcome;

  /// Builds a queue on the fake clock. [restore] seeds it from saved state.
  AprsRetryQueue makeQueue() => AprsRetryQueue(
    clock: () => clock,
    onTransmit: (message) {
      transmissions.add(message);
      return outcome;
    },
    onStateChanged: (message, state) => states.add((message.msgId, state)),
    onPersist: (json) => persisted = json,
  );

  /// Moves the clock on and lets the queue act, the way its timer would.
  void advance(Duration by) {
    clock = clock.add(by);
    queue.tick();
  }

  void addMessage({int msgId = 7, String destination = 'W1XYZ-5'}) {
    queue.add(
      msgId: msgId,
      destination: destination,
      message: 'hello there',
      radioDeviceId: 2,
      route: const ['Wide', 'APN000', 'WIDE1-1'],
    );
  }

  setUp(() {
    clock = DateTime(2026, 10, 29, 12, 0, 0);
    transmissions = [];
    states = [];
    persisted = '';
    outcome = AprsTransmitOutcome.sent;
    queue = makeQueue();
  });

  tearDown(() => queue.dispose());

  test('resends a minute after the message went out', () {
    addMessage();
    expect(queue.isPending(7), isTrue);
    expect(transmissions, isEmpty, reason: 'the caller sent the first copy');

    advance(const Duration(seconds: 55));
    expect(transmissions, isEmpty);

    advance(const Duration(seconds: 10));
    expect(transmissions.length, 1);
    expect(transmissions.single.msgId, 7);
    expect(transmissions.single.message, 'hello there');
    expect(transmissions.single.route, ['Wide', 'APN000', 'WIDE1-1']);
  });

  test('makes five transmissions in all, then gives up', () {
    addMessage();
    // Four retries, one a minute, on top of the caller's first copy.
    for (var i = 0; i < 4; i++) {
      advance(const Duration(minutes: 1));
    }
    expect(transmissions.length, 4);
    expect(queue.isPending(7), isTrue, reason: 'the last copy has its minute');

    // The minute after the last copy goes unanswered: TX OUT.
    advance(const Duration(minutes: 1));
    expect(transmissions.length, 4);
    expect(queue.isPending(7), isFalse);
    expect(states.last, (7, AprsDeliveryState.failed));
  });

  test('counts the attempts left down for the display', () {
    addMessage();
    advance(const Duration(minutes: 1));
    expect(states.last, (7, AprsDeliveryState.pending));
    expect(queue.pending.single.attemptsLeft, 3);
    advance(const Duration(minutes: 1));
    expect(queue.pending.single.attemptsLeft, 2);
  });

  test('an ack ends it', () {
    addMessage();
    expect(queue.resolve(7, 'W1XYZ-5', rejected: false), isTrue);
    expect(queue.isPending(7), isFalse);
    expect(states.last, (7, AprsDeliveryState.acked));

    advance(const Duration(minutes: 5));
    expect(transmissions, isEmpty);
  });

  test('an ack from another SSID of the same station counts', () {
    addMessage();
    expect(queue.resolve(7, 'W1XYZ-9', rejected: false), isTrue);
    expect(queue.isPending(7), isFalse);
  });

  test('an ack from an unrelated station does not', () {
    addMessage();
    expect(queue.resolve(7, 'N0CALL-1', rejected: false), isFalse);
    expect(queue.isPending(7), isTrue);
  });

  test('a rejection ends it too', () {
    addMessage();
    expect(queue.resolve(7, 'W1XYZ-5', rejected: true), isTrue);
    expect(states.last, (7, AprsDeliveryState.rejected));
  });

  test('an attempt that could not be transmitted is not spent', () {
    addMessage();
    outcome = AprsTransmitOutcome.unavailable;
    advance(const Duration(minutes: 1));
    expect(transmissions.length, 1, reason: 'tried, but nothing went out');
    expect(queue.pending.single.attemptsLeft, 4);

    outcome = AprsTransmitOutcome.sent;
    advance(const Duration(minutes: 1));
    expect(queue.pending.single.attemptsLeft, 3);
  });

  test('an off-the-air message is given up on at the deadline', () {
    addMessage();
    outcome = AprsTransmitOutcome.unavailable;
    advance(AprsRetryQueue.deadline + const Duration(minutes: 1));
    expect(queue.isPending(7), isFalse);
    expect(states.last, (7, AprsDeliveryState.failed));
  });

  test('cancelling stops the retries and says so', () {
    addMessage();
    expect(queue.cancel(7), isTrue);
    expect(queue.isPending(7), isFalse);
    expect(states.last, (7, AprsDeliveryState.cancelled));

    advance(const Duration(minutes: 5));
    expect(transmissions, isEmpty);
    expect(queue.cancel(7), isFalse);
  });

  test('a saved queue comes back and carries on', () {
    addMessage();
    final saved = persisted;
    queue.dispose();

    queue = makeQueue();
    queue.restore(saved);
    expect(queue.isPending(7), isTrue);
    expect(states.last, (7, AprsDeliveryState.pending));

    advance(const Duration(minutes: 1));
    expect(transmissions.length, 1);
  });

  test('restoring twice does not double the queue', () {
    addMessage();
    final saved = persisted;
    queue.dispose();

    queue = makeQueue();
    queue.restore(saved);
    queue.restore(saved);
    expect(queue.pending.length, 1);
  });

  test('a message whose deadline passed while closed comes back failed', () {
    addMessage();
    final saved = persisted;
    queue.dispose();

    clock = clock.add(const Duration(hours: 2));
    queue = makeQueue();
    queue.restore(saved);
    expect(queue.isPending(7), isFalse);
    expect(states.last, (7, AprsDeliveryState.failed));

    advance(const Duration(minutes: 1));
    expect(transmissions, isEmpty, reason: 'nothing is put on the air late');
  });

  test('ignores a saved queue it cannot read', () {
    queue.restore('not json at all');
    expect(queue.pending, isEmpty);
  });
}
