import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';

// Each subscription keeps its own «Сортировка серверов», chosen in its «Изменить» sheet:
// "happify_sort_<profile id>" holds the rule's name. The pure parts live here, for the tests.

/// The rules a subscription can take, in Happ's order, with «По стране» after them.
const happProfileSortRules = [ProxiesSort.unsorted, ProxiesSort.delay, ProxiesSort.name, ProxiesSort.country];

const happSortKeyPrefix = 'happify_sort_';

String happSortKey(String profileId) => '$happSortKeyPrefix$profileId';

/// Set once the old shared rule was handed to the subscriptions.
const happSortMigratedKey = 'happify_sort_migrated';

/// The shared rule build-37 kept (and the servers page still uses for its own list).
const happLegacySortKey = 'proxies_sort_mode';

/// The rule saved as [raw]; anything unknown, or a rule only the servers page has, is «Без сортировки».
ProxiesSort happParseProfileSort(String? raw) {
  if (raw == null) return ProxiesSort.unsorted;
  final rule = ProxiesSort.values.where((e) => e.name == raw).firstOrNull;
  return rule != null && happProfileSortRules.contains(rule) ? rule : ProxiesSort.unsorted;
}

/// What the move to a rule per subscription writes, once: the shared rule the user had chosen
/// (absent while never chosen) becomes the rule of every subscription that has none yet.
/// Empty when there is nothing to hand over; the caller marks it done either way.
Map<String, String> happSortMigration({
  required bool migrated,
  required String? legacy,
  required Iterable<String> profileIds,
  required Set<String> existingKeys,
}) {
  if (migrated || legacy == null) return const {};
  final rule = happParseProfileSort(legacy);
  if (rule == ProxiesSort.unsorted) return const {};
  return {
    for (final id in profileIds)
      if (!existingKeys.contains(happSortKey(id))) happSortKey(id): rule.name,
  };
}

/// The per-subscription keys Happify keeps; removed with the subscription.
List<String> happProfileKeys(String profileId) => [
  happSortKey(profileId),
  'happify_last_server_$profileId',
  'happify_ping_$profileId',
  'happify_speed_$profileId',
  'happify_announce_$profileId',
  'happify_notified_exp_$profileId',
  'happify_notified_traffic_$profileId',
];

const _perProfilePrefixes = [
  happSortKeyPrefix,
  'happify_last_server_',
  'happify_ping_',
  'happify_speed_',
  'happify_announce_',
  'happify_notified_exp_',
  'happify_notified_traffic_',
];

/// Subscription ids are UUIDs (profile_repository.dart: `Uuid().v4()`).
final _uuidLike = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

bool happIsProfileIdLike(String id) => _uuidLike.hasMatch(id);

/// Keys left by subscriptions that are gone: per-subscription keys whose id is a UUID not in
/// [profileIds]. Anything else that shares a prefix (a global key such as "happify_ping_on_open",
/// or one added later) is not a subscription's and stays.
List<String> happOrphanProfileKeys(Iterable<String> keys, Set<String> profileIds) {
  const global = {'happify_ping_on_open', happSortMigratedKey};
  final out = <String>[];
  for (final key in keys) {
    if (global.contains(key)) continue;
    for (final prefix in _perProfilePrefixes) {
      if (!key.startsWith(prefix)) continue;
      final id = key.substring(prefix.length);
      if (happIsProfileIdLike(id) && !profileIds.contains(id)) out.add(key);
      break;
    }
  }
  return out;
}
