import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/keep_top/keep_top.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The servers the profile's saved config has, read without the core, so they list before connecting.
final happifyOfflineServersProvider = FutureProvider.family<List<({String tag, String type})>, String>((
  ref,
  profileId,
) async {
  final proxies = await readProfileProxies(ref.watch(profilePathResolverProvider).file(profileId));
  return [for (final p in proxies) (tag: p.tag, type: p.type)];
});

/// A server the user tapped before connecting: '<profile id>\n<server tag>', used once.
const happifyPickNextKey = 'happify_pick_next';

/// Happ-like: the active profile's servers right on the home screen, before and after connecting.
/// Connected, they come from the core with their pings, and a tap switches at once. Disconnected,
/// they come from the saved config, and a tap picks the server and connects to it.
class HappifyHomeServers extends HookConsumerWidget {
  const HappifyHomeServers({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked = useState<String?>(null);
    final profileId = ref.watch(activeProfileProvider.select((p) => p.valueOrNull?.id));
    if (profileId == null) return const SizedBox.shrink();
    final running = ref.watch(serviceRunningProvider);
    final live = running ? ref.watch(proxiesOverviewNotifierProvider).valueOrNull : null;

    if (live != null && live.items.isNotEmpty) {
      // groups only when listed at all: lowest and balance, with "Show lowest and balance" on
      final items = live.items.where((e) => e.isVisible && (!e.isGroup || e.tag == 'lowest' || e.tag == 'balance')).toList();
      return Column(
        children: [
          for (final proxy in items)
            ProxyTile(
              proxy,
              key: ValueKey(proxy.tag),
              selected: live.selected == proxy.tag,
              onTap: () => ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(live.tag, proxy.tag),
            ),
        ],
      );
    }

    final offline = ref.watch(happifyOfflineServersProvider(profileId)).valueOrNull ?? const [];
    if (offline.isEmpty) return const SizedBox.shrink();
    final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    final key = 'happify_last_server_$profileId';
    final saved = picked.value ?? prefs?.getString(key);
    final pins = pinnedSet(ref.watch(HappifyPrefs.pinnedServers));
    final sorted = [...offline]..sort((a, b) => (pins.contains(a.tag) ? 0 : 1).compareTo(pins.contains(b.tag) ? 0 : 1));
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final s in sorted)
          ListTile(
            key: ValueKey(s.tag),
            selected: s.tag == saved,
            selectedTileColor: theme.colorScheme.primaryContainer,
            title: Text((pins.contains(s.tag) ? '📌 ' : '') + s.tag, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(s.type.toUpperCase()),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: running
                ? null
                : () async {
                    // picked as soon as the core is up, even with "Last server" off
                    picked.value = s.tag;
                    await prefs?.setString(key, s.tag);
                    await prefs?.setString(happifyPickNextKey, '$profileId\n${s.tag}');
                    await ref.read(Preferences.startedByUser.notifier).update(true);
                    await ref.read(connectionNotifierProvider.notifier).mayConnect();
                  },
          ),
      ],
    );
  }
}
