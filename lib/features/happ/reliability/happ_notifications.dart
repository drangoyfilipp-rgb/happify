import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/localization/locale_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/reliability/happ_notify_rules.dart';
import 'package:hiddify/features/happ/reliability/happ_platform.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bumped when a «Уведомления» switch changes, so the screen reads them again.
final happNotifyRevision = StateProvider<int>((ref) => 0);

bool happNotifyEnabled(SharedPreferences? prefs, HappNotifyType type) => happNotifyOn(type, prefs?.getBool(type.prefKey));

/// Posts a notification of [type] when the user has it on. [ru]/[en]: (title, text).
Future<void> happNotify(
  SharedPreferences? prefs,
  HappNotifyType type, {
  required bool isRu,
  required (String, String) ru,
  required (String, String) en,
  String? profileId,
}) async {
  if (!PlatformUtils.isAndroid || !happNotifyEnabled(prefs, type)) return;
  final (title, text) = isRu ? ru : en;
  await HappPlatform.notify(id: type.idFor(profileId), title: title, text: text, important: type.important);
}

/// Whether notifications are written in Russian: the app's language.
bool happIsRu(Ref ref) => ref.read(localePreferencesProvider).languageCode == 'ru';

/// Watches what the notifications are about while the app runs: the subscriptions' end and
/// traffic (at start, after each change, then hourly), the VPN failing to connect, and updates.
final happNotificationsWatcherProvider = Provider<void>((ref) {
  if (!PlatformUtils.isAndroid) return;

  void checkSubscriptions(List<ProfileEntity> profiles) {
    final prefs = ref.read(sharedPreferencesProvider).valueOrNull;
    if (prefs == null) return;
    final now = DateTime.now();
    for (final p in profiles) {
      if (p is! RemoteProfileEntity) continue;
      final sub = p.subInfo;
      if (sub == null) continue;
      // the end date
      if (sub.expire.year > 1971) {
        final key = 'happify_notified_exp_${p.id}';
        final sent = happReadExpirySent(prefs.getString(key), sub.expire);
        final due = happExpiryWarning(expire: sub.expire, now: now, sent: sent);
        if (due != null && happNotifyEnabled(prefs, HappNotifyType.subExpiring)) {
          // marked before posting: a crash in between never posts it twice
          unawaited(prefs.setString(key, happWriteExpirySent(sub.expire, {...sent, due, if (due == 1) 3})));
          // the days really left: the app may have been closed when the warning fell due
          final days = happDaysLeft(expire: sub.expire, now: now);
          unawaited(
            happNotify(
              prefs,
              HappNotifyType.subExpiring,
              isRu: happIsRu(ref),
              profileId: p.id,
              ru: ('Подписка «${p.name}» скоро закончится', '${happDaysLeftText(days, ru: true)}. Продлите, чтобы VPN не отключился'),
              en: ('Subscription "${p.name}" ends soon', '${happDaysLeftText(days, ru: false)}. Renew it to keep the VPN working'),
            ),
          );
        }
      }
      // the traffic
      if (happTrafficLow(used: sub.consumption, total: sub.total)) {
        final key = 'happify_notified_traffic_${p.id}';
        final period = happTrafficPeriod(sub.total, sub.expire.year > 1971 ? sub.expire : null);
        if (prefs.getString(key) != period && happNotifyEnabled(prefs, HappNotifyType.trafficLow)) {
          unawaited(prefs.setString(key, period));
          final left = sub.total - sub.consumption;
          final leftGb = (left < 0 ? 0 : left) / (1 << 30);
          unawaited(
            happNotify(
              prefs,
              HappNotifyType.trafficLow,
              isRu: happIsRu(ref),
              profileId: p.id,
              ru: ('Трафик подписки «${p.name}» заканчивается', 'Осталось ${leftGb.toStringAsFixed(1).replaceAll('.', ',')} ГБ'),
              en: ('Traffic of "${p.name}" is running out', '${leftGb.toStringAsFixed(1)} GB left'),
            ),
          );
        }
      }
    }
  }

  ref.listen(profilesNotifierProvider, (_, next) {
    if (next.valueOrNull case final list?) checkSubscriptions(list);
  }, fireImmediately: true);
  final hourly = Timer.periodic(const Duration(hours: 1), (_) {
    if (ref.read(profilesNotifierProvider).valueOrNull case final list?) checkSubscriptions(list);
  });
  ref.onDispose(hourly.cancel);

  // the VPN could not connect: a failure the user did not cause
  DateTime? lastProblem;
  ref.listen(connectionNotifierProvider, (previous, next) {
    final now = next.valueOrNull;
    final failed = now is Disconnected && now.connectionFailure != null && previous?.valueOrNull is! Disconnected;
    if (!failed) return;
    if (!happNoInternetNotifyDue(lastProblem, DateTime.now())) return;
    lastProblem = DateTime.now();
    unawaited(
      happNotify(
        ref.read(sharedPreferencesProvider).valueOrNull,
        HappNotifyType.vpnProblem,
        isRu: happIsRu(ref),
        ru: ('VPN не смог подключиться', 'Откройте Happify, чтобы увидеть причину'),
        en: ('The VPN could not connect', 'Open Happify to see why'),
      ),
    );
  });
});

/// «Уведомления»: a switch per kind, each with a line on what it is.
class HappNotificationsPage extends ConsumerWidget {
  const HappNotificationsPage({super.key});

  static (String, String, String, String) _texts(HappNotifyType t) => switch (t) {
    HappNotifyType.subExpiring => (
      'Подписка заканчивается',
      'За 3 дня и за 1 день до конца подписки',
      'Subscription ending',
      '3 days and 1 day before the subscription ends',
    ),
    HappNotifyType.trafficLow => (
      'Трафик заканчивается',
      'Когда осталось меньше 10% трафика подписки',
      'Traffic running out',
      'When less than 10% of the subscription\'s traffic is left',
    ),
    HappNotifyType.vpnProblem => (
      'VPN не подключается / нет интернета',
      'Если VPN не смог подключиться или пропал интернет',
      'VPN can\'t connect / no internet',
      'When the VPN could not connect or the internet is gone',
    ),
    HappNotifyType.serverSwitched => (
      'Смена сервера',
      'Когда автопереключение выбрало другой сервер',
      'Server switched',
      'When automatic switching picked another server',
    ),
    HappNotifyType.throttled => (
      'Канал душат — резерв',
      'Когда все серверы одного протокола перестали работать и включён другой протокол',
      'Throttled — reserve',
      'When every server of one protocol stopped working and another protocol is used',
    ),
    HappNotifyType.subUpdated => (
      'Подписка обновлена',
      'После каждого обновления подписки',
      'Subscription updated',
      'After each subscription update',
    ),
    HappNotifyType.testResults => (
      'Результаты пинга и скорости',
      'Когда проверка пинга или скорости закончилась',
      'Ping and speed results',
      'When a ping or speed test is done',
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(happNotifyRevision);
    final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    final theme = Theme.of(context);
    Widget tile(HappNotifyType t) {
      final (ruT, ruS, enT, enS) = _texts(t);
      return SwitchListTile.adaptive(
        title: Text(hr(context, ruT, enT)),
        subtitle: Text(hr(context, ruS, enS)),
        value: happNotifyEnabled(prefs, t),
        onChanged: prefs == null
            ? null
            : (v) async {
                await prefs.setBool(t.prefKey, v);
                ref.read(happNotifyRevision.notifier).state++;
              },
      );
    }

    Widget header(String ru, String en) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(hr(context, ru, en), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );

    return Scaffold(
      appBar: AppBar(title: Text(hr(context, 'Уведомления', 'Notifications'))),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              hr(
                context,
                'По умолчанию включено только важное. Уведомления приходят, пока Happify запущен (в фоне тоже). Уведомление самого VPN настраивается отдельно: «Уведомление VPN» в настройках.',
                'Only what matters is on by default. They come while Happify runs (in the background too). The VPN\'s own notification is set separately: "VPN notification" in the settings.',
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          header('Важные', 'Important'),
          for (final t in HappNotifyType.values.where((t) => t.defaultOn)) tile(t),
          header('Дополнительные', 'Extra'),
          for (final t in HappNotifyType.values.where((t) => !t.defaultOn)) tile(t),
          ListTile(
            leading: const Icon(Icons.settings_rounded),
            title: Text(hr(context, 'Системные настройки уведомлений', 'System notification settings')),
            subtitle: Text(hr(context, 'Если уведомления не приходят, проверьте, что Android их не выключил', 'If nothing comes, check Android has not turned them off')),
            onTap: () async {
              try {
                await const MethodChannelOpener().open();
              } catch (_) {}
            },
          ),
        ],
      ),
    );
  }
}

/// Opens the system page of the app's notifications.
class MethodChannelOpener {
  const MethodChannelOpener();
  Future<void> open() => const MethodChannel('com.hiddify.app/platform').invokeMethod<bool>('open_notification_settings');
}

