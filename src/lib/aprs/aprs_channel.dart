/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// aprs_channel.dart - Which channel a radio uses for APRS.
//
// The app routes APRS by the channel being named `APRS`: the radio layer tags
// each frame with its channel name, and the handlers, the decoder and the
// packet store all key off that name. The name was also the only way to choose
// the channel, so a radio with APRS on a channel called anything else carried
// no APRS at all, and the APRS setup wizard worked by renaming a channel.
//
// The radio already knows better. Its "auto share location channel"
// (`RadioSettings.autoShareLocCh`, set in the radio's own menu and in the
// beacon settings dialog) is the channel it shares position on, which is the
// channel its APRS traffic belongs to. When it is set, it wins; when it is
// left on "Current", the name match is still what decides.
//
// Everything else in the app keeps seeing the name `APRS`: [Radio] stamps that
// name on frames for whichever channel this resolves to, so one answer here
// settles transmit and receive alike.
//

import '../models/radio_models.dart';
import '../services/data_broker.dart';

/// One channel, as little of it as choosing needs.
typedef AprsChannelOption = ({int id, String name});

class AprsChannel {
  AprsChannel._();

  /// The channel name the app routes APRS on. A channel carrying this name is
  /// the APRS channel when the radio names no other, and frames on the chosen
  /// channel are tagged with it whatever the channel is really called.
  static const String channelName = 'APRS';

  /// "Current channel", the radio's value for sharing location on whatever
  /// channel it happens to be on rather than a fixed one.
  static const int currentChannel = 0;

  /// The channel id APRS belongs on, or -1 when there is none.
  ///
  /// [autoShareLocCh] is the radio's setting, which counts from 1 with 0
  /// meaning "current channel". It wins whenever it names a channel that
  /// exists; otherwise the channel named [channelName] decides, as it always
  /// has.
  static int resolve({
    required int autoShareLocCh,
    required Iterable<AprsChannelOption> channels,
  }) {
    if (autoShareLocCh > currentChannel) {
      final chosen = autoShareLocCh - 1;
      for (final channel in channels) {
        if (channel.id == chosen) return channel.id;
      }
    }
    for (final channel in channels) {
      if (channel.name == channelName) return channel.id;
    }
    return -1;
  }

  /// The channel id APRS belongs on for the radio at [radioDeviceId], read
  /// from the broker, or -1 when that radio has none.
  static int channelIdFor(int radioDeviceId) {
    if (radioDeviceId < 0) return -1;
    return resolve(
      autoShareLocCh: _autoShareLocCh(radioDeviceId),
      channels: _channels(radioDeviceId),
    );
  }

  /// Whether the radio at [radioDeviceId] has a channel APRS can use.
  static bool hasAprsChannel(int radioDeviceId) =>
      channelIdFor(radioDeviceId) >= 0;

  /// The radio's chosen channel, ignoring the name match. Null when it is on
  /// "current channel" or names a channel the radio does not have — which is
  /// what the APRS tab needs to tell the user which rule is in force.
  static AprsChannelOption? chosenChannel(int radioDeviceId) {
    if (radioDeviceId < 0) return null;
    final setting = _autoShareLocCh(radioDeviceId);
    if (setting <= currentChannel) return null;
    final chosen = setting - 1;
    for (final channel in _channels(radioDeviceId)) {
      if (channel.id == chosen) return channel;
    }
    return null;
  }

  static int _autoShareLocCh(int radioDeviceId) {
    final raw = DataBroker.getValueDynamic(radioDeviceId, 'Settings', null);
    if (raw is RadioSettings) return raw.autoShareLocCh;
    if (raw is Map) {
      try {
        return RadioSettings.fromJson(
          Map<String, dynamic>.from(raw),
        ).autoShareLocCh;
      } catch (_) {
        return currentChannel;
      }
    }
    return currentChannel;
  }

  static List<AprsChannelOption> _channels(int radioDeviceId) {
    final raw = DataBroker.getValueDynamic(radioDeviceId, 'Channels', null);
    if (raw is! List) return const [];
    final options = <AprsChannelOption>[];
    for (final item in raw) {
      if (item is RadioChannelInfo) {
        options.add((id: item.channelId, name: item.name));
        continue;
      }
      if (item is Map) {
        try {
          final channel = RadioChannelInfo.fromJson(
            Map<String, dynamic>.from(item),
          );
          options.add((id: channel.channelId, name: channel.name));
        } catch (_) {
          // A row we cannot read is a row we cannot choose.
        }
      }
    }
    return options;
  }
}
