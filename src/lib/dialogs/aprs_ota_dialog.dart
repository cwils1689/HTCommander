/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// aprs_ota_dialog.dart - "APRS OTA: on the air now".
//
// Lists the ops currently on the air (from aprsota.org) and lets the user
// chase one by tapping it. Chasing sends `CHASE <callsign>` to the `OTA` bot
// as an ordinary addressed APRS message, which the APRS tab then threads as a
// normal conversation with OTA.
//

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../aprs/weather_data.dart';
import '../gps/gps_data.dart';
import '../l10n/app_localizations.dart';
import '../ota/ota_client.dart';
import '../ota/ota_models.dart';
import '../radio/repeaterbook_client.dart';
import '../services/data_broker_client.dart';
import 'dialog_utils.dart';

/// What the user chose to do in the dialog.
class AprsOtaChaseRequest {
  /// The host callsign to chase.
  final String callsign;

  const AprsOtaChaseRequest(this.callsign);
}

/// Shows the OTA ops list. Returns the op the user chose to chase, or null.
Future<AprsOtaChaseRequest?> showAprsOtaDialog(BuildContext context) {
  return showDialog<AprsOtaChaseRequest>(
    context: context,
    builder: (_) => const _AprsOtaDialog(),
  );
}

class _AprsOtaDialog extends StatefulWidget {
  const _AprsOtaDialog();

  @override
  State<_AprsOtaDialog> createState() => _AprsOtaDialogState();
}

class _AprsOtaDialogState extends State<_AprsOtaDialog> {
  final DataBrokerClient _broker = DataBrokerClient();
  final OtaClient _client = OtaClient.instance;
  final TextEditingController _tokenController = TextEditingController();

  bool _loading = false;
  OtaFetchStatus _status = OtaFetchStatus.ok;
  String? _error;
  List<OtaOp> _ops = const [];
  DateTime? _generatedAt;

  @override
  void initState() {
    super.initState();
    _tokenController.text = _client.token ?? '';
    if (_client.hasToken) {
      _refresh();
    } else {
      _status = OtaFetchStatus.noToken;
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _client.fetchNow(force: force);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _status = result.status;
      _error = result.message;
      if (result.now != null) {
        _ops = result.now!.onAir;
        _generatedAt = result.now!.generatedAt;
      }
    });
  }

  void _saveToken() {
    final value = _tokenController.text.trim();
    if (value.isEmpty) return;
    _client.token = value;
    setState(() => _status = OtaFetchStatus.ok);
    _refresh(force: true);
  }

  Future<void> _openHandbook() async {
    await launchUrl(
      Uri.parse(OtaClient.handbookUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _openOpPage(OtaOp op) async {
    final url = op.url;
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Our own position, for the distance column. Null when we have no fix.
  GpsData? _ourFix() {
    final raw = _broker.getValueDynamic(1, 'GpsData', null);
    GpsData? gps;
    if (raw is GpsData) {
      gps = raw;
    } else if (raw is Map) {
      gps = GpsData.fromJson(Map<String, dynamic>.from(raw));
    }
    if (gps == null || !gps.isFixed) return null;
    if (gps.latitude == 0 && gps.longitude == 0) return null;
    return gps;
  }

  String? _distanceLabel(OtaOp op, GpsData? ours) {
    final pos = op.position;
    if (pos == null || ours == null) return null;
    final km = RepeaterBookClient.distanceKm(
      ours.latitude,
      ours.longitude,
      pos.latitude,
      pos.longitude,
    );
    return WeatherData.systemUsesMetric
        ? '${km.toStringAsFixed(0)} km'
        : '${(km / 1.609344).toStringAsFixed(0)} mi';
  }

  Future<void> _confirmChase(OtaOp op) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.otaChaseTitle(op.callsign)),
        content: Text(l10n.otaChaseBody(op.callsign)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.otaChaseConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(AprsOtaChaseRequest(op.callsign));
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return HTDialog(
      title: l10n.otaTitle,
      maxWidth: 560,
      maxHeight: 620,
      content: _buildBody(l10n),
      actions: [
        if (_client.hasToken)
          TextButton(
            // aprsota.org asks for no more than one poll a minute, so the
            // button waits out the interval rather than letting the user
            // hammer it.
            onPressed: (_loading || !_client.canFetchNow)
                ? null
                : () => _refresh(force: true),
            child: Text(l10n.otaRefresh),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_status == OtaFetchStatus.noToken) return _buildTokenPrompt(l10n);
    if (_loading && _ops.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_status != OtaFetchStatus.ok && _ops.isEmpty) {
      return _buildError(l10n);
    }

    final ours = _ourFix();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_status != OtaFetchStatus.ok) ...[
          _banner(_error ?? l10n.otaErrorGeneric),
          const SizedBox(height: 8),
        ],
        Text(
          _ops.isEmpty ? l10n.otaNobodyOnAir : l10n.otaOnAirCount(_ops.length),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        if (_generatedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              l10n.otaAsOf(_formatLocalTime(_generatedAt!)),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Flexible(
          child: _ops.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.otaNobodyOnAirHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: _ops.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _buildOpRow(l10n, _ops[i], ours),
                ),
        ),
      ],
    );
  }

  Widget _buildOpRow(AppLocalizations l10n, OtaOp op, GpsData? ours) {
    final scheme = Theme.of(context).colorScheme;

    final subtitleParts = <String>[];
    final reference = op.reference;
    if (reference != null) subtitleParts.add(reference.label);
    final distance = _distanceLabel(op, ours);
    if (distance != null) subtitleParts.add(distance);
    if (op.grid != null) subtitleParts.add(op.grid!);
    final minutes = op.minutesLeft();
    if (minutes != null) subtitleParts.add(l10n.otaMinutesLeft(minutes));

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      title: Row(
        children: [
          Expanded(
            child: Text(
              op.callsign,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
          ),
          Text(
            l10n.otaQsoCount(op.qsos),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (op.description != null)
            Text(
              op.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurface),
            ),
          if (subtitleParts.isNotEmpty)
            Text(
              subtitleParts.join('  •  '),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (op.url != null)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              tooltip: l10n.otaOpenOpPage,
              onPressed: () => _openOpPage(op),
            ),
          FilledButton.tonal(
            onPressed: () => _confirmChase(op),
            child: Text(l10n.otaChase),
          ),
        ],
      ),
      onTap: () => _confirmChase(op),
    );
  }

  Widget _buildTokenPrompt(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.otaTokenIntro, style: TextStyle(color: scheme.onSurface)),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.otaTokenLabel,
              hintText: 'aprsota_...',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _saveToken(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: _openHandbook,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(l10n.otaGetToken),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _saveToken,
                child: Text(l10n.otaSaveToken),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildError(AppLocalizations l10n) {
    final String text;
    switch (_status) {
      case OtaFetchStatus.unauthorized:
        text = _error ?? l10n.otaErrorUnauthorized;
      case OtaFetchStatus.rateLimited:
        text = _error ?? l10n.otaErrorRateLimited;
      default:
        text = _error ?? l10n.otaErrorGeneric;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (_status == OtaFetchStatus.unauthorized)
              TextButton(
                onPressed: () =>
                    setState(() => _status = OtaFetchStatus.noToken),
                child: Text(l10n.otaChangeToken),
              ),
          ],
        ),
      ),
    );
  }

  Widget _banner(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber,
            size: 16,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatLocalTime(DateTime utc) {
    final local = utc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}
