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
import 'package:htcommander/ota/ota_host_session.dart';

void main() {
  final session = OtaHostSession.instance;

  setUp(() => session.reset());

  group('command strings', () {
    test('HOST carries the description, collapsed to one line', () {
      expect(OtaHostSession.hostCommand(''), 'HOST');
      expect(OtaHostSession.hostCommand('   '), 'HOST');
      expect(
        OtaHostSession.hostCommand('  lakeshore op,\n HT and a stick '),
        'HOST lakeshore op, HT and a stick',
      );
    });

    test('QSL names the chaser, with the message optional', () {
      expect(OtaHostSession.qslCommand('w1xyz-5'), 'QSL W1XYZ-5');
      expect(
        OtaHostSession.qslCommand('w1xyz', 'thx for the contact 73'),
        'QSL W1XYZ thx for the contact 73',
      );
    });

    test('DONE keeps the sign-off', () {
      expect(OtaHostSession.doneCommand(), 'DONE');
      expect(OtaHostSession.doneCommand('gotta go 73'), 'DONE gotta go 73');
    });
  });

  group('reading the bot', () {
    test('HOST then the prompt and confirmation puts the op on the air', () {
      session.noteCommandSent('HOST op from the track');
      expect(session.phase, OtaHostPhase.awaitingBeacon);
      expect(session.description, 'op from the track');

      session.ingestBotMessage(
        'Send a position report within 5 mins to go on the air',
      );
      expect(session.phase, OtaHostPhase.awaitingBeacon);
      expect(session.beaconPromptAt, isNotNull);
      expect(session.beaconSecondsLeft, greaterThan(4 * 60));

      session.ingestBotMessage(
        'K7ABC-6 is on the air from DN40fb. aprsota.org/K7ABC',
      );
      expect(session.phase, OtaHostPhase.onAir);
      expect(session.station, 'K7ABC-6');
      expect(session.location, 'DN40fb');
      expect(session.url, 'https://aprsota.org/K7ABC');
      expect(session.beaconSecondsLeft, isNull);
    });

    test('a missed beacon leaves us off the air, with the reason', () {
      session.noteCommandSent('HOST');
      session.ingestBotMessage('No beacon received. Send HOST to try again.');
      expect(session.phase, OtaHostPhase.idle);
      expect(session.notice, contains('No beacon received'));
    });

    test('an op sent over APRS-IS is refused', () {
      session.noteCommandSent('HOST');
      session.ingestBotMessage(
        'Must transmit via RF to host. aprsota.org/handbook/host-an-op',
      );
      expect(session.phase, OtaHostPhase.idle);
      expect(session.notice, startsWith('Must transmit via RF'));
    });

    test('relayed chases queue up, longest wait first', () {
      session.ingestBotMessage('DE W1XYZ-5 DN40fb greetings from mike');
      session.ingestBotMessage('DE N0CALL-7 DN41aa');
      expect(session.chasers.map((c) => c.station), ['W1XYZ-5', 'N0CALL-7']);
      expect(session.chasers.first.grid, 'DN40fb');
      expect(session.chasers.first.message, 'greetings from mike');
      expect(session.chasers.last.message, isNull);

      // A chaser calling again stays one entry, in their original place.
      session.ingestBotMessage('DE W1XYZ-5 DN40fb still here');
      expect(session.chasers.map((c) => c.station), ['W1XYZ-5', 'N0CALL-7']);
      expect(session.chasers.first.message, 'still here');
    });

    test('a QSL clears the chaser, SSID or not', () {
      session.ingestBotMessage('DE W1XYZ-5 DN40fb hello');
      session.noteCommandSent('QSL W1XYZ thx 73');
      expect(session.chasers, isEmpty);
    });

    test('TIME gives the countdown and what a STAY would add', () {
      session.ingestBotMessage(
        'Off the air in 35 minutes, max 95 minutes. STAY adds 30 mins',
      );
      expect(session.phase, OtaHostPhase.onAir);
      expect(session.minutesLeft, 35);
      expect(session.minutesToCap, 95);
      expect(session.stayAdds, 30);
      expect(session.atCap, isFalse);
    });

    test('a trimmed STAY offer is reported as the bot words it', () {
      session.ingestBotMessage(
        'Off the air in 9 minutes, max 25 minutes. STAY adds 16 mins',
      );
      expect(session.stayAdds, 16);
    });

    test('no STAY offer means the op is at the maximum', () {
      session.ingestBotMessage('At the 2 hour max. Off the air in 12 minutes.');
      expect(session.minutesLeft, 12);
      expect(session.stayAdds, isNull);
      expect(session.atCap, isTrue);
    });

    test('INFO fills in the totals', () {
      session.ingestBotMessage(
        '3 chasing, 12 QSOs, 11 pts, 22 min left. STAY adds 30 mins',
      );
      expect(session.chasing, 3);
      expect(session.qsos, 12);
      expect(session.points, 11);
      expect(session.minutesLeft, 22);
    });

    test('a CHASERS reply replaces the queue, but only when asked', () {
      session.ingestBotMessage('DE W1XYZ-5 DN40fb hello');
      // Unsolicited, this is just a message we do not understand.
      session.ingestBotMessage('N0CALL-7 KJ4HQS-15');
      expect(session.chasers.map((c) => c.station), ['W1XYZ-5']);

      session.noteCommandSent('CHASERS');
      session.ingestBotMessage('N0CALL-7 KJ4HQS-15');
      expect(session.chasers.map((c) => c.station), ['N0CALL-7', 'KJ4HQS-15']);
    });

    test('DONE ends the op only once the bot confirms it', () {
      session.ingestBotMessage(
        'K7ABC-6 is on the air from DN40fb. aprsota.org/K7ABC',
      );
      session.noteCommandSent('DONE thx all 73');
      expect(session.phase, OtaHostPhase.onAir);

      session.ingestBotMessage(
        'Op complete: 12 QSOs, 11 pts. aprsota.org/K7ABC',
      );
      expect(session.phase, OtaHostPhase.ended);
      expect(session.qsos, 12);
      expect(session.points, 11);
      expect(session.summary, contains('Op complete'));
    });
  });

  group('rate limits', () {
    test('a command sent is held back for the interval the bot sets', () {
      expect(session.canSend(OtaHostCommand.stay), isTrue);
      session.noteCommandSent('STAY');
      expect(session.canSend(OtaHostCommand.stay), isFalse);
      expect(session.cooldown(OtaHostCommand.stay).inSeconds, greaterThan(150));
      // QSL is self-limiting, so the bot sets no interval on it.
      session.noteCommandSent('QSL W1XYZ');
      expect(session.canSend(OtaHostCommand.qsl), isTrue);
    });
  });
}
