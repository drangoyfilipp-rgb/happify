import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_device.dart';
import 'package:hiddify/features/happ/happify_lifecycle.dart';
import 'package:hiddify/features/happ/happify_routing.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _platform = MethodChannel('com.hiddify.app/platform');

/// "Expert mode": brings back every Hiddify setting hidden in the simple mode.
class ExpertModeTile extends ConsumerWidget {
  const ExpertModeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      secondary: const Icon(Icons.engineering_rounded),
      title: Text(hr(context, 'Режим эксперта', 'Expert mode')),
      subtitle: Text(
        hr(
          context,
          'Показать DNS, порты, фрагментацию TLS, правила маршрутизации, логи и другие тонкие настройки',
          'Show DNS, ports, TLS fragment, routing rules, logs and other fine-tuning',
        ),
      ),
      value: ref.watch(HappifyPrefs.expertMode),
      onChanged: ref.read(HappifyPrefs.expertMode.notifier).update,
    );
  }
}

/// "Показывать lowest и balance": the two core groups as rows in the server lists, home included.
/// On the main settings page and first in Settings → General, where it is easy to find.
class ShowBalancersTile extends ConsumerWidget {
  const ShowBalancersTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      key: const ValueKey('happify_show_balancers_tile'),
      secondary: const Icon(Icons.call_split_rounded),
      title: Text(hr(context, 'Показывать lowest и balance', 'Show lowest and balance')),
      subtitle: Text(
        hr(
          context,
          'Группы в списке серверов: lowest берёт самый быстрый сервер, balance распределяет соединения по всем',
          'Groups in the server list: lowest takes the fastest server, balance spreads connections over all',
        ),
      ),
      value: ref.watch(HappifyPrefs.showBalancers),
      onChanged: ref.read(HappifyPrefs.showBalancers.notifier).update,
    );
  }
}

/// The everyday Happify options: autoconnect, clipboard, always-on VPN, device id.
class HappifyGeneralTiles extends ConsumerWidget {
  const HappifyGeneralTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const ShowBalancersTile(),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.power_settings_new_rounded),
          title: Text(hr(context, 'Подключаться при запуске', 'Connect on app start')),
          subtitle: Text(
            hr(context, 'Открыл приложение, и VPN включается сам', 'Opening the app turns the VPN on'),
          ),
          value: ref.watch(HappifyPrefs.autoConnectOnStart),
          onChanged: ref.read(HappifyPrefs.autoConnectOnStart.notifier).update,
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.autorenew_rounded),
          title: Text(hr(context, 'Держать VPN включённым', 'Keep VPN on')),
          subtitle: Text(
            hr(
              context,
              'После сбоя или обрыва VPN подключится снова сам. Если выключишь его кнопкой, он останется выключенным',
              'Reconnects by itself after a failure or a drop. A stop with the button stays a stop',
            ),
          ),
          value: ref.watch(HappifyPrefs.keepConnected),
          onChanged: ref.read(HappifyPrefs.keepConnected.notifier).update,
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.history_rounded),
          title: Text(hr(context, 'Последний сервер', 'Last server')),
          subtitle: Text(
            hr(context, 'Подключаться к серверу, который был выбран в прошлый раз', 'Connect to the server picked last time'),
          ),
          value: ref.watch(HappifyPrefs.rememberLastServer),
          onChanged: ref.read(HappifyPrefs.rememberLastServer.notifier).update,
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.system_update_rounded),
          title: Text(hr(context, 'Проверять обновления', 'Check for updates')),
          subtitle: Text(hr(context, 'При запуске, не чаще раза в 6 ч.', 'On start, at most every 6 h')),
          value: ref.watch(HappifyPrefs.checkUpdates),
          onChanged: ref.read(HappifyPrefs.checkUpdates.notifier).update,
        ),
        // the rest works well as it is; it is there for whoever wants to change it
        if (ref.watch(HappifyPrefs.expertMode)) ...[
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.sync_rounded),
          title: Text(hr(context, 'Обновлять подписку при открытии', 'Update subscription on open')),
          subtitle: Text(hr(context, 'Не чаще раза в 10 минут', 'At most every 10 minutes')),
          value: ref.watch(HappifyPrefs.updateOnOpen),
          onChanged: ref.read(HappifyPrefs.updateOnOpen.notifier).update,
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.network_ping_rounded),
          title: Text(hr(context, 'Пинг при открытии', 'Ping on open')),
          subtitle: Text(
            hr(context, 'Проверить все серверы после обновления подписки', 'Test every server after the subscription update'),
          ),
          value: ref.watch(HappifyPrefs.pingOnOpen),
          onChanged: ref.read(HappifyPrefs.pingOnOpen.notifier).update,
        ),
        const _PingMethodTile(),
        ],
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.content_paste_go_rounded),
          title: Text(hr(context, 'Ссылка из буфера обмена', 'Link from clipboard')),
          subtitle: Text(
            hr(
              context,
              'Скопировал ссылку на подписку, и приложение предложит её добавить',
              'Copy a subscription link and the app offers to add it',
            ),
          ),
          value: ref.watch(HappifyPrefs.clipboardDetect),
          onChanged: ref.read(HappifyPrefs.clipboardDetect.notifier).update,
        ),
        if (PlatformUtils.isAndroid)
          ListTile(
            leading: const Icon(Icons.vpn_key_rounded),
            title: Text(hr(context, 'Кнопка VPN в шторке', 'VPN button in quick settings')),
            subtitle: Text(
              hr(
                context,
                'Включать и выключать VPN из шторки, рядом с Bluetooth и режимом полёта',
                'Turn the VPN on and off from the quick settings, next to Bluetooth and airplane mode',
              ),
            ),
            onTap: () async {
              String? answer;
              try {
                answer = await _platform.invokeMethod<String>('add_qs_tile');
              } catch (_) {}
              if (!context.mounted) return;
              final added = answer == '1' || answer == '2';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    added
                        ? hr(context, 'Кнопка Happify в шторке', 'The Happify button is in quick settings')
                        : hr(
                            context,
                            'Опусти шторку, нажми карандаш и перетащи плитку Happify наверх',
                            'Pull down quick settings, tap the pencil and drag the Happify tile up',
                          ),
                  ),
                ),
              );
            },
          ),
        ListTile(
          leading: const Icon(Icons.fingerprint_rounded),
          title: Text(hr(context, 'ID устройства (HWID)', 'Device ID (HWID)')),
          subtitle: Text(HappDevice.hwid.isEmpty ? '—' : HappDevice.hwid),
          trailing: const Icon(Icons.copy_rounded),
          onTap: () async {
            if (HappDevice.hwid.isEmpty) return;
            await Clipboard.setData(ClipboardData(text: HappDevice.hwid));
            if (!context.mounted) return;
            ref
                .read(inAppNotificationControllerProvider)
                .showSuccessToast(hr(context, 'HWID скопирован', 'HWID copied'));
          },
        ),
      ],
    );
  }
}

/// The ping: an HTTP HEAD request through each server to the test address; the address can change.
class _PingMethodTile extends ConsumerWidget {
  const _PingMethodTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(ConfigOptions.connectionTestUrl);
    final options = ref.read(ConfigOptions.connectionTestUrl.notifier).possibleValues ?? const <String>[];
    return ListTile(
      leading: const Icon(Icons.speed_rounded),
      title: Text(hr(context, 'Пинг: HEAD-запрос через сервер', 'Ping: HEAD request through the server')),
      subtitle: Text(url),
      trailing: PopupMenuButton<String>(
        initialValue: url,
        icon: const Icon(Icons.arrow_drop_down_rounded),
        onSelected: ref.read(ConfigOptions.connectionTestUrl.notifier).update,
        itemBuilder: (_) => [for (final e in options) PopupMenuItem(value: e, child: Text(e))],
      ),
    );
  }
}

/// Whether [text] looks like something the add-profile flow takes: a subscription or a config link.
bool looksLikeSubscription(String text) {
  final s = text.trim();
  if (s.isEmpty || s.length > 4096 || s.contains('\n')) return false;
  final lower = s.toLowerCase();
  const schemes = [
    'vless://',
    'vmess://',
    'trojan://',
    'ss://',
    'ssr://',
    'hy2://',
    'hysteria://',
    'hysteria2://',
    'tuic://',
    'wireguard://',
    'wg://',
    'happ://add/',
    'hiddify://',
    'sing-box://',
    'clash://',
    'v2rayng://',
  ];
  if (schemes.any(lower.startsWith)) return true;
  if (lower.startsWith('https://') || lower.startsWith('http://')) {
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return false;
    // a plain web page is not offered: a subscription path or a panel link is
    final path = '${uri.path}?${uri.query}'.toLowerCase();
    return path.contains('sub') ||
        path.contains('/s/') ||
        path.contains('token') ||
        path.contains('config') ||
        path.contains('happ') ||
        path.contains('link') ||
        RegExp(r'/[a-z0-9_-]{16,}').hasMatch(path);
  }
  return false;
}

/// Watches the clipboard when the app opens or comes back to the front, and offers to add a
/// subscription link it finds there, once per link. Wraps the app.
class ClipboardSubscriptionWatcher extends HookConsumerWidget {
  const ClipboardSubscriptionWatcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useRef(false);

    Future<void> check() async {
      if (busy.value || !ref.read(HappifyPrefs.clipboardDetect) || !ref.read(Preferences.introCompleted)) return;
      busy.value = true;
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text?.trim() ?? '';
        // a Happ routing link: offered as the custom routing profile
        if (text.startsWith('happ://routing/') && clipHash(text) != ref.read(HappifyPrefs.lastClipboardOffer)) {
          await ref.read(HappifyPrefs.lastClipboardOffer.notifier).update(clipHash(text));
          final profile = parseHappRouting(text);
          if (profile == null || !context.mounted) return;
          final apply = await ref
              .read(dialogNotifierProvider.notifier)
              .showConfirmation(
                title: hr(context, 'Применить маршрутизацию?', 'Apply routing?'),
                message: hr(
                  context,
                  'В буфере обмена профиль маршрутизации ${profile['Name'] ?? ''}. Он заменит текущий',
                  'The clipboard has the routing profile ${profile['Name'] ?? ''}. It replaces the current one',
                ),
                icon: Icons.alt_route_rounded,
                positiveBtnTxt: hr(context, 'Применить', 'Apply'),
              );
          if (apply) {
            await ref.read(HappifyRoutingPrefs.customJson.notifier).update(jsonEncode(profile));
            await setHappifyRouting(ref, HappifyRouting.custom);
          }
          return;
        }
        if (!looksLikeSubscription(text)) return;
        if (clipHash(text) == ref.read(HappifyPrefs.lastClipboardOffer)) return;
        await ref.read(HappifyPrefs.lastClipboardOffer.notifier).update(clipHash(text));
        // a link already among the profiles is not offered again
        final repo = ref.read(profileRepositoryProvider).valueOrNull;
        if (repo != null) {
          final profiles = await repo.watchAll().first;
          final known = profiles.getOrElse((_) => const <ProfileEntity>[]);
          for (final p in known) {
            if (p is RemoteProfileEntity && (p.url == text || text.endsWith(p.url))) return;
          }
        }
        if (!context.mounted) return;
        final shown = text.length > 70 ? '${text.substring(0, 70)}…' : text;
        final add = await ref
            .read(dialogNotifierProvider.notifier)
            .showConfirmation(
              title: hr(context, 'Добавить подписку?', 'Add subscription?'),
              message: hr(context, 'В буфере обмена ссылка:\n$shown', 'The clipboard has a link:\n$shown'),
              icon: Icons.content_paste_go_rounded,
              positiveBtnTxt: hr(context, 'Добавить', 'Add'),
            );
        if (add) await ref.read(addProfileNotifierProvider.notifier).addClipboard(text);
      } catch (_) {
        // the clipboard is not always readable; nothing to offer then
      } finally {
        busy.value = false;
      }
    }

    useOnAppLifecycleStateChange((_, state) {
      if (state == AppLifecycleState.resumed) unawaited(check());
    });
    useEffect(() {
      final timer = Timer(const Duration(seconds: 3), () => unawaited(check()));
      return timer.cancel;
    }, const []);
    return child;
  }
}

/// How long the VPN has been up, under the connect button: "00:12:34".
class ConnectionTimer extends HookConsumerWidget {
  const ConnectionTimer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final since = ref.watch(HappifyPrefs.connectedSince);
    final connected = status is Connected || status is HotReloading;
    final tick = useState(0);

    useEffect(() {
      final notifier = ref.read(HappifyPrefs.connectedSince.notifier);
      if (connected && since == 0) {
        Future.microtask(() => notifier.update(DateTime.now().millisecondsSinceEpoch));
      } else if (status is Disconnected && since != 0) {
        Future.microtask(() => notifier.update(0));
      }
      return null;
    }, [connected, status is Disconnected, since]);

    useEffect(() {
      if (!connected) return null;
      final timer = Timer.periodic(const Duration(seconds: 1), (_) => tick.value++);
      return timer.cancel;
    }, [connected]);

    if (!connected || since == 0) return const SizedBox(height: 20);
    var elapsed = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(since));
    if (elapsed.isNegative) elapsed = Duration.zero;
    String two(int n) => n.toString().padLeft(2, '0');
    final text = elapsed.inDays > 0
        ? '${elapsed.inDays}${hr(context, 'д', 'd')} ${two(elapsed.inHours % 24)}:${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}'
        : '${two(elapsed.inHours)}:${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}';
    final theme = Theme.of(context);
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// «Kill switch»: Android's own Always-on VPN and «Блокировать соединения без VPN», which an app
/// cannot turn on itself; the current state, a how-to and a button to the system page.
class HappKillSwitchTile extends ConsumerWidget {
  const HappKillSwitchTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PlatformUtils.isAndroid) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.shield_rounded),
      title: Text(hr(context, 'Kill switch: блокировка без VPN', 'Kill switch: block without VPN')),
      subtitle: FutureBuilder(
        future: killSwitchState(),
        builder: (context, snap) {
          final state = snap.data;
          final status = state == null || !state.known
              ? hr(context, 'Состояние видно, когда VPN включён', 'The state shows while the VPN is on')
              : state.lockdown
              ? hr(context, 'Включён: без VPN интернета нет', 'On: no internet without the VPN')
              : state.alwaysOn
              ? hr(context, 'Постоянный VPN включён, блокировка выключена', 'Always-on is on, blocking is off')
              : hr(context, 'Выключен', 'Off');
          return Text(
            '$status\n' +
                hr(
                  context,
                  'Включается и выключается в настройках Android: выбери Happify, «Постоянная VPN» и «Блокировать соединения без VPN». Приложение само его менять не может',
                  'Turned on and off in Android settings: pick Happify, "Always-on VPN" and "Block connections without VPN". An app can\'t change it itself',
                ),
          );
        },
      ),
      trailing: const Icon(Icons.open_in_new_rounded),
      onTap: () async {
        // a short how-to first: Android hides these switches two screens deep
        final go = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.shield_rounded),
            title: Text(hr(context, 'Как включить kill switch', 'How to turn on the kill switch')),
            content: Text(
              hr(
                context,
                '1. Нажми «Открыть настройки VPN».\n'
                    '2. Найди Happify и нажми на шестерёнку рядом.\n'
                    '3. Включи «Постоянная VPN»: Android сам поднимет VPN после перезагрузки или сбоя.\n'
                    '4. По желанию включи «Блокировать соединения без VPN»: без VPN интернета не будет совсем.\n\n'
                    'Если что-то сломалось, выключи эти пункты там же, и интернет вернётся.',
                '1. Tap "Open VPN settings".\n'
                    '2. Find Happify and tap the gear next to it.\n'
                    '3. Turn on "Always-on VPN": Android brings the VPN back after a reboot or a crash.\n'
                    '4. If you want, turn on "Block connections without VPN": no internet at all without the VPN.\n\n'
                    'If something breaks, turn these off in the same place and the internet comes back.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(hr(context, 'Отмена', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(hr(context, 'Открыть настройки VPN', 'Open VPN settings')),
              ),
            ],
          ),
        );
        if (go != true || !context.mounted) return;
        try {
          await _platform.invokeMethod<bool>('open_vpn_settings');
        } catch (_) {
          ref
              .read(inAppNotificationControllerProvider)
              .showErrorToast(hr(context, 'Не удалось открыть настройки', 'Could not open settings'));
        }
      },
    );
  }
}
