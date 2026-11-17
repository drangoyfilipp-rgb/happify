import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_last_server.dart';
import 'package:hiddify/features/happ/reliability/happ_bypass.dart';
import 'package:hiddify/features/happ/reliability/happ_diagnostics.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_runtime.dart';
import 'package:hiddify/features/happ/reliability/happ_notifications.dart';
import 'package:hiddify/features/happ/reliability/happ_platform.dart';
import 'package:hiddify/features/happ/reliability/happ_profile_sort_state.dart';
import 'package:hiddify/features/happ/reliability/happ_user_pick.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_traffic_saving.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _platform = MethodChannel('com.hiddify.app/platform');

/// The kill switch as Android sees it: whether the system keeps Happify always on and blocks
/// traffic without it. Unknown while the VPN is off or before Android 10.
Future<({bool known, bool alwaysOn, bool lockdown})> killSwitchState() async {
  try {
    final map = await _platform.invokeMapMethod<String, dynamic>('kill_switch_state');
    return (
      known: map?['known'] == true,
      alwaysOn: map?['alwaysOn'] == true,
      lockdown: map?['lockdown'] == true,
    );
  } catch (_) {
    return (known: false, alwaysOn: false, lockdown: false);
  }
}

/// What Happify does around the app's life, wrapping the app:
/// - on open: updates the active subscription, then tests every ping, one after the other, so a
///   ping of the old list never shows over the new one;
/// - "Keep VPN on": when the tunnel fails on its own, connects again, waiting longer each time.
///   A stop by the user (the button, the notification, the tile) is never undone.
/// - remembers the last server of each profile.
class HappifyLifecycle extends HookConsumerWidget {
  const HappifyLifecycle({super.key, required this.child});

  final Widget child;

  static const _updateEvery = Duration(minutes: 10);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(happifyLastServerProvider, (_, _) {});
    // the user picked a server: the one «Последний сервер» brings back in this profile (the
    // failover's own switches never emit this)
    ref.listen<HappUserPick?>(happUserPickProvider, (_, pick) {
      if (pick == null || pick.groupTag != happMainSelectorTag) return;
      unawaited(happSaveUserPick(ref.read(sharedPreferencesProvider).valueOrNull, ref.read(activeProfileProvider).valueOrNull?.id, pick));
    });
    // «Автопереключение при сбое» and the liveness indicator, while connected
    ref.listen(happFailoverRuntimeProvider, (_, _) {});
    // «Уведомления» about the subscriptions and the VPN
    ref.listen(happNotificationsWatcherProvider, (_, _) {});
    // «Диагностика» records failures from the start
    ref.listen(happDiagnosticsProvider, (_, _) {});
    // each subscription's sort: the old shared rule handed over once; keys of deleted ones removed
    ref.listen(happProfilePrefsMaintenanceProvider, (_, _) {});
    // «Мимо VPN» from the VPN notification: the picker over whatever screen is open
    useEffect(() {
      final sub = HappPlatform.actions.listen((action) {
        if (action == 'bypass') unawaited(happShowBypassPicker());
      });
      // asked for while the app was starting
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 800), () async {
          if (await HappPlatform.takePendingAction() == 'bypass') await happShowBypassPicker();
        }),
      );
      return sub.cancel;
    }, const []);
    // kept alive: «Экономия трафика» follows mobile data by itself
    ref.listen(happTrafficSavingProvider, (_, _) {});
    final busy = useRef(false);
    final pingPending = useRef(false);
    final retries = useRef(0);
    final retryTimer = useRef<Timer?>(null);
    final lastPing = useRef<DateTime?>(null);

    // a ping tests every server: once in 2 minutes is enough, however often the app is reopened
    Future<void> ping() async {
      pingPending.value = false;
      final last = lastPing.value;
      if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) return;
      lastPing.value = DateTime.now();
      await ref.read(proxyRepositoryProvider).urlTest('select').run();
    }

    Future<void> onOpen() async {
      if (busy.value || !ref.read(Preferences.introCompleted)) return;
      busy.value = true;
      try {
        final profile = await ref.read(activeProfileProvider.future);
        // saving traffic: the subscription is updated on open far less often, and nothing is pinged
        final saving = ref.read(happTrafficSavingProvider);
        final every = saving ? const Duration(hours: 6) : _updateEvery;
        if (ref.read(HappifyPrefs.updateOnOpen) &&
            profile is RemoteProfileEntity &&
            DateTime.now().difference(profile.lastUpdate) > every) {
          await ref.read(updateProfileNotifierProvider(profile.id).notifier).updateProfile(profile, isBulk: true);
          lastPing.value = null; // the new list is tested at once
          // an update of the active profile reconnects: the ping waits for the new list
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        if (ref.read(HappifyPrefs.pingOnOpen) && !saving) {
          if (ref.read(serviceRunningProvider)) {
            await ping();
          } else {
            // tested once the VPN is up
            pingPending.value = true;
          }
        }
      } catch (_) {
        // nothing to update or test now
      } finally {
        busy.value = false;
      }
    }

    // «Проверять обновления»: a newer Happify build, at most every 6 hours (checkOnStart throttles)
    final updatePrompt = useRef(false);
    Future<void> selfUpdate() async {
      if (updatePrompt.value || !ref.read(HappifyPrefs.checkUpdates) || !ref.read(Preferences.introCompleted)) return;
      updatePrompt.value = true;
      try {
        final release = await ref.read(appUpdateNotifierProvider.notifier).checkOnStart();
        if (release == null) return;
        await ref
            .read(dialogNotifierProvider.notifier)
            .showNewVersion(
              currentVersion: ref.read(appInfoProvider).requireValue.buildNumber,
              newVersion: release,
              canIgnore: true,
            );
      } catch (_) {
        // no network now: the next open tries again
      } finally {
        updatePrompt.value = false;
      }
    }

    ref.listen(connectionNotifierProvider, (previous, next) {
      final was = previous?.valueOrNull;
      final now = next.valueOrNull;
      if (now is Connected) {
        retries.value = 0;
        if (pingPending.value && !busy.value) {
          unawaited(Future<void>.delayed(const Duration(seconds: 1), ping));
        }
      }
      // Keep VPN on: only a failure is retried, never a stop the user asked for
      final failed = now is Disconnected && now.connectionFailure != null && (was?.isRunning ?? false);
      if (failed && ref.read(HappifyPrefs.keepConnected) && ref.read(Preferences.startedByUser)) {
        if (retries.value >= 6) return;
        final wait = Duration(seconds: 3 << retries.value);
        retries.value++;
        retryTimer.value?.cancel();
        retryTimer.value = Timer(wait, () async {
          final status = ref.read(connectionNotifierProvider).valueOrNull;
          if (status is Disconnected && ref.read(Preferences.startedByUser) && ref.read(HappifyPrefs.keepConnected)) {
            await ref.read(connectionNotifierProvider.notifier).mayConnect();
          }
        });
      }
      // the user stopped it: nothing waits to bring it back
      if (now is Disconnected && now.connectionFailure == null) retryTimer.value?.cancel();
    });

    useOnAppLifecycleStateChange((_, state) {
      if (state == AppLifecycleState.resumed) {
        unawaited(onOpen());
        unawaited(selfUpdate());
      }
    });
    useEffect(() {
      final timer = Timer(const Duration(seconds: 4), () => unawaited(onOpen()));
      // after the subscription update and the VPN start have had their turn
      final updateTimer = Timer(const Duration(seconds: 10), () => unawaited(selfUpdate()));
      return () {
        timer.cancel();
        updateTimer.cancel();
        retryTimer.value?.cancel();
      };
    }, const []);
    return child;
  }
}
