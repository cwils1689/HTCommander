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
import 'package:htcommander/widgets/chat_widget.dart';

void main() {
  /// A sent message, optionally still counting down its transmissions.
  ChatMessage message({String? badge, IconData icon = Icons.schedule}) =>
      ChatMessage(
        id: '1',
        route: '→ W1XYZ-5',
        senderCallsign: 'K7ABC-6',
        message: 'hello there',
        time: DateTime(2026, 10, 29, 12),
        isSender: true,
        icon: icon,
        iconBadge: badge,
      );

  Future<void> pumpChat(WidgetTester tester, ChatMessage chatMessage) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatWidget(messages: [chatMessage])),
      ),
    );
    await tester.pump();
  }

  testWidgets('a waiting message shows the transmissions it has left', (
    tester,
  ) async {
    await pumpChat(tester, message(badge: '3'));
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a message with nothing to count down shows no badge', (
    tester,
  ) async {
    await pumpChat(tester, message());
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.text('3'), findsNothing);
  });

  testWidgets('a message given up on shows the failed icon', (tester) async {
    await pumpChat(tester, message(icon: Icons.error_outline));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
