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
import 'package:htcommander/aprs/aprs_channel.dart';

void main() {
  // A radio with APRS on channel 3 and the operator's chosen data channel,
  // named something else, on channel 5.
  const channels = <AprsChannelOption>[
    (id: 0, name: 'National'),
    (id: 3, name: 'APRS'),
    (id: 5, name: 'DIGITAL'),
  ];

  group('AprsChannel.resolve', () {
    test('the radio\'s chosen channel wins over one named APRS', () {
      // autoShareLocCh counts from 1, so 6 is channel id 5.
      expect(AprsChannel.resolve(autoShareLocCh: 6, channels: channels), 5);
    });

    test('"Current channel" leaves the name to decide', () {
      expect(
        AprsChannel.resolve(
          autoShareLocCh: AprsChannel.currentChannel,
          channels: channels,
        ),
        3,
      );
    });

    test('a choice the radio no longer has falls back to the name', () {
      expect(AprsChannel.resolve(autoShareLocCh: 99, channels: channels), 3);
    });

    test('the chosen channel wins even when it is the one named APRS', () {
      expect(AprsChannel.resolve(autoShareLocCh: 4, channels: channels), 3);
    });

    test('no choice and no APRS channel means none', () {
      expect(
        AprsChannel.resolve(
          autoShareLocCh: AprsChannel.currentChannel,
          channels: const [(id: 0, name: 'National')],
        ),
        -1,
      );
    });

    test('the name match is case sensitive, as the routing is', () {
      expect(
        AprsChannel.resolve(
          autoShareLocCh: AprsChannel.currentChannel,
          channels: const [(id: 2, name: 'aprs')],
        ),
        -1,
      );
    });

    test('a radio with no channels has none', () {
      expect(AprsChannel.resolve(autoShareLocCh: 6, channels: const []), -1);
    });
  });
}
