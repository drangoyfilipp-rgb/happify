import 'dart:async';

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/happ/reliability/happ_profile_sort.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Bumped when a subscription's sort is saved, so its card sorts again.
final happSortRevision = StateProvider<int>((ref) => 0);

/// The «Сортировка серверов» of a subscription (by profile id).
final happProfileSortProvider = Provider.family<ProxiesSort, String>((ref, profileId) {
  ref.watch(happSortRevision);
  final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
  return happParseProfileSort(prefs?.getString(happSortKey(profileId)));
});

Future<void> happSetProfileSort(ProviderContainer container, String profileId, ProxiesSort rule) async {
  final prefs = container.read(sharedPreferencesProvider).valueOrNull;
  if (prefs == null) return;
  if (rule == ProxiesSort.unsorted) {
    await prefs.remove(happSortKey(profileId));
  } else {
    await prefs.setString(happSortKey(profileId), rule.name);
  }
  container.read(happSortRevision.notifier).state++;
}

/// Once the subscriptions are known: the old shared sort handed to them (once), and the keys of
/// subscriptions deleted outside the app's own delete removed.
final happProfilePrefsMaintenanceProvider = Provider<void>((ref) {
  var done = false;
  ref.listen(profilesNotifierProvider, (_, next) {
    final profiles = next.valueOrNull;
    final prefs = ref.read(sharedPreferencesProvider).valueOrNull;
    // an empty list may be a database still opening: wait for the subscriptions
    if (done || profiles == null || profiles.isEmpty || prefs == null) return;
    done = true;
    final ids = {for (final p in profiles) p.id};
    unawaited(() async {
      final writes = happSortMigration(
        migrated: prefs.getBool(happSortMigratedKey) ?? false,
        legacy: prefs.getString(happLegacySortKey),
        profileIds: ids,
        existingKeys: prefs.getKeys(),
      );
      for (final e in writes.entries) {
        await prefs.setString(e.key, e.value);
      }
      await prefs.setBool(happSortMigratedKey, true);
      if (writes.isNotEmpty) ref.read(happSortRevision.notifier).state++;
      for (final key in happOrphanProfileKeys(prefs.getKeys(), ids)) {
        await prefs.remove(key);
      }
    }());
  }, fireImmediately: true);
});
