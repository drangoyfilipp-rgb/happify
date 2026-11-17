import 'dart:async';

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_home_servers.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/reliability/happ_user_pick.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the server picked in each profile and picks it again on the next connection.
///
/// The core keeps the choice too, but loses it when a subscription update renames or reorders its
/// servers, or when another profile was used in between; this keeps one per profile, by name.
///
/// Only the user's own picks write it (a [HappUserPick], saved by HappifyLifecycle with
/// [happSaveUserPick], and the home rows while disconnected): a
/// server «Автопереключение при сбое» moved to never replaces the user's choice. Build-37 saved
/// whatever was selected and switched on a single failed ping, which is how a chosen Prague became
/// Helsinki ten minutes later.
final happifyLastServerProvider = Provider<void>((ref) {
  final remember = ref.watch(HappifyPrefs.rememberLastServer);
  if (!ref.watch(serviceRunningProvider)) return;
  ref.watch(coreRestartSignalProvider);
  final profileId = ref.watch(activeProfileProvider.select((p) => p.valueOrNull?.id));
  if (profileId == null) return;

  final prefs = ref.read(sharedPreferencesProvider).requireValue;
  // a server tapped on the home screen before connecting is picked once, whatever the settings
  final pickRaw = prefs.getString(happifyPickNextKey);
  final pickNext = pickRaw != null && pickRaw.startsWith('$profileId\n') ? pickRaw.substring(profileId.length + 1) : null;
  if (!remember && pickNext == null) return;
  final key = happLastServerKey(profileId);
  final repo = ref.read(proxyRepositoryProvider);
  var restored = false;

  final sub = repo.watchProxies().listen((event) {
    event.fold((_) {}, (group) {
      if (restored || group == null || group.items.isEmpty) return;
      restored = true;
      final saved = pickNext ?? prefs.getString(key);
      if (pickNext != null) unawaited(prefs.remove(happifyPickNextKey));
      if (saved != null && saved != group.selected && group.items.any((item) => item.tag == saved)) {
        unawaited(repo.selectProxy(group.tag, saved).run());
      }
    });
  });
  ref.onDispose(sub.cancel);
});

/// The pref that keeps the server last picked in [profileId].
String happLastServerKey(String profileId) => 'happify_last_server_$profileId';

/// Saves [pick] as the last server of [profileId]; nothing without a profile.
Future<void> happSaveUserPick(SharedPreferences? prefs, String? profileId, HappUserPick pick) async {
  if (prefs == null || profileId == null) return;
  await prefs.setString(happLastServerKey(profileId), pick.outboundTag);
}
