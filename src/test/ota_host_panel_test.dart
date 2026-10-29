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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/aprs_ota_host_panel.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/ota/ota_host_session.dart';

void main() {
  /// Pumps past a dialog's open or close animation. The panel ticks once a
  /// second to drive its countdowns, so nothing here can settle.
  Future<void> pumpTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('sending a QSL closes the composer and keeps the panel up', (
    tester,
  ) async {
    final session = OtaHostSession.instance;
    session.reset();
    session.ingestBotMessage(
      'K7ABC-6 is on the air from DN40fb. aprsota.org/K7ABC',
    );
    session.ingestBotMessage('DE W1XYZ-5 DN40fb greetings from mike');

    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AprsOtaHostPanel(
            onSendCommand: (message) async {
              sent.add(message);
              return true;
            },
            onRequestBeacon: () {},
            transmitsOverRf: true,
          ),
        ),
      ),
    );
    await tester.pump();

    // The chaser the bot relayed is waiting on a QSL, listed once: attaching
    // the session restores the saved op rather than doubling what is held.
    expect(find.text('W1XYZ-5'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'QSL').first);
    await pumpTransition(tester);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'thx for the contact 73');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'QSL'),
      ),
    );
    // The composer's controller must outlive the route's exit animation:
    // disposing it with the field still on screen tore the tree down with
    // '_dependents.isEmpty'.
    await pumpTransition(tester);

    expect(sent, ['QSL W1XYZ-5 thx for the contact 73']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    // The QSL answered the only chaser, so the queue is empty but the op is
    // still on the air.
    expect(find.text('W1XYZ-5'), findsNothing);
    expect(find.textContaining('is on the air'), findsOneWidget);

    session.reset();
  });
}
