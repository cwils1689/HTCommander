/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// aprs_ota_host_dialog.dart - "APRS OTA: host an op".
//
// The host side of APRS OTA, which is a conversation with the `OTA` bot: HOST
// goes out, a position report follows within five minutes, and the bot puts the
// op on the air. From there the dialog is a console for the op — the chasers
// waiting on a QSL, the time left, and the commands that answer them — built
// entirely out of what the bot has said, since there is no API for the host.
//
// Nothing here touches the radio: the APRS tab owns that and passes in
// [onSendCommand] and [onRequestBeacon].
//

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../gps/gps_data.dart';
import '../handlers/software_beacon_config.dart';
import '../l10n/app_localizations.dart';
import '../ota/ota_client.dart';
import '../ota/ota_host_session.dart';
import '../services/data_broker_client.dart';
import 'dialog_utils.dart';

/// Shows the host console.
///
/// [onSendCommand] puts one message body on the air addressed to the OTA bot
/// and reports whether it went. [onRequestBeacon] asks the software beacon for
/// a one-off position report, which is what actually starts and sustains an op.
Future<void> showAprsOtaHostDialog(
  BuildContext context, {
  required Future<bool> Function(String message) onSendCommand,
  required VoidCallback onRequestBeacon,
  required bool transmitsOverRf,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AprsOtaHostDialog(
      onSendCommand: onSendCommand,
      onRequestBeacon: onRequestBeacon,
      transmitsOverRf: transmitsOverRf,
    ),
  );
}

class _AprsOtaHostDialog extends StatefulWidget {
  final Future<bool> Function(String message) onSendCommand;
  final VoidCallback onRequestBeacon;
  final bool transmitsOverRf;

  const _AprsOtaHostDialog({
    required this.onSendCommand,
    required this.onRequestBeacon,
    required this.transmitsOverRf,
  });

  @override
  State<_AprsOtaHostDialog> createState() => _AprsOtaHostDialogState();
}

class _AprsOtaHostDialogState extends State<_AprsOtaHostDialog> {
  final DataBrokerClient _broker = DataBrokerClient();
  final OtaHostSession _session = OtaHostSession.instance;
  final TextEditingController _descriptionController = TextEditingController();

  /// Ticks the countdowns and the rate-limit cooldowns.
  Timer? _ticker;

  /// Set while a command is in flight, so a button cannot be double-sent.
  bool _sending = false;

  /// The last beacon this dialog asked for, so the prompt does not produce a
  /// second one right behind the first.
  DateTime? _lastBeaconAt;
  DateTime? _handledPrompt;

  @override
  void initState() {
    super.initState();
    _session.attach();
    _session.addListener(_onSessionChanged);
    _descriptionController.text = _session.phase == OtaHostPhase.idle
        ? ''
        : (_session.description ?? '');
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _session.removeListener(_onSessionChanged);
    _descriptionController.dispose();
    _broker.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    _beaconForPromptIfNeeded();
  }

  /// The bot asks for a position report after HOST. One already went out with
  /// the command, so only beacon again if that was a while ago.
  void _beaconForPromptIfNeeded() {
    final prompt = _session.beaconPromptAt;
    if (prompt == null || prompt == _handledPrompt) return;
    _handledPrompt = prompt;
    final last = _lastBeaconAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 45)) {
      return;
    }
    _beacon();
  }

  void _beacon() {
    _lastBeaconAt = DateTime.now();
    widget.onRequestBeacon();
  }

  // --- Sending -------------------------------------------------------------

  Future<void> _send(String message, {bool beaconAfter = false}) async {
    if (_sending) return;
    setState(() => _sending = true);
    final sent = await widget.onSendCommand(message);
    if (sent) {
      _session.noteCommandSent(message);
      if (beaconAfter) _beacon();
    }
    if (!mounted) return;
    setState(() => _sending = false);
  }

  Future<void> _goOnAir() async {
    // A position report has to follow the command, so send one straight away
    // rather than waiting for the bot's prompt to reach us.
    await _send(
      OtaHostSession.hostCommand(_descriptionController.text),
      beaconAfter: true,
    );
  }

  Future<void> _qsl(OtaChaser chaser) async {
    final message = await _promptForText(
      title: AppLocalizations.of(context).otaHostQslTitle(chaser.station),
      body: AppLocalizations.of(context).otaHostQslBody(chaser.station),
      label: AppLocalizations.of(context).otaHostQslMessageLabel,
      hint: AppLocalizations.of(context).otaHostQslMessageHint,
      confirm: AppLocalizations.of(context).otaHostQsl,
    );
    if (message == null) return;
    await _send(OtaHostSession.qslCommand(chaser.station, message));
  }

  Future<void> _blast() async {
    final l10n = AppLocalizations.of(context);
    final text = await _promptForText(
      title: l10n.otaHostBlastTitle,
      body: l10n.otaHostBlastBody,
      label: l10n.otaHostBlastLabel,
      hint: l10n.otaHostBlastHint,
      confirm: l10n.otaHostBlastSend,
      requireText: true,
    );
    if (text == null || text.isEmpty) return;
    await _send(OtaHostSession.blastCommand(text));
  }

  Future<void> _done() async {
    final l10n = AppLocalizations.of(context);
    final signoff = await _promptForText(
      title: l10n.otaHostDoneTitle,
      body: l10n.otaHostDoneBody,
      label: l10n.otaHostSignoffLabel,
      hint: l10n.otaHostSignoffHint,
      confirm: l10n.otaHostDoneConfirm,
    );
    if (signoff == null) return;
    await _send(OtaHostSession.doneCommand(signoff));
  }

  /// A small composer used for the QSL, BLAST and DONE free text. Returns null
  /// when the user backs out, or the (possibly empty) text they entered.
  Future<String?> _promptForText({
    required String title,
    required String body,
    required String label,
    required String hint,
    required String confirm,
    bool requireText = false,
  }) async {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(body),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: _maxFreeTextLength,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setInner(() {}),
                onSubmitted: (value) {
                  if (requireText && value.trim().isEmpty) return;
                  Navigator.of(ctx).pop(value.trim());
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: (requireText && controller.text.trim().isEmpty)
                  ? null
                  : () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(confirm),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  // --- Preflight -----------------------------------------------------------

  SoftwareBeaconConfig _beaconConfig() {
    final raw = _broker.getValueDynamic(0, 'SoftwareBeaconConfig', null);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return SoftwareBeaconConfig.fromJson(decoded);
        }
      } catch (_) {
        // Fall through to the default.
      }
    }
    if (raw is Map<String, dynamic>) return SoftwareBeaconConfig.fromJson(raw);
    return const SoftwareBeaconConfig();
  }

  bool _hasFix() {
    final raw = _broker.getValueDynamic(1, 'GpsData', null);
    GpsData? gps;
    if (raw is GpsData) {
      gps = raw;
    } else if (raw is Map) {
      gps = GpsData.fromJson(Map<String, dynamic>.from(raw));
    }
    if (gps == null || !gps.isFixed) return false;
    return !(gps.latitude == 0 && gps.longitude == 0);
  }

  /// Everything that would stop an op from starting, worst first.
  List<_Warning> _warnings(AppLocalizations l10n) {
    final warnings = <_Warning>[];
    if (_session.localStation() == null) {
      warnings.add(_Warning(l10n.otaHostNoCallsign, blocking: true));
    }
    if (!widget.transmitsOverRf) {
      warnings.add(_Warning(l10n.otaHostRfWarning, blocking: true));
    }
    final beacon = _beaconConfig();
    if (!beacon.includeLocation) {
      warnings.add(_Warning(l10n.otaHostBeaconLocationWarning, blocking: true));
    } else if (!_hasFix()) {
      warnings.add(_Warning(l10n.otaHostNoFixWarning));
    }
    if (!beacon.isActive) {
      warnings.add(_Warning(l10n.otaHostBeaconOffWarning));
    } else if (beacon.enabled && beacon.intervalSeconds > 15 * 60) {
      warnings.add(_Warning(l10n.otaHostBeaconIntervalWarning));
    }
    return warnings;
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return HTDialog(
      title: l10n.otaHostTitle,
      maxWidth: 580,
      maxHeight: 680,
      content: _buildBody(l10n),
      actions: [
        TextButton(
          onPressed: () => launchUrl(
            Uri.parse(OtaClient.hostHandbookUrl),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(l10n.otaHostHandbook),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    switch (_session.phase) {
      case OtaHostPhase.idle:
        return _buildStart(l10n);
      case OtaHostPhase.awaitingBeacon:
        return _buildAwaitingBeacon(l10n);
      case OtaHostPhase.onAir:
        return _buildOnAir(l10n);
      case OtaHostPhase.ended:
        return _buildEnded(l10n);
    }
  }

  /// Not hosting: the preflight checks, the description, and the one button
  /// that starts an op.
  Widget _buildStart(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final station = _session.localStation();
    final warnings = _warnings(l10n);
    final blocked = warnings.any((w) => w.blocking);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.otaHostIntro, style: TextStyle(color: scheme.onSurface)),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.radio, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                l10n.otaHostStation(station ?? '—'),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            maxLength: _maxFreeTextLength,
            decoration: InputDecoration(
              labelText: l10n.otaHostDescriptionLabel,
              hintText: l10n.otaHostDescriptionHint,
              helperText: l10n.otaHostDescriptionHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          for (final warning in warnings) ...[
            const SizedBox(height: 8),
            _banner(warning.text, severe: warning.blocking),
          ],
          if (_session.notice != null) ...[
            const SizedBox(height: 8),
            _banner(_session.notice!, severe: true, onDismiss: _dismissNotice),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (blocked || _sending) ? null : _goOnAir,
            icon: const Icon(Icons.cell_tower, size: 18),
            label: Text(l10n.otaHostGoOnAir),
          ),
        ],
      ),
    );
  }

  /// HOST is out and the bot wants a position report inside five minutes.
  Widget _buildAwaitingBeacon(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final seconds = _session.beaconSecondsLeft ?? 0;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.otaHostAwaiting,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.otaHostAwaitingBody(_formatCountdown(seconds)),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (_session.description != null) ...[
            const SizedBox(height: 10),
            Text(
              _session.description!,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: scheme.onSurface,
              ),
            ),
          ],
          if (_session.notice != null) ...[
            const SizedBox(height: 10),
            _banner(_session.notice!, severe: true, onDismiss: _dismissNotice),
          ],
          if (_session.lastBotMessage != null) ...[
            const SizedBox(height: 10),
            _lastReply(l10n),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _beacon,
                icon: const Icon(Icons.my_location, size: 16),
                label: Text(l10n.otaHostBeaconAgain),
              ),
              const Spacer(),
              TextButton(
                onPressed: _session.reset,
                child: Text(l10n.otaHostStopWaiting),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// On the air: the op's numbers, the queue of chasers, and the commands.
  Widget _buildOnAir(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final chasers = _session.chasers;
    final minutes = _session.minutesLeft;

    final facts = <String>[];
    if (_session.location != null) facts.add(_session.location!);
    if (minutes != null) facts.add(l10n.otaHostMinutesLeft(minutes));
    if (_session.qsos != null) facts.add(l10n.otaQsoCount(_session.qsos!));
    if (_session.points != null)
      facts.add(l10n.otaHostPoints(_session.points!));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.cell_tower, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.otaHostOnAir(_session.station ?? '—'),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (_session.url != null)
              IconButton(
                icon: const Icon(Icons.open_in_new, size: 18),
                tooltip: l10n.otaOpenOpPage,
                onPressed: () => launchUrl(
                  Uri.parse(_session.url!),
                  mode: LaunchMode.externalApplication,
                ),
              ),
          ],
        ),
        if (facts.isNotEmpty)
          Text(
            facts.join('  •  '),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        if (_session.description != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _session.description!,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: scheme.onSurface,
              ),
            ),
          ),
        if (_session.minutesLeft == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l10n.otaHostAskTimeHint,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        if (_session.notice != null) ...[
          const SizedBox(height: 8),
          _banner(_session.notice!, onDismiss: _dismissNotice),
        ],
        const SizedBox(height: 10),
        _buildCommandBar(l10n),
        const Divider(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.otaHostChasersWaiting(chasers.length),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (_session.chasing != null && _session.chasing! > 0)
              Text(
                l10n.otaHostChasingCount(_session.chasing!),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Flexible(
          child: chasers.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    l10n.otaHostNoChasers,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: chasers.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _buildChaserRow(l10n, chasers[i]),
                ),
        ),
      ],
    );
  }

  /// The op commands, each held back while the bot's rate limit is running.
  Widget _buildCommandBar(AppLocalizations l10n) {
    final stayAdds = _session.stayAdds;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _commandButton(
          label: stayAdds == null
              ? l10n.otaHostStay
              : l10n.otaHostStayAdds(stayAdds),
          command: OtaHostCommand.stay,
          enabled: !_session.atCap,
          onPressed: () => _send(OtaHostSession.stayCommand),
        ),
        _commandButton(
          label: l10n.otaHostTime,
          command: OtaHostCommand.time,
          onPressed: () => _send(OtaHostSession.timeCommand),
        ),
        _commandButton(
          label: l10n.otaHostInfo,
          command: OtaHostCommand.info,
          onPressed: () => _send(OtaHostSession.infoCommand),
        ),
        _commandButton(
          label: l10n.otaHostChasers,
          command: OtaHostCommand.chasers,
          onPressed: () => _send(OtaHostSession.chasersCommand),
        ),
        _commandButton(
          label: l10n.otaHostBlast,
          command: OtaHostCommand.blast,
          onPressed: _blast,
        ),
        FilledButton.tonalIcon(
          onPressed: _sending ? null : _done,
          icon: const Icon(Icons.stop_circle_outlined, size: 16),
          label: Text(l10n.otaHostDone),
        ),
      ],
    );
  }

  Widget _commandButton({
    required String label,
    required OtaHostCommand command,
    required VoidCallback onPressed,
    bool enabled = true,
  }) {
    final cooldown = _session.cooldown(command);
    final waiting = cooldown > Duration.zero;
    return OutlinedButton(
      onPressed: (!enabled || waiting || _sending) ? null : onPressed,
      child: Text(
        waiting
            ? AppLocalizations.of(
                context,
              ).otaHostCooldown(label, cooldown.inSeconds)
            : label,
      ),
    );
  }

  Widget _buildChaserRow(AppLocalizations l10n, OtaChaser chaser) {
    final scheme = Theme.of(context).colorScheme;
    final details = <String>[];
    if (chaser.grid != null) details.add(chaser.grid!);
    details.add(_formatLocalTime(chaser.at));

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      title: Text(
        chaser.station,
        style: TextStyle(fontWeight: FontWeight.bold, color: scheme.onSurface),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chaser.message != null)
            Text(
              chaser.message!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurface),
            ),
          Text(
            details.join('  •  '),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      trailing: FilledButton.tonal(
        onPressed: _sending ? null : () => _qsl(chaser),
        child: Text(l10n.otaHostQsl),
      ),
      onTap: _sending ? null : () => _qsl(chaser),
    );
  }

  /// The op is over: the bot's own summary, and a way back to the start.
  Widget _buildEnded(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final waiting = _session.chasers;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.otaHostEnded,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _session.summary ?? l10n.otaHostEndedUnknown,
            style: TextStyle(color: scheme.onSurface),
          ),
          if (waiting.isNotEmpty) ...[
            const SizedBox(height: 10),
            _banner(
              l10n.otaHostEndedUnanswered(
                waiting.map((c) => c.station).join(' '),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              if (_session.url != null)
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(_session.url!),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(l10n.otaOpenOpPage),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  _descriptionController.text = _session.description ?? '';
                  _session.reset();
                },
                child: Text(l10n.otaHostAnother),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _dismissNotice() => _session.clearNotice();

  Widget _lastReply(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      l10n.otaHostLastReply(_session.lastBotMessage!),
      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
    );
  }

  Widget _banner(String text, {bool severe = false, VoidCallback? onDismiss}) {
    final scheme = Theme.of(context).colorScheme;
    final background = severe
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = severe
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: foreground),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: foreground),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: Icon(Icons.close, size: 14, color: foreground),
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }

  /// "4:05" for the beacon window's remaining seconds.
  static String _formatCountdown(int seconds) {
    final mm = seconds ~/ 60;
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  static String _formatLocalTime(DateTime time) {
    final local = time.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// A preflight problem. [blocking] ones stop an op from being started at all.
class _Warning {
  final String text;
  final bool blocking;

  const _Warning(this.text, {this.blocking = false});
}

/// The bot cuts a command's free text to fit one APRS message, so there is no
/// point letting the user type much past that.
const int _maxFreeTextLength = 55;
