import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_home.dart';
import 'package:hiddify/features/happ/happ_ping_plan.dart';
import 'package:hiddify/features/happ/happ_switch_guard.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_traffic_saving.dart';
import 'package:hiddify/features/happ/reliability/happ_notifications.dart';
import 'package:hiddify/features/happ/reliability/happ_notify_rules.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_data_providers.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/hiddifycore/offline_core_test_gate.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The servers whose ping is being measured, per profile id: tag → the delay the row showed when
/// the test began (null when none), so a live row knows when its new result has come.
final happPingPending = StateProvider<Map<String, Map<String, int?>>>((ref) => const {});

/// The settings of the speedometer's test core: the user's own, without anything that reaches
/// outside the app (TUN, system proxy, LAN sharing, tproxy/redirect), and every server running.
SingboxConfigOption happOfflineTestOptions(SingboxConfigOption options) => options.copyWith(
  enableTun: false,
  setSystemProxy: false,
  enableClashApi: false,
  allowConnectionFromLan: false,
  enableTproxyPort: false,
  enableRedirectPort: false,
  enableDirectPort: false,
  keepTop: -1,
  keepTags: const [],
);

void _setPending(ProviderContainer ref, String profileId, Map<String, int?>? tags) {
  final all = {...ref.read(happPingPending)};
  if (tags == null || tags.isEmpty) {
    all.remove(profileId);
  } else {
    all[profileId] = tags;
  }
  ref.read(happPingPending.notifier).state = all;
}

void _done(ProviderContainer ref, String profileId, Iterable<String> tags) {
  final current = ref.read(happPingPending)[profileId];
  if (current == null) return;
  final left = {...current}..removeWhere((k, _) => tags.contains(k));
  _setPending(ref, profileId, left);
}

void _snack(BuildContext context, String ru, String en) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: const Duration(seconds: 3), content: Text(hr(context, ru, en))));
}

/// Happ's speedometer on a subscription card: every server tested, connected or not.
///
/// Works off the app's container rather than the card's ref: the card may be rebuilt or scrolled
/// away while the test runs, and the test still has to clean up.
Future<void> happPingProfile(BuildContext context, ProfileEntity profile) async {
  final ref = ProviderScope.containerOf(context, listen: false);
  // a second tap while the first is still getting ready does nothing
  if (ref.read(happPingPending).containsKey(profile.id) || !_inFlight.add(profile.id)) return;
  final isRu = Localizations.maybeLocaleOf(context)?.languageCode != 'en';
  try {
    await _ping(context, ref, profile);
    // «Результаты пинга и скорости» as a notification, for whoever turned it on (off by default)
    final prefs = ref.read(sharedPreferencesProvider).valueOrNull;
    if (prefs != null && happNotifyEnabled(prefs, HappNotifyType.testResults)) {
      final best = happReadPingCache(prefs, profile.id).entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      if (best.isNotEmpty) {
        final name = happCleanName(best.first.key);
        unawaited(
          happNotify(
            prefs,
            HappNotifyType.testResults,
            isRu: isRu,
            ru: ('Пинг проверен: ${profile.name}', 'Быстрее всех — $name, ${best.first.value} мс'),
            en: ('Ping tested: ${profile.name}', 'Fastest — $name, ${best.first.value} ms'),
          ),
        );
      }
    }
  } finally {
    _inFlight.remove(profile.id);
  }
}

final _inFlight = <String>{};

Future<void> _ping(BuildContext context, ProviderContainer ref, ProfileEntity profile) async {
  final status = ref.read(connectionNotifierProvider).valueOrNull;
  final connected = status == null || status is! Disconnected;
  final active = ref.read(activeProfileProvider).valueOrNull;
  final core = ref.read(hiddifyCoreServiceProvider);
  final route = happPingRoute(
    connected: connected,
    thisIsActive: active?.id == profile.id,
    offlineCapable: core.offlineTestSupported,
  );

  switch (route) {
    case HappPingRoute.live:
      await happPingLive(ref, profile.id);
    case HappPingRoute.busyOther:
      // one core per app: testing this one would drop the connection, so it waits
      _snack(
        context,
        'Сейчас подключена другая подписка. Отключитесь, чтобы проверить пинг этой',
        'Another subscription is connected. Disconnect to test this one',
      );
    case HappPingRoute.unsupported:
      _snack(context, 'Подключитесь, чтобы проверить пинг', 'Connect to test the ping');
    case HappPingRoute.offline:
      await _offline(context, ref, profile, active);
  }
}

Future<void> _offline(BuildContext context, ProviderContainer ref, ProfileEntity profile, ProfileEntity? active) async {
  final core = ref.read(hiddifyCoreServiceProvider);
  if (core.offlineTest.busy) {
    // one test core at a time: another subscription is being tested
    _snack(context, 'Пинг уже проверяется, подождите немного', 'The ping is being tested, wait a moment');
    return;
  }
  // kept alive while it is read, even when the card is closed meanwhile
  final serversSub = ref.listen(happServersProvider(profile.id).future, (_, _) {});
  final List<HappServer> servers;
  try {
    servers = await serversSub.read();
  } catch (_) {
    return;
  } finally {
    serversSub.close();
  }
  if (servers.isEmpty) return;
  final repo = ref.read(configOptionRepositoryProvider);
  final tested = repo.fullOptionsOverrided(profile.profileOverride()).toNullable();
  // what the core holds when nothing tests: the settings of the subscription connecting uses
  final restore = repo.fullOptionsOverrided((active ?? profile).profileOverride()).toNullable();
  if (tested == null || restore == null) return;
  final prefs = ref.read(sharedPreferencesProvider).valueOrNull;
  final tags = {for (final s in servers) s.tag};
  _setPending(ref, profile.id, {for (final t in tags) t: null});
  Map<String, int>? results;
  try {
    results = await core.offlineUrlTest(
      path: ref.read(profilePathResolverProvider).file(profile.id).path,
      name: profile.name,
      tags: tags,
      testOptions: happOfflineTestOptions(tested),
      restoreOptions: restore,
      budget: happPingBudget(ref.read(happTrafficSavingProvider)),
      onDelays: (fresh) {
        if (prefs != null) {
          final merged = {...happReadPingCache(prefs, profile.id), ...fresh};
          unawaited(prefs.setString(happPingCacheKey(profile.id), jsonEncode(merged)));
          ref.read(happPingCacheRevision.notifier).state++;
        }
        _done(ref, profile.id, fresh.keys);
      },
    );
  } finally {
    _setPending(ref, profile.id, null);
  }
  // not when it was called off because the user is connecting
  if (results == null && ref.read(connectionNotifierProvider).valueOrNull is Disconnected) {
    _snack(context, 'Не удалось проверить пинг. Попробуйте подключиться', 'Could not test the ping. Try connecting');
  }
}

/// The ping of the connected subscription [profileId]: each shown server tested by its own tag,
/// [happPingWaveSize] at a time (see happ_ping_plan.dart for why not the whole group). A row's
/// spinner stops at its first working result of this test, or after [happPingRowDeadline]; all of
/// them as soon as the connection goes. A ping already running for it is waited for instead.
/// Never longer than the waves plus the row deadline.
Future<void> happPingLive(ProviderContainer ref, String profileId) async {
  if (ref.read(happPingPending).containsKey(profileId)) {
    // one ping at a time: wait for the one running (bounded by its own deadlines)
    final until = DateTime.now().add(const Duration(seconds: 90));
    while (ref.read(happPingPending).containsKey(profileId) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return;
  }
  final live = ref.read(proxiesOverviewNotifierProvider).valueOrNull;
  if (live == null || live.items.isEmpty) return;
  final tags = [
    for (final p in live.items)
      if (!p.isGroup && p.isVisible) p.tag,
  ];
  if (tags.isEmpty) return;
  _setPending(ref, profileId, {for (final p in live.items) if (!p.isGroup && p.isVisible) p.tag: happCoreDelay(p)});
  final started = <String, DateTime>{};
  bool stillHere() => ref.read(serviceRunningProvider) && ref.read(activeProfileProvider).valueOrNull?.id == profileId;
  void sweep() {
    final now = DateTime.now();
    final group = ref.read(proxiesOverviewNotifierProvider).valueOrNull;
    if (group == null) return; // the list is reloading: look again next time
    final done = [
      for (final p in group.items)
        if (started.containsKey(p.tag) &&
            happPingRowDone(
              delay: p.urlTestDelay,
              testedAt: p.hasUrlTestTime() ? p.urlTestTime.toDateTime() : null,
              startedAt: started[p.tag],
              now: now,
            ))
          p.tag,
    ];
    // a row no longer in the list: nothing will come for it
    final gone = [
      for (final t in started.keys)
        if (!group.items.any((e) => e.tag == t)) t,
    ];
    _done(ref, profileId, [...done, ...gone]);
  }

  try {
    // a server pick in flight goes first (≤5 s)
    await HappSwitchActivity.waitIdle();
    final repo = ref.read(proxyRepositoryProvider);
    for (final wave in happPingWaves(tags)) {
      if (!stillHere()) return;
      final at = DateTime.now();
      for (final t in wave) {
        started[t] = at;
      }
      await Future.wait([
        for (final t in wave)
          repo.urlTest(t).run().timeout(const Duration(seconds: 3), onTimeout: () => throw TimeoutException('url test')).then<void>((_) {}, onError: (Object _) {}),
      ]);
      final pauseUntil = at.add(happPingWavePause);
      while (DateTime.now().isBefore(pauseUntil)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        sweep();
      }
    }
    final until = DateTime.now().add(happPingRowDeadline + const Duration(seconds: 1));
    while (DateTime.now().isBefore(until)) {
      if (!stillHere() || ref.read(happPingPending)[profileId] == null) break;
      sweep();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  } finally {
    _setPending(ref, profileId, null);
  }
}
