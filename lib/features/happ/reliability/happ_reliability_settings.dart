import 'package:flutter/material.dart';
import 'package:hiddify/features/happ/happify_extras.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_tiles.dart';
import 'package:hiddify/features/happ/reliability/happ_bypass.dart';
import 'package:hiddify/features/happ/reliability/happ_diagnostics.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_runtime.dart';
import 'package:hiddify/features/happ/reliability/happ_notifications.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// «Надёжность» in the settings: what keeps the connection working, each with a line on what it does.
class HappReliabilitySection extends ConsumerWidget {
  const HappReliabilitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bypass = happBypassList(ref.watch(happBypassApps));
    final failures = ref.watch(happDiagnosticsProvider.select((r) => r.length));
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 4),
          child: Text(
            hr(context, 'Надёжность', 'Reliability'),
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.swap_horiz_rounded),
          title: Text(hr(context, 'Автопереключение при сбое', 'Switch on failure')),
          subtitle: Text(
            hr(
              context,
              'Раз в минуту (при включённом экране) проверяю, что через сервер есть интернет. Если сервер не отвечает 3 раза подряд (~30 с), а без VPN интернет есть, тихо перейду на самый быстрый рабочий сервер этой подписки; если не работает весь протокол — на другой, сначала Reality. Ваш сервер запомню и верну, когда он снова заработает. lowest и balance не трогаю',
              'Once a minute (screen on) I check the internet gets through the server. If it fails 3 times in a row (~30 s) while the internet works without the VPN, I quietly move to the fastest working server of this subscription; if the whole protocol is down, to another one, Reality first. Your server is remembered and comes back once it works. lowest and balance are left alone',
            ),
          ),
          value: ref.watch(happFailoverPref),
          onChanged: ref.read(happFailoverPref.notifier).update,
        ),
        if (PlatformUtils.isAndroid) ...[
          const HappAutoConnectTiles(),
          const HappKillSwitchTile(),
          ListTile(
            leading: const Icon(Icons.call_split_rounded),
            title: Text(hr(context, 'Мимо VPN', 'Bypass the VPN')),
            subtitle: Text(
              bypass.isEmpty
                  ? hr(
                      context,
                      'Приложения, которые ходят в интернет напрямую. Добавить можно из уведомления VPN: «Мимо VPN»',
                      'Apps that go online directly. Add one from the VPN notification: "Bypass"',
                    )
                  : hr(context, 'Напрямую: ${bypass.length}', 'Direct: ${bypass.length}'),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => open(const HappBypassPage()),
          ),
        ],
        ListTile(
          leading: const Icon(Icons.troubleshoot_rounded),
          title: Text(hr(context, 'Диагностика', 'Diagnostics')),
          subtitle: Text(
            failures == 0
                ? hr(
                    context,
                    'Какие приложения и сайты не смогли соединиться и почему. Без лишнего трафика',
                    'Which apps and sites failed to connect, and why. No extra traffic',
                  )
                : hr(context, 'Сбоев за сеанс: $failures', 'Failures this session: $failures'),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => open(const HappDiagnosticsPage()),
        ),
        if (PlatformUtils.isAndroid)
          ListTile(
            leading: const Icon(Icons.notifications_rounded),
            title: Text(hr(context, 'Уведомления', 'Notifications')),
            subtitle: Text(
              hr(
                context,
                'Что сообщать: конец подписки, трафик, проблемы с VPN — включено; остальное по желанию',
                'What to tell you: subscription end, traffic, VPN problems are on; the rest is up to you',
              ),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => open(const HappNotificationsPage()),
          ),
      ],
    );
  }
}
