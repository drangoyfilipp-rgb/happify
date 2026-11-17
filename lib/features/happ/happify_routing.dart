import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Ready-made routing profiles in the format Happ uses (DirectSites, ProxySites, BlockSites...),
/// turned into the app's route rules. They go before the user's own rules.
enum HappifyRouting {
  off,
  roscomvpn,
  roscomvpnWhitelist,
  subscription,
  custom;

  String present(BuildContext context) => switch (this) {
    off => hr(context, 'Выключено', 'Off'),
    roscomvpn => 'RoscomVPN',
    roscomvpnWhitelist => hr(context, 'RoscomVPN: белые списки', 'RoscomVPN: whitelist'),
    subscription => hr(context, 'Из подписки', 'From subscription'),
    custom => hr(context, 'Свой профиль', 'Custom profile'),
  };

  String explain(BuildContext context) => switch (this) {
    off => hr(context, 'Работают только регион и твои правила', 'Only the region and your own rules apply'),
    roscomvpn => hr(
      context,
      'Российские сайты, игры и магазины приложений напрямую, YouTube, Telegram и GitHub через VPN, реклама и торренты блокируются',
      'Russian sites, games and app stores go direct; YouTube, Telegram, GitHub through the VPN; ads and torrents blocked',
    ),
    roscomvpnWhitelist => hr(
      context,
      'Напрямую только сайты из белых списков мобильных операторов, остальное через VPN',
      'Only mobile-carrier whitelist sites go direct, everything else through the VPN',
    ),
    subscription => hr(context, 'Маршрутизация, которую прислал твой VPN-сервис', 'The routing your VPN provider sends'),
    custom => hr(context, 'Ссылка happ://routing, JSON или адрес JSON-файла', 'A happ://routing link, JSON, or a JSON URL'),
  };
}

abstract class HappifyRoutingPrefs {
  static final preset = PreferencesNotifier.create<HappifyRouting, String>(
    "happify_routing_preset",
    HappifyRouting.roscomvpn,
    mapFrom: (v) => HappifyRouting.values.firstWhere((e) => e.name == v, orElse: () => HappifyRouting.roscomvpn),
    mapTo: (v) => v.name,
  );

  /// RoscomVPN blocks torrents; on, torrent traffic goes through like the rest.
  static final allowTorrents = PreferencesNotifier.create<bool, bool>("happify_routing_allow_torrents", false);

  /// The custom profile as Happ JSON.
  static final customJson = PreferencesNotifier.create<String, String>("happify_routing_custom_json", "");

  /// What the user last chose other than Off, so the quick switch turns that one back on.
  static final lastOn = PreferencesNotifier.create<HappifyRouting, String>(
    "happify_routing_last_on",
    HappifyRouting.roscomvpn,
    mapFrom: (v) => HappifyRouting.values.firstWhere((e) => e.name == v, orElse: () => HappifyRouting.roscomvpn),
    mapTo: (v) => v.name,
  );
}

const _rcSite = 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/sing-box';
const _rcIp = 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/sing-box';
const _sgSite = 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set';
const _sgIp = 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set';

/// The categories RoscomVPN publishes as sing-box rule sets.
const _rcSites = {
  'apple', 'category-ads', 'category-geoblock-ru', 'category-ru', 'epicgames', 'escapefromtarkov', 'faceit', //
  'github', 'google-deepmind', 'google-play', 'microsoft', 'origin', 'pinterest', 'private', 'push', 'riot',
  'steam', 'telegram', 'torrent', 'twitch', 'twitch-ads', 'whitelist', 'win-spy', 'youtube',
};
const _rcIps = {'direct', 'whitelist', 'private'};

/// RoscomVPN's own profiles (hydraponique/roscomvpn-routing, HAPP/DEFAULT.JSON and WHITELIST.JSON).
/// The rule sets themselves are fetched fresh, so only the category lists live here.
const _roscomDefault = {
  'RouteOrder': 'block-proxy-direct',
  'BlockSites': ['geosite:win-spy', 'geosite:torrent', 'geosite:category-ads'],
  'ProxySites': ['geosite:google-play', 'geosite:github', 'geosite:twitch-ads', 'geosite:youtube', 'geosite:telegram'],
  'DirectSites': [
    'geosite:private', 'geosite:category-ru', 'geosite:whitelist', 'geosite:microsoft', 'geosite:apple', //
    'geosite:epicgames', 'geosite:riot', 'geosite:escapefromtarkov', 'geosite:steam', 'geosite:twitch',
    'geosite:pinterest', 'geosite:faceit',
  ],
  'DirectIp': ['geoip:private', 'geoip:direct'],
};
const _roscomWhitelist = {
  'RouteOrder': 'block-proxy-direct',
  'BlockSites': ['geosite:win-spy', 'geosite:torrent', 'geosite:category-ads'],
  'DirectSites': ['geosite:private', 'geosite:whitelist'],
  'DirectIp': ['geoip:private', 'geoip:whitelist'],
};

/// Reads a Happ routing profile from a happ://routing/... link, base64, or plain JSON.
Map<String, dynamic>? parseHappRouting(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('happ://routing/')) {
    // happ://routing/add/<base64> and happ://routing/onadd/<base64>
    s = s.substring(s.indexOf('/', 'happ://routing/'.length) + 1);
  }
  if (!s.startsWith('{')) {
    try {
      final norm = s.replaceAll('-', '+').replaceAll('_', '/');
      s = utf8.decode(base64.decode(norm.padRight((norm.length + 3) ~/ 4 * 4, '=')));
    } catch (_) {
      return null;
    }
  }
  try {
    final json = jsonDecode(s);
    if (json is! Map<String, dynamic>) return null;
    const keys = ['DirectSites', 'DirectIp', 'ProxySites', 'ProxyIp', 'BlockSites', 'BlockIp'];
    return keys.any(json.containsKey) ? json : null;
  } catch (_) {
    return null;
  }
}

List<String> _list(dynamic v) => v is List ? v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList() : [];

Rule? _rule(String name, Outbound outbound, List<String> sites, List<String> ips) {
  final ruleSets = <String>[];
  final domains = <String>[];
  final suffixes = <String>[];
  final keywords = <String>[];
  final regexes = <String>[];
  final cidrs = <String>[];
  for (final e in sites) {
    if (e.startsWith('geosite:')) {
      final c = e.substring(8).toLowerCase();
      // an attribute (geosite:google@cn) has no rule set of its own
      if (c.contains('@')) continue;
      ruleSets.add(_rcSites.contains(c) ? '$_rcSite/$c.srs' : '$_sgSite/geosite-$c.srs');
    } else if (e.startsWith('full:')) {
      domains.add(e.substring(5));
    } else if (e.startsWith('domain:')) {
      suffixes.add(e.substring(7));
    } else if (e.startsWith('keyword:')) {
      keywords.add(e.substring(8));
    } else if (e.startsWith('regexp:')) {
      regexes.add(e.substring(7));
    } else if (!e.contains(':')) {
      suffixes.add(e);
    }
  }
  for (final e in ips) {
    if (e.startsWith('geoip:')) {
      final c = e.substring(6).toLowerCase();
      ruleSets.add(_rcIps.contains(c) ? '$_rcIp/$c.srs' : '$_sgIp/geoip-$c.srs');
    } else if (InternetAddress.tryParse(e.split('/').first) != null) {
      cidrs.add(e.contains('/') ? e : (e.contains(':') ? '$e/128' : '$e/32'));
    }
  }
  if (ruleSets.isEmpty && domains.isEmpty && suffixes.isEmpty && keywords.isEmpty && regexes.isEmpty && cidrs.isEmpty) {
    return null;
  }
  return Rule(
    name: 'happify:$name',
    enabled: true,
    outbound: outbound,
    ruleSets: ruleSets,
    domains: domains,
    domainSuffixes: suffixes,
    domainKeywords: keywords,
    domainRegexes: regexes,
    ipCidrs: cidrs,
  );
}

/// The rules of a Happ profile, in its RouteOrder. Domain and IP lists are separate rules, so a rule set
/// never has to match together with a domain list.
List<Rule> happRoutingRules(Map<String, dynamic> profile) {
  final order = '${profile['RouteOrder'] ?? 'block-proxy-direct'}'.toLowerCase().split('-');
  final rules = <Rule>[];
  for (final kind in order) {
    final (outbound, key) = switch (kind) {
      'block' => (Outbound.block, 'Block'),
      'proxy' => (Outbound.proxy, 'Proxy'),
      'direct' => (Outbound.direct, 'Direct'),
      _ => (null, ''),
    };
    if (outbound == null) continue;
    final sites = _rule('$kind-sites', outbound, _list(profile['${key}Sites']), []);
    final ips = _rule('$kind-ip', outbound, [], _list(profile['${key}Ip']));
    if (sites != null) rules.add(sites);
    if (ips != null) rules.add(ips);
  }
  return rules;
}

/// The subscription's routing link, when the active profile sent one.
final subscriptionRoutingLinkProvider = Provider<String?>((ref) {
  final headers = ref.watch(activeProfileProvider).valueOrNull?.populatedHeaders;
  final v = headers?['routing']?.toString().trim();
  return (v == null || v.isEmpty) ? null : v;
});

/// Downloads a routing profile given by its address; empty text when it can't be read.
/// Routing files are small: anything bigger is refused.
const happRoutingMaxBytes = 1024 * 1024;

/// Only https, so nobody on the way can swap the rules.
bool happRoutingUrlAllowed(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

/// Downloads a routing file: https only, no redirects, at most 1 MiB. Empty when it can't.
Future<String> fetchRoutingText(String url) async {
  if (!happRoutingUrlAllowed(url)) return '';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(url.trim()));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return '';
    if (response.contentLength > happRoutingMaxBytes) return '';
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > happRoutingMaxBytes) return '';
    }
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return '';
  } finally {
    client.close(force: true);
  }
}

/// The last subscription routing file that was read, so a failed download keeps the old rules.
final _subRoutingCache = PreferencesNotifier.create<String, String>("happify_sub_routing_cache", "");

/// The subscription's routing profile: the link itself, or the JSON file it points to.
/// A download that fails falls back to the last one read for the same link.
/// null while loading; a null profile with done == true means it couldn't be read.
final subscriptionRoutingProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final link = ref.watch(subscriptionRoutingLinkProvider);
  if (link == null) return null;
  if (!link.startsWith('http://') && !link.startsWith('https://')) return parseHappRouting(link);
  final key = clipHash(link);
  final text = await fetchRoutingText(link);
  final fresh = parseHappRouting(text);
  if (fresh != null) {
    await ref.read(_subRoutingCache.notifier).update('$key\n$text');
    return fresh;
  }
  final cached = ref.read(_subRoutingCache);
  final cut = cached.indexOf('\n');
  if (cut > 0 && cached.substring(0, cut) == key) return parseHappRouting(cached.substring(cut + 1));
  return null;
});

/// RoscomVPN's block list without torrents, when the user allowed them.
Map<String, dynamic> happWithTorrents(Map<String, dynamic> profile, bool allow) {
  if (!allow) return profile;
  return {
    ...profile,
    'BlockSites': _list(profile['BlockSites']).where((e) => e != 'geosite:torrent').toList(),
  };
}

/// The rules the chosen profile adds before the user's own; empty when it is off or unreadable.
final happifyRoutingRulesProvider = Provider<List<Rule>>((ref) {
  final preset = ref.watch(HappifyRoutingPrefs.preset);
  final profile = switch (preset) {
    HappifyRouting.off => null,
    HappifyRouting.roscomvpn => happWithTorrents(_roscomDefault, ref.watch(HappifyRoutingPrefs.allowTorrents)),
    HappifyRouting.roscomvpnWhitelist => happWithTorrents(_roscomWhitelist, ref.watch(HappifyRoutingPrefs.allowTorrents)),
    HappifyRouting.subscription => ref.watch(subscriptionRoutingProfileProvider).valueOrNull,
    HappifyRouting.custom => parseHappRouting(ref.watch(HappifyRoutingPrefs.customJson)),
  };
  if (profile == null) return const [];
  return happRoutingRules(profile);
});

Future<void> setHappifyRouting(WidgetRef ref, HappifyRouting value) async {
  await ref.read(HappifyRoutingPrefs.preset.notifier).update(value);
  if (value != HappifyRouting.off) await ref.read(HappifyRoutingPrefs.lastOn.notifier).update(value);
}

/// Asks for a custom profile: a happ://routing link, JSON, base64, or the address of a JSON file.
Future<bool> askCustomRouting(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final input = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(hr(context, 'Свой профиль маршрутизации', 'Custom routing profile')),
      content: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 5,
        decoration: InputDecoration(
          hintText: hr(context, 'happ://routing/..., JSON или https://...', 'happ://routing/..., JSON or https://...'),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(hr(context, 'Отмена', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(hr(context, 'Применить', 'Apply'))),
      ],
    ),
  );
  if (input == null || input.trim().isEmpty) return false;
  var text = input.trim();
  if (text.startsWith('http://') || text.startsWith('https://')) text = await fetchRoutingText(text);
  final profile = parseHappRouting(text);
  final notifications = ref.read(inAppNotificationControllerProvider);
  if (profile == null) {
    if (context.mounted) {
      notifications.showErrorToast(hr(context, 'Не удалось прочитать профиль', 'Could not read the profile'));
    }
    return false;
  }
  await ref.read(HappifyRoutingPrefs.customJson.notifier).update(jsonEncode(profile));
  await setHappifyRouting(ref, HappifyRouting.custom);
  if (context.mounted) {
    final name = profile['Name']?.toString();
    notifications.showSuccessToast(
      hr(context, 'Профиль ${name ?? ''} применён', 'Profile ${name ?? ''} applied').replaceAll('  ', ' '),
    );
  }
  return true;
}

/// The routing profile picker: every option, with a line on what it does.
class HappifyRoutingSection extends ConsumerWidget {
  const HappifyRoutingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(HappifyRoutingPrefs.preset);
    final hasSub = ref.watch(subscriptionRoutingLinkProvider) != null;
    final hasCustom = ref.watch(HappifyRoutingPrefs.customJson).isNotEmpty;
    final subProfile = ref.watch(subscriptionRoutingProfileProvider);
    final subFailed = hasSub && subProfile.hasValue && subProfile.value == null;
    final roscom = preset == HappifyRouting.roscomvpn || preset == HappifyRouting.roscomvpnWhitelist;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            hr(context, 'Профиль маршрутизации', 'Routing profile'),
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            hr(
              context,
              'Решает, какие сайты идут через VPN, а какие напрямую. Напрямую быстрее и не ломает банки и госуслуги, которые не любят зарубежные IP. Белые списки нужны, когда мобильный оператор пускает только на разрешённые сайты.',
              'Decides which sites go through the VPN and which go direct. Direct is faster and keeps banks and government sites working, which dislike foreign IPs. The whitelist is for when the mobile carrier only lets you reach allowed sites.',
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final option in HappifyRouting.values)
          if (option != HappifyRouting.subscription || hasSub || preset == option)
            RadioListTile<HappifyRouting>.adaptive(
              value: option,
              groupValue: preset,
              title: Text(option.present(context)),
              subtitle: Text(
                option == HappifyRouting.subscription && subFailed
                    ? hr(
                        context,
                        'Подписка прислала маршрутизацию, но её не удалось прочитать. Правила не применены',
                        'The subscription sent routing that couldn\'t be read. No rules applied',
                      )
                    : option.explain(context),
              ),
              secondary: option == HappifyRouting.custom && hasCustom
                  ? IconButton(
                      icon: const Icon(Icons.edit_rounded),
                      tooltip: hr(context, 'Заменить', 'Replace'),
                      onPressed: () => askCustomRouting(context, ref),
                    )
                  : null,
              onChanged: (value) async {
                if (value == null) return;
                if (value == HappifyRouting.custom && !hasCustom) {
                  await askCustomRouting(context, ref);
                } else {
                  await setHappifyRouting(ref, value);
                }
              },
            ),
        if (roscom)
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.downloading_rounded),
            title: Text(hr(context, 'Разрешить торренты', 'Allow torrents')),
            subtitle: Text(
              hr(
                context,
                'RoscomVPN блокирует торренты, чтобы не подставлять сервер жалобами правообладателей. Включи, если пользуешься торрент-клиентом',
                'RoscomVPN blocks torrents to keep copyright complaints off the server. Turn on if you use a torrent client',
              ),
            ),
            value: ref.watch(HappifyRoutingPrefs.allowTorrents),
            onChanged: ref.read(HappifyRoutingPrefs.allowTorrents.notifier).update,
          ),
      ],
    );
  }
}

/// The quick switch: turns the last chosen profile on and off; a tap on the title opens the choice.
class HappifyRoutingQuickTile extends ConsumerWidget {
  const HappifyRoutingQuickTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(HappifyRoutingPrefs.preset);
    final lastOn = ref.watch(HappifyRoutingPrefs.lastOn);
    final on = preset != HappifyRouting.off;
    return ListTile(
      leading: const Icon(Icons.alt_route_rounded),
      title: Text(hr(context, 'Маршрутизация', 'Routing')),
      subtitle: Text((on ? preset : lastOn).present(context) + (on ? '' : hr(context, ' (выкл.)', ' (off)'))),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => const SafeArea(child: SingleChildScrollView(child: HappifyRoutingSection())),
      ),
      trailing: Switch.adaptive(
        value: on,
        onChanged: (value) => setHappifyRouting(ref, value ? lastOn : HappifyRouting.off),
      ),
    );
  }
}
