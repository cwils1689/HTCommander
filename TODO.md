# Fork to-do

Work queued for this fork (`cwils1689/HTCommander`). Fork-local; not intended
for upstream.

## Bugs

### 1. APRS beacon ignores the selected channel

The channel used for APRS is found by matching the channel's **name** against
the literal string `APRS`:

```dart
for (final channel in channels) {
  if (channel.name == 'APRS') return channel.channelId;
}
return -1;
```

There is no setting for it, so selecting a different channel elsewhere (e.g.
channel 8 for crossband repeat) has no effect — everything goes to whichever
channel happens to be named `APRS`. The APRS setup wizard in `aprs_tab.dart`
renames the chosen channel to that literal string and writes it to the radio,
so the choice lives only in the channel's name on the radio itself.

That lookup is duplicated in four files:

- `lib/handlers/aprs_handler.dart`
- `lib/handlers/software_beacon_handler.dart`
- `lib/handlers/digipeater_handler.dart`
- `lib/aprsis/aprsis_manager.dart`

**Fix:** add a real per-radio APRS channel setting, collapse the four copies
into one helper that prefers the setting and falls back to the name match so
existing setups keep working, and add UI to choose it.

Also affects APRS OTA (feature 4): every command to the `OTA` bot, chasing
and hosting alike, goes out through the same lookup — and hosting is
declined outright unless the command reaches the bot over RF.

### 2. Some messages do not appear when they repeat earlier text — FIXED

In `aprs_tab.dart` (`_addEntry`, around the `duplicatesToRemove` loop), message
de-duplication matches on sender + addressee + message text across **every**
entry held, with **no time window** and **without comparing the APRS message
ID**:

```dart
// Same origin: collapse retransmissions, keeping the oldest copy.
if (!n.time.isAfter(entry.time)) return;
```

So sending or receiving the same text to the same station again — minutes,
hours or days later — is silently swallowed as a retransmission of the first
one. The non-message branch directly below gets this right, using a 5-minute
window.

**Fixed** by `_isSameMessageRetransmission` in `aprs_tab.dart`: the APRS
sequence id is compared when both copies carry one, so different ids are kept
as different messages; copies with no id fall back to a 5-minute window, and
id matches are bounded to an hour because the outgoing id counter restarts
with the app. The RF-beats-internet rule above it is untouched.

Note the interaction with the retry feature below: that feature *depends* on
same-ID retransmissions still collapsing, so these two want designing
together.

## Features

### 3. Resend messages until an ack is received

Like the Yaesu FT-3DR: after sending an addressed APRS message, retry it until
the addressee acks, rather than sending once and hoping.

There is **no retry logic at all** today. `aprs_handler.dart` allocates a
message ID (`_getNextAprsMessageId`) and transmits once; incoming acks are
parsed but nothing is waiting on them.

Needs:

- A pending-message store keyed by message ID, with attempt count and next-due
  time, surviving app restarts.
- Retransmit on a backoff (APRS practice is roughly 30 s growing to a few
  minutes) with a cap on attempts and a total deadline.
- Cancel on ack, on reject, or when the user withdraws it.
- UI state per message: pending / acked / gave up, so a failed delivery is
  visible rather than silent.
- Reuse the **same** message ID on every retry, so the receiving station
  recognises retransmissions and de-duplicates them — and so bug 2's fix does
  not treat them as separate messages.

### 4. APRS OTA (aprsota.org) — DONE

On-the-air activity run through the `OTA` APRS bot: a host goes on the air from
wherever they are and chasers work them, with the website scoring it.

**Chasing** is `APRS OTA...` in the APRS tab menu: `lib/ota/ota_client.dart`
reads `/api/v1/now` (bearer token pasted by the user, kept at device 0 as
`OtaApiToken`; polled at most once a minute, with If-None-Match), and
`lib/dialogs/aprs_ota_dialog.dart` lists the ops on the air with distance from
our own fix. Picking one sends `CHASE <callsign>` and a beacon behind it.

**Hosting** is `Host an Op...` in the same menu.
`lib/ota/ota_host_session.dart` holds the op: the bot's replies are the only
source of truth, since there is no host-side API, so it parses the beacon
prompt, the on-air confirmation, the no-beacon nudges, `DE` chase relays, the
TIME/STAY/INFO timings, the CHASERS queue and `Op complete`. It also builds the
command strings and holds each command back for the interval the bot documents,
because tripping a rate limit just makes the bot go quiet. State is persisted
as `OtaHostOpState` and timed out on restore against the bot's own limits (the
5-minute beacon window, the 2-hour op cap) so a stale op never reads as live.
`lib/dialogs/aprs_ota_host_dialog.dart` is the console over it: preflight
checks that block a doomed HOST (no callsign, no RF-capable radio, status-only
beacon), the countdown while the bot waits for a position report, then the op's
numbers, the queue of chasers waiting on a QSL, and STAY / TIME / INFO /
CHASERS / BLAST / QSL / DONE. The APRS tab keeps the radio and passes in the
send and beacon callbacks.

Parsing of the bot's replies is covered by `test/ota_host_session_test.dart`.

Still open on this:

- The new strings exist in English only (`app_en.arb`); the other locales fall
  back to English, as the rest of the OTA strings already do.
- Hosting inherits bug 1 above: the commands go out on whichever channel
  happens to be named `APRS`.
