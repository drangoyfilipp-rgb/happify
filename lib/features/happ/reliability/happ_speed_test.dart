import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_home.dart';
import 'package:hiddify/features/happ/happ_ping_plan.dart';
import 'package:hiddify/features/happ/happify_offline_ping.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/reliability/happ_notifications.dart';
import 'package:hiddify/features/happ/reliability/happ_notify_rules.dart';
import 'package:hiddify/features/happ/reliability/happ_platform.dart';
import 'package:hiddify/features/happ/reliability/happ_speed_plan.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// «Тест скорости»: by hand only (a long press on a server, or «…» → «Найти самый быстрый»: the top 5
// by ping, then a sheet with the winner and «Переключиться на …»), one server
// after another, through the core's download test, 2–5 MB each (happ_speed_plan.dart).

String happSpeedCacheKey(String profileId) => 'happify_speed_$profileId';

/// Bumped when a result is saved, so the rows read the cache again.
final happSpeedRevision = StateProvider<int>((ref) => 0);

/// The servers being tested now, per profile id.
final happSpeedPending = StateProvider<Map<String, Set<String>>>((ref) => const {});

Map<String, ({int bps, DateTime at})> happSpeedCacheOf(SharedPreferences? prefs, String profileId) =>
    happReadSpeedCache(prefs?.getString(happSpeedCacheKey(profileId)));

final _running = <String>{};

void _snack(BuildContext context, String ru, String en) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: const Duration(seconds: 3), content: Text(hr(context, ru, en))));
}

/// «Найти самый быстрый» progress per profile id: the server being tested (from 1) of how many.
final happSpeedProgress = StateProvider<Map<String, ({int at, int total})>>((ref) => const {});

void _setProgress(ProviderContainer container, String profileId, ({int at, int total})? p) {
  final all = {...container.read(happSpeedProgress)};
  if (p == null) {
    all.remove(profileId);
  } else {
    all[profileId] = p;
  }
  container.read(happSpeedProgress.notifier).state = all;
}

/// Set when a server ran out of time: its steps stop and start nothing more.
class _Cancel {
  bool cancelled = false;
}

/// Tests [tags] of [profile] one after the other. Asks first on mobile data. A server that fails
/// or times out is ✕ and the rest go on; never two at once. With [findFastest] the end is a
/// sheet ranking them with «Переключиться на …».
Future<void> happSpeedTest(BuildContext context, ProfileEntity profile, List<String> tags, {bool findFastest = false}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (tags.isEmpty) {
    _snack(context, 'Нет серверов с пингом: сначала проверьте пинг', 'No servers with a ping: test the ping first');
    return;
  }
  final running = container.read(serviceRunningProvider);
  final active = container.read(activeProfileProvider).valueOrNull?.id == profile.id;
  if (!running || !active) {
    _snack(context, 'Подключитесь к этой подписке, чтобы проверить скорость', 'Connect to this subscription to test the speed');
    return;
  }
  if (!_running.add(profile.id)) {
    _snack(context, 'Тест скорости уже идёт', 'A speed test is already running');
    return;
  }
  final ru = Localizations.maybeLocaleOf(context)?.languageCode == 'ru';
  try {
    if (await HappPlatform.onMobileData()) {
      if (!context.mounted) return;
      final mb = tags.length * 5;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.signal_cellular_alt_rounded),
          title: Text(hr(context, 'Вы на мобильном интернете', 'You are on mobile data')),
          content: Text(
            hr(
              context,
              'Тест скорости скачает до $mb МБ (обычно меньше: на медленной связи он останавливается раньше). Продолжить?',
              'The speed test downloads up to $mb MB (usually less: on a slow link it stops earlier). Go on?',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(hr(context, 'Отмена', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(hr(context, 'Проверить', 'Test'))),
          ],
        ),
      );
      if (go != true) return;
    }
    final results = <String, int>{};
    bool stillHere() =>
        container.read(serviceRunningProvider) && container.read(activeProfileProvider).valueOrNull?.id == profile.id;
    for (final (i, tag) in tags.indexed) {
      if (!stillHere()) break;
      // the core may still be downloading for the server before: wait for it, at most a while
      final waitFrom = DateTime.now();
      while (!happSpeedMayStartNext(testing: _busyCore(container), waited: DateTime.now().difference(waitFrom))) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (!stillHere()) break;
      if (tags.length > 1) _setProgress(container, profile.id, (at: i + 1, total: tags.length));
      _setPending(container, profile.id, tag, true);
      final cancel = _Cancel();
      try {
        final r = await _testOne(container, tag, cancel).timeout(
          happSpeedServerTimeout,
          onTimeout: () {
            cancel.cancelled = true;
            return (bps: 0, running: true);
          },
        );
        results[tag] = r.bps > 0 ? r.bps : -1;
        if (r.bps > 0) _save(container, profile.id, {tag: r.bps});
        // it answers: a ping shown as failed («—») is tested again (the core tries in stages)
        final item = container.read(proxiesOverviewNotifierProvider).valueOrNull?.items.where((e) => e.tag == tag).firstOrNull;
        if (item != null && happRepingAfterSpeed(bps: r.bps, delay: item.urlTestDelay)) {
          unawaited(container.read(proxyRepositoryProvider).urlTest(tag).run().then<void>((_) {}, onError: (Object _) {}));
        }
      } catch (_) {
        cancel.cancelled = true;
        results[tag] = -1;
      } finally {
        _setPending(container, profile.id, tag, false);
      }
    }
    _setProgress(container, profile.id, null);
    final ranked = happRankSpeeds(tags, results);
    final winner = happSpeedWinner(ranked);
    final text = winner == null ? null : '${happCleanName(winner)}: ${happSpeedLabel(results[winner]!, ru: ru)}';
    if (text != null) {
      unawaited(
        happNotify(
          container.read(sharedPreferencesProvider).valueOrNull,
          HappNotifyType.testResults,
          isRu: ru,
          ru: ('Тест скорости готов', text),
          en: ('Speed test done', text),
        ),
      );
    }
    if (!context.mounted) return;
    if (findFastest && tags.length > 1) {
      await _showResults(context, container, ranked, tested: results.keys.toSet());
    } else if (text == null) {
      _snack(context, 'Не удалось измерить скорость', 'Could not measure the speed');
    } else {
      _snack(context, text, text);
    }
  } finally {
    _setProgress(container, profile.id, null);
    _running.remove(profile.id);
  }
}

/// The core is downloading for some server of the shown group.
bool _busyCore(ProviderContainer container) {
  final group = container.read(proxiesOverviewNotifierProvider).valueOrNull;
  return group?.items.any((e) => e.downloadTesting) ?? false;
}

/// The result sheet of «Найти самый быстрый»: the servers by Мбит/с, the winner on top, ✕ for the
/// ones that failed, and a button to switch to the winner (as the user's own pick).
Future<void> _showResults(
  BuildContext context,
  ProviderContainer container,
  List<({String tag, int bps})> ranked, {
  required Set<String> tested,
}) async {
  final winner = happSpeedWinner(ranked);
  final ru = Localizations.maybeLocaleOf(context)?.languageCode == 'ru';
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final live = container.read(proxiesOverviewNotifierProvider).valueOrNull;
      final selected = live?.selected;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(hr(sheet, 'Самый быстрый сервер', 'Fastest server'), style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                winner == null
                    ? hr(sheet, 'Ни один сервер не ответил на тест скорости', 'No server answered the speed test')
                    : hr(sheet, 'Скорость скачивания через каждый сервер', 'Download speed through each server'),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              for (final (i, r) in ranked.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Text(
                    r.bps > 0 ? (i == 0 ? '🏆' : '${i + 1}') : '✕',
                    style: theme.textTheme.titleMedium?.copyWith(color: r.bps > 0 ? null : theme.colorScheme.error),
                  ),
                  title: Text(
                    happCleanName(r.tag),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: i == 0 && r.bps > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null,
                  ),
                  trailing: Text(
                    r.bps > 0
                        ? happSpeedLabel(r.bps, ru: ru).replaceFirst('↓ ', '')
                        : (tested.contains(r.tag) ? hr(sheet, 'не ответил', 'failed') : hr(sheet, 'не проверен', 'not tested')),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: r.bps > 0 ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (winner != null && live != null && winner != selected)
                FilledButton.icon(
                  icon: const Icon(Icons.bolt_rounded),
                  label: Text(
                    hr(sheet, 'Переключиться на ${happCleanName(winner)}', 'Switch to ${happCleanName(winner)}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () async {
                    Navigator.of(sheet).pop();
                    // changeProxy emits HappUserPick: failover keeps it as the user's own choice
                    final ok = await container.read(proxiesOverviewNotifierProvider.notifier).changeProxy(live.tag, winner);
                    if (ok && context.mounted) {
                      _snack(context, 'Подключено к ${happCleanName(winner)}', 'Connected to ${happCleanName(winner)}');
                    }
                  },
                )
              else
                OutlinedButton(
                  onPressed: () => Navigator.of(sheet).pop(),
                  child: Text(
                    winner != null && winner == selected
                        ? hr(sheet, 'Вы уже на нём', 'You\'re already on it')
                        : hr(sheet, 'Закрыть', 'Close'),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// One server: a first megabyte, then a second step sized from it (or none). Each step waits
/// for the core's background download to finish ([happSpeedPoll]); the second never starts while
/// the first runs, nor once [cancel] is set. [running] true: a step timed out with the core still
/// downloading.
Future<({int bps, bool running})> _testOne(ProviderContainer container, String tag, _Cancel cancel) async {
  final repo = container.read(proxyRepositoryProvider);
  Future<({int bps, Duration took, bool running})> step(int bytes) async {
    final before = _probeOf(container, tag)?.speed;
    final watch = Stopwatch()..start();
    // the core answers at once and downloads in the background (the call has a deadline)
    final ok = await repo.downloadTest(tag, bytes).run();
    if (ok.isLeft() || cancel.cancelled) return (bps: 0, took: watch.elapsed, running: false);
    var sawTesting = false;
    while (true) {
      if (cancel.cancelled) return (bps: 0, took: watch.elapsed, running: true);
      // the list is reloading (null for a moment): look again, the step's own timeout still holds
      if (container.read(proxiesOverviewNotifierProvider).valueOrNull == null) {
        if (watch.elapsed >= happSpeedStepTimeout) return (bps: 0, took: watch.elapsed, running: true);
        await Future<void>.delayed(happSpeedPollEvery);
        continue;
      }
      final probe = _probeOf(container, tag);
      final testing = probe?.testing ?? false;
      sawTesting = sawTesting || testing;
      final r = happSpeedPoll(
        sawTesting: sawTesting,
        testing: testing,
        speed: probe?.speed,
        before: before,
        elapsed: watch.elapsed,
      );
      if (r != null) return (bps: r.bps, took: watch.elapsed, running: r.running);
      await Future<void>.delayed(happSpeedPollEvery);
    }
  }

  final first = await step(happSpeedFirstBytes);
  if (first.running || cancel.cancelled) return (bps: 0, running: true);
  // a slow link (≥ 3 s) or a failure: the first step is the whole test
  final secondBytes = happSpeedSecondStep(firstBytes: happSpeedFirstBytes, firstTook: first.took, firstSpeed: first.bps);
  if (secondBytes == null) return (bps: happSpeedResult(first: first.bps), running: false);
  final second = await step(secondBytes);
  return (bps: happSpeedResult(first: first.bps, second: second.running ? null : second.bps), running: second.running);
}

({int speed, bool testing})? _probeOf(ProviderContainer container, String tag) {
  final group = container.read(proxiesOverviewNotifierProvider).valueOrNull;
  final item = group?.items.where((e) => e.tag == tag).firstOrNull;
  if (item == null) return null;
  return (speed: item.downloadSpeed.toInt(), testing: item.downloadTesting);
}

void _setPending(ProviderContainer container, String profileId, String tag, bool on) {
  final all = {...container.read(happSpeedPending)};
  final set = {...?all[profileId]};
  on ? set.add(tag) : set.remove(tag);
  if (set.isEmpty) {
    all.remove(profileId);
  } else {
    all[profileId] = set;
  }
  container.read(happSpeedPending.notifier).state = all;
}

void _save(ProviderContainer container, String profileId, Map<String, int> fresh) {
  final prefs = container.read(sharedPreferencesProvider).valueOrNull;
  if (prefs == null) return;
  final raw = happWriteSpeedCache(happSpeedCacheOf(prefs, profileId), fresh, DateTime.now());
  unawaited(prefs.setString(happSpeedCacheKey(profileId), raw));
  container.read(happSpeedRevision.notifier).state++;
}

/// «…» → «Найти самый быстрый»: the 5 servers with the lowest ping, by download speed. The ping
/// is measured again first, and only this test's working pings count: picking from the pings on
/// screen took cached and stale ones (and servers whose ping had not come yet), so servers with a
/// high ping were tested.
Future<void> happSpeedTestTop(BuildContext context, ProfileEntity profile) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final active = container.read(activeProfileProvider).valueOrNull?.id == profile.id;
  if (!container.read(serviceRunningProvider) || !active) {
    _snack(context, 'Подключитесь к этой подписке, чтобы проверить скорость', 'Connect to this subscription to test the speed');
    return;
  }
  if (_running.contains(profile.id)) {
    _snack(context, 'Тест скорости уже идёт', 'A speed test is already running');
    return;
  }
  _snack(context, 'Сначала проверяю пинг…', 'Testing the ping first…');
  final since = DateTime.now();
  await happPingLive(container, profile.id);
  if (!context.mounted) return;
  final live = container.read(proxiesOverviewNotifierProvider).valueOrNull;
  final samples = <HappPingSample>[
    for (final p in live?.items ?? const <OutboundInfo>[])
      (
        tag: p.tag,
        isGroup: p.isGroup,
        visible: p.isVisible,
        delay: p.urlTestDelay,
        testedAt: p.hasUrlTestTime() ? p.urlTestTime.toDateTime() : null,
      ),
  ];
  await happSpeedTest(context, profile, happTopFreshByPing(samples, since), findFastest: true);
}
