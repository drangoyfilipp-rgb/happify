import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_traffic_saving.dart';
import 'package:hiddify/features/happ/reliability/happ_user_pick.dart';
import 'package:hiddify/features/happ/reliability/happ_wifi_status.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _platform = MethodChannel('com.hiddify.app/platform');

/// "Extra" section of the settings: Wi-Fi trigger and the IP cleanliness check.
class HappifyExtraTiles extends ConsumerWidget {
  const HappifyExtraTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            hr(context, 'Дополнительно', 'Extra'),
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        const _IpCheckTile(),
        const HappTrafficSavingTile(),
        if (PlatformUtils.isAndroid) const HappVpnNotificationTile(),
      ],
    );
  }

}

/// «Автоподключение по сети» (off by default): the VPN turns on by itself on mobile data and on
/// Wi-Fi that isn't trusted, and off when the phone joins a trusted Wi-Fi. Android does it
/// (HappifyWifiWatcher.kt), so it works with the app closed. Without location access Android hides
/// the Wi-Fi name: then only the network type counts (every Wi-Fi is untrusted).
class HappAutoConnectTiles extends ConsumerWidget {
  const HappAutoConnectTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PlatformUtils.isAndroid) return const SizedBox.shrink();
    final trusted = pinnedSet(ref.watch(HappifyExtraPrefs.trustedWifi));
    final on = ref.watch(HappifyExtraPrefs.wifiAuto);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.wifi_lock_rounded),
          title: Text(hr(context, 'Автоподключение по сети', 'Auto-connect by network')),
          subtitle: Text(
            hr(
              context,
              'VPN включается сам на мобильном интернете и в чужих Wi-Fi (кафе, отель), а в доверенных сетях (дом, работа) выключается. Работает и при закрытом приложении',
              'The VPN turns on by itself on mobile data and on other Wi-Fi (café, hotel), and turns off on trusted networks (home, work). Works with the app closed too',
            ),
          ),
          value: on,
          onChanged: ref.read(HappifyExtraPrefs.wifiAuto.notifier).update,
        ),
        if (on)
          ListTile(
            leading: const Icon(Icons.home_rounded),
            title: Text(hr(context, 'Доверенные Wi-Fi', 'Trusted Wi-Fi')),
            subtitle: Text(
              trusted.isEmpty
                  ? hr(context, 'Пока нет. Нажми, чтобы добавить сеть, к которой ты подключён сейчас', 'None yet. Tap to add the network you\'re on now')
                  : '${trusted.join(', ')}\n${hr(context, 'Нажми, чтобы добавить текущую или убрать сеть', 'Tap to add the current one or remove a network')}',
            ),
            onTap: () => _editTrusted(context, ref),
          ),
      ],
    );
  }
}

Future<Map<Object?, Object?>?> _wifiInfo() async {
  try {
    return await _platform.invokeMethod<Map<Object?, Object?>>('current_ssid').timeout(const Duration(seconds: 4));
  } catch (_) {
    return null;
  }
}

Future<void> _editTrusted(BuildContext context, WidgetRef ref) async {
  final first = await _wifiInfo();
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (context) => _TrustedWifiDialog(first: first));
}

/// The trusted networks, and the Wi-Fi the phone is on now (the one under the VPN). Looks again
/// every 2 s while open, so it catches up after the permission or location is turned on.
class _TrustedWifiDialog extends HookConsumerWidget {
  const _TrustedWifiDialog({required this.first});
  final Map<Object?, Object?>? first;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = useState(first);
    final isMounted = useIsMounted();
    useEffect(() {
      final timer = Timer.periodic(const Duration(seconds: 2), (_) async {
        final next = await _wifiInfo();
        if (isMounted() && next != null) info.value = next;
      });
      return timer.cancel;
    }, const []);
    final (:status, :ssid) = happWifiStatusOf(info.value);
    final trusted = pinnedSet(ref.watch(HappifyExtraPrefs.trustedWifi));
    Future<void> call(String method) async {
      try {
        await _platform.invokeMethod<void>(method);
      } catch (_) {}
    }

    final text = switch (status) {
      HappWifiStatus.named => hr(context, 'Сейчас: $ssid', 'Now: $ssid'),
      HappWifiStatus.notOnWifi => hr(context, 'Сейчас ты не подключён к Wi-Fi.', 'You\'re not on Wi-Fi right now.'),
      HappWifiStatus.needPermission => hr(
        context,
        'Ты в Wi-Fi, но Android показывает имя сети только приложениям с доступом к геолокации. Happify не следит за местоположением, разрешение нужно только чтобы узнать имя сети.',
        'You\'re on Wi-Fi, but Android only shows the network name to apps with location access. Happify doesn\'t track your location; it only needs this to read the network name.',
      ),
      HappWifiStatus.locationOff => hr(
        context,
        'Ты в Wi-Fi, но геолокация на телефоне выключена, а без неё Android скрывает имя сети. Включи её, чтобы добавить сеть (потом можно снова выключить).',
        'You\'re on Wi-Fi, but location is off on the phone, and without it Android hides the network name. Turn it on to add the network (you can turn it off again later).',
      ),
      HappWifiStatus.hidden => hr(
        context,
        'Ты в Wi-Fi, но телефон не сообщает имя сети. Попробуй переподключиться к Wi-Fi.',
        'You\'re on Wi-Fi, but the phone doesn\'t tell the network name. Try reconnecting to the Wi-Fi.',
      ),
    };
    return AlertDialog(
      title: Text(hr(context, 'Доверенные сети', 'Trusted networks')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text),
            if (status == HappWifiStatus.needPermission)
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => call('open_app_settings'),
                child: Text(hr(context, 'Не спрашивает? Открыть настройки приложения', 'No prompt? Open app settings')),
              ),
            for (final name in trusted)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.wifi_rounded),
                title: Text(name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    trusted.remove(name);
                    await ref.read(HappifyExtraPrefs.trustedWifi.notifier).update(trusted.join('\n'));
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(hr(context, 'Готово', 'Done'))),
        switch (status) {
          HappWifiStatus.needPermission => FilledButton(
            onPressed: () => call('request_location'),
            child: Text(hr(context, 'Разрешить', 'Allow')),
          ),
          HappWifiStatus.locationOff => FilledButton(
            onPressed: () => call('open_location_settings'),
            child: Text(hr(context, 'Включить геолокацию', 'Turn on location')),
          ),
          HappWifiStatus.named when !trusted.contains(ssid) => FilledButton(
            onPressed: () async {
              trusted.add(ssid!);
              await ref.read(HappifyExtraPrefs.trustedWifi.notifier).update(trusted.join('\n'));
            },
            child: Text(hr(context, 'Добавить $ssid', 'Add $ssid')),
          ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }
}

/// What a check of the exit IP found.
class _IpVerdict {
  const _IpVerdict({required this.ip, required this.where, required this.clean, required this.notes});

  final String ip;
  final String where;
  final bool clean;
  final List<String> notes;
}

/// Checks the IP the sites see against abuse and datacenter databases (ipapi.is), so you know
/// why Google or Cloudflare keep asking for captchas, and swaps the server when it's flagged.
class _IpCheckTile extends ConsumerStatefulWidget {
  const _IpCheckTile();

  @override
  ConsumerState<_IpCheckTile> createState() => _IpCheckTileState();
}

class _IpCheckTileState extends ConsumerState<_IpCheckTile> {
  bool _busy = false;
  _IpVerdict? _verdict;
  String? _error;

  Future<_IpVerdict> _check() async {
    final isRu = Localizations.maybeLocaleOf(context)?.languageCode == 'ru';
    String pick(String ru, String en) => isRu ? ru : en;
    final client = ref.read(httpClientProvider);
    final response = await client.get<Map<String, dynamic>>('https://api.ipapi.is/', proxyOnly: true);
    final data = response.data;
    if (response.statusCode != 200 || data == null) throw Exception('no answer');
    bool flag(String key) => data[key] == true;
    final company = data['company'] is Map ? data['company'] as Map : const {};
    final asn = data['asn'] is Map ? data['asn'] as Map : const {};
    final location = data['location'] is Map ? data['location'] as Map : const {};
    final score = '${company['abuser_score'] ?? asn['abuser_score'] ?? ''}';
    final level = RegExp(r'\((.+)\)').firstMatch(score)?.group(1)?.toLowerCase() ?? '';
    final abuser = flag('is_abuser') || level.contains('high');
    final notes = <String>[
      if (flag('is_abuser')) pick('IP есть в базах спама и атак', 'The IP is in spam and attack databases'),
      if (level.isNotEmpty)
        pick('Жалобы на сеть: ${_level(level, true)}', 'Network abuse: ${_level(level, false)}'),
      if (flag('is_datacenter')) pick('Адрес дата-центра: банки и стриминги могут не пускать', 'Datacenter address: banks and streaming may refuse it'),
      if (flag('is_tor')) pick('Это выход Tor', 'This is a Tor exit'),
      if (!abuser && !flag('is_datacenter')) pick('Похоже на обычный домашний или мобильный IP', 'Looks like a regular home or mobile IP'),
    ];
    return _IpVerdict(
      ip: '${data['ip'] ?? '?'}',
      where: [location['country'], asn['org'] ?? company['name']].whereType<String>().join(' · '),
      clean: !abuser && !flag('is_tor'),
      notes: notes,
    );
  }

  String _level(String level, bool ru) => switch (level) {
    final l when l.contains('very high') => ru ? 'очень много' : 'very high',
    final l when l.contains('high') => ru ? 'много' : 'high',
    final l when l.contains('elevated') => ru ? 'выше обычного' : 'elevated',
    final l when l.contains('very low') => ru ? 'почти нет' : 'very low',
    final l when l.contains('low') => ru ? 'мало' : 'low',
    _ => level,
  };

  Future<void> _run() async {
    final status = ref.read(connectionNotifierProvider).valueOrNull;
    if (status?.isConnected != true) {
      setState(() => _error = hr(context, 'Сначала включи VPN', 'Turn the VPN on first'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verdict = await _check();
      if (mounted) setState(() => _verdict = verdict);
    } catch (_) {
      if (mounted) setState(() => _error = hr(context, 'Не удалось проверить, попробуй ещё раз', 'Couldn\'t check, try again'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks the fastest working server other than the current one, then checks again.
  Future<void> _switchServer() async {
    final repo = ref.read(proxyRepositoryProvider);
    final event = await repo.watchProxies().first;
    final group = event.toNullable();
    if (group == null) return;
    final others = group.items
        .where((item) => !item.isGroup && item.isVisible && item.tag != group.selected && ConnectionConst.isValidDelay(item.urlTestDelay))
        .toList()
      ..sort((a, b) => a.urlTestDelay.compareTo(b.urlTestDelay));
    if (others.isEmpty) {
      if (mounted) setState(() => _error = hr(context, 'Нет другого рабочего сервера', 'No other working server'));
      return;
    }
    setState(() => _busy = true);
    final picked = await repo.selectProxy(group.tag, others.first.tag).run();
    // the user asked for another server: theirs now, kept and returned to by the failover
    if (picked.isRight()) ref.read(happUserPickProvider.notifier).state = HappUserPick(group.tag, others.first.tag);
    await Future<void>.delayed(const Duration(seconds: 3));
    await _run();
  }

  @override
  Widget build(BuildContext context) {
    final verdict = _verdict;
    final lines = <String>[
      if (verdict == null && _error == null)
        hr(
          context,
          'Проверяет, не в спам-базах ли IP сервера. Если он «грязный», Google и Cloudflare заваливают капчами, а банки и стриминги могут не пускать. Тогда можно сразу сменить сервер',
          'Checks whether the server\'s IP is in spam databases. A dirty IP brings endless Google and Cloudflare captchas, and banks or streaming may refuse it. Then you can switch the server right away',
        ),
      if (_error != null) _error!,
      if (verdict != null) ...[
        '${verdict.clean ? hr(context, '✅ Чистый', '✅ Clean') : hr(context, '⚠️ Грязный: жди капчи', '⚠️ Dirty: expect captchas')} · ${verdict.ip}',
        if (verdict.where.isNotEmpty) verdict.where,
        ...verdict.notes,
      ],
    ];
    return ListTile(
      leading: const Icon(Icons.verified_user_rounded),
      title: Text(hr(context, 'Проверка чистоты IP', 'IP cleanliness check')),
      subtitle: Text(lines.join('\n')),
      isThreeLine: true,
      trailing: _busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : verdict != null && !verdict.clean
          ? TextButton(onPressed: _switchServer, child: Text(hr(context, 'Сменить', 'Switch')))
          : const Icon(Icons.search_rounded),
      onTap: _busy ? null : _run,
    );
  }
}

/// «Экономия трафика»: Авто (on mobile data) / Вкл / Выкл. It never reconnects the VPN.
class HappTrafficSavingTile extends ConsumerWidget {
  const HappTrafficSavingTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = happTrafficSavingMode(ref.watch(HappifyPrefs.trafficSaving));
    final on = ref.watch(happTrafficSavingProvider);
    String name(HappTrafficSaving m) => switch (m) {
      HappTrafficSaving.auto => hr(context, 'Авто', 'Auto'),
      HappTrafficSaving.on => hr(context, 'Вкл', 'On'),
      HappTrafficSaving.off => hr(context, 'Выкл', 'Off'),
    };
    return ListTile(
      leading: const Icon(Icons.data_saver_on_rounded),
      title: Text(hr(context, 'Экономия трафика', 'Traffic saving')),
      subtitle: Text(
        '${name(mode)}${mode == HappTrafficSaving.auto ? hr(context, ' (сейчас ${on ? 'включена: мобильный интернет' : 'выключена'})', ' (now ${on ? 'on: mobile data' : 'off'})') : ''}\n'
        '${hr(context, 'Пинг только по кнопке, подписка обновляется реже, IP не проверяется. Авто: включается сама на мобильном интернете. VPN не переподключается', 'Ping only on demand, the subscription updates less often, no IP lookup. Auto: turns on by itself on mobile data. The VPN never reconnects')}',
      ),
      isThreeLine: true,
      onTap: () async {
        final picked = await showDialog<HappTrafficSaving>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(hr(context, 'Экономия трафика', 'Traffic saving')),
            children: [
              for (final m in HappTrafficSaving.values)
                ListTile(
                  leading: Icon(m == mode ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
                  title: Text(name(m)),
                  subtitle: m == HappTrafficSaving.auto
                      ? Text(hr(context, 'Включается на мобильном интернете', 'On while on mobile data'))
                      : null,
                  onTap: () => Navigator.of(context).pop(m),
                ),
            ],
          ),
        );
        if (picked != null) await ref.read(HappifyPrefs.trafficSaving.notifier).update(picked.name);
      },
    );
  }
}

/// «Уведомление VPN»: on, the VPN's notification is always there (shown again after a swipe or
/// «Очистить всё»); off, it is as quiet as Android allows. Removing it never turns the VPN off.
class HappVpnNotificationTile extends HookConsumerWidget {
  const HappVpnNotificationTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = useState<({bool allowed, bool channel})?>(null);
    Future<void> read() async {
      try {
        final map = await _platform.invokeMapMethod<String, dynamic>('vpn_notification_state');
        state.value = (allowed: map?['allowed'] != false, channel: map?['channel'] != false);
      } catch (_) {}
    }

    useEffect(() {
      read();
      return null;
    }, const []);
    // back from the system settings: read again
    useOnAppLifecycleStateChange((_, s) {
      if (s == AppLifecycleState.resumed) read();
    });
    final blocked = state.value != null && !(state.value!.allowed && state.value!.channel);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: Text(hr(context, 'Уведомление VPN', 'VPN notification')),
          subtitle: Text(
            hr(
              context,
              'Всегда видно, что VPN включён. Если смахнуть или нажать «Очистить всё», уведомление вернётся. VPN при этом не выключается',
              'Always shows the VPN is on. Swiped away or cleared, it comes back. The VPN stays on',
            ),
          ),
          value: ref.watch(HappifyPrefs.vpnNotification),
          onChanged: ref.read(HappifyPrefs.vpnNotification.notifier).update,
        ),
        if (blocked)
          ListTile(
            leading: const Icon(Icons.notifications_off_outlined, color: Color(0xFFE5484D)),
            title: Text(hr(context, 'Уведомления выключены в Android', 'Notifications are off in Android')),
            subtitle: Text(hr(context, 'Нажмите, чтобы включить их в настройках телефона', 'Tap to turn them on in the phone settings')),
            onTap: () async {
              try {
                await _platform.invokeMethod<bool>('open_notification_settings');
              } catch (_) {}
            },
          ),
      ],
    );
  }
}
