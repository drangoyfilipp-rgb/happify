import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/features/happ/happ_announce_card.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_server_sort.dart';
import 'package:hiddify/features/happ/reliability/happ_profile_sort.dart';
import 'package:hiddify/features/happ/reliability/happ_profile_sort_state.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// «Изменить» in a subscription's «…» menu, as in Happ: one sheet with everything the user sets for
// it — the name, the subscription link, the message under the card, auto-update — and deleting it.

/// The message the user wrote for a profile, which wins over the subscription's own text and
/// outlives its updates: "happify_announce_<profile id>"; an empty string hides the row.
String happAnnounceKey(String profileId) => 'happify_announce_$profileId';

/// Bumped when a message above is saved, so the cards read it again.
final happAnnounceRevision = StateProvider<int>((ref) => 0);

typedef HappAnnounce = ({String text, Color? color, String? link});

/// What the card shows under the traffic: the user's own text, else the subscription's; null hides it.
HappAnnounce? happAnnounceOf(SharedPreferences? prefs, ProfileEntity profile) {
  final own = prefs?.getString(happAnnounceKey(profile.id));
  if (own != null) return own.trim().isEmpty ? null : (text: own, color: null, link: null);
  if (profile case final RemoteProfileEntity r) {
    final sub = HappAnnounceCard.contentOf(r);
    if (sub != null) return (text: sub.text, color: sub.color, link: sub.link);
  }
  return null;
}

/// The auto-update interval the subscription itself asks for (hours), from its headers.
int? happSubscriptionUpdateHours(ProfileEntity profile) {
  final raw = profile.populatedHeaders?['profile-update-interval'];
  final hours = int.tryParse('${raw ?? ''}'.trim());
  return hours != null && hours > 0 ? hours : null;
}

/// The interval the app updates [profile] by, as the parser works it out: none when auto-update is
/// off; else the user's own interval, else the subscription's.
Duration? happEffectiveUpdateInterval(UserOverride override, int? subscriptionHours) {
  if (override.isAutoUpdateDisable) return null;
  final own = override.updateInterval;
  if (own != null && own > 0) return Duration(hours: own);
  if (subscriptionHours != null) return Duration(hours: subscriptionHours);
  return null;
}

/// Opens the editor of [profile].
Future<void> happEditProfile(BuildContext context, ProfileEntity profile) async {
  final container = ProviderScope.containerOf(context, listen: false);
  // the profile as saved now, not as the menu that was opened saw it
  final current =
      container.read(profilesNotifierProvider).valueOrNull?.where((p) => p.id == profile.id).firstOrNull ?? profile;
  final result = await showModalBottomSheet<_EditorResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ProfileEditor(profile: current),
  );
  if (!context.mounted) return;
  switch (result) {
    case _EditorResult.configEditor:
      // from the profiles sheet: it closes first, as the menu's own «Изменить» did
      if (Breakpoint(context).isMobile() && context.canPop()) context.pop();
      context.goNamed('profileDetails', pathParameters: {'id': current.id});
    case _EditorResult.delete:
      final t = container.read(translationsProvider).requireValue;
      final ok = await container
          .read(dialogNotifierProvider.notifier)
          .showConfirmation(
            title: t.dialogs.confirmation.profile.delete.title,
            message: t.dialogs.confirmation.profile.delete.msg,
          );
      if (ok) await container.read(profilesNotifierProvider.notifier).deleteProfile(current);
    case _EditorResult.saved || null:
      break;
  }
}

enum _EditorResult { saved, delete, configEditor }

class _ProfileEditor extends HookConsumerWidget {
  const _ProfileEditor({required this.profile});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final remote = switch (profile) {
      final RemoteProfileEntity r => r,
      _ => null,
    };
    final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    final override = profile.userOverride ?? const UserOverride();
    final ownMessage = prefs?.getString(happAnnounceKey(profile.id));
    final subMessage = remote == null ? null : HappAnnounceCard.contentOf(remote)?.text;
    final initialMessage = ownMessage ?? subMessage ?? '';
    final subHours = happSubscriptionUpdateHours(profile);
    final ownHours = (override.updateInterval ?? 0) > 0 ? override.updateInterval : null;

    final name = useTextEditingController(text: profile.name);
    final url = useTextEditingController(text: remote?.url ?? '');
    final message = useTextEditingController(text: initialMessage);
    // «Как в подписке» shows while the field differs from the subscription's text
    useListenable(message);
    // «Как в подписке» pressed: the user's own message goes, the subscription's comes back
    final messageReset = useState(false);
    final autoUpdate = useState(!override.isAutoUpdateDisable);
    // hours; null: as the subscription says
    final hours = useState<int?>(ownHours);
    final saving = useState(false);
    // «Сортировка серверов» of this subscription
    final sort = useState(ref.read(happProfileSortProvider(profile.id)));
    final nameError = useState<String?>(null);
    final urlError = useState<String?>(null);
    final expert = ref.watch(HappifyPrefs.expertMode);

    final choices = <int?>[
      if (subHours != null) null,
      for (final h in const [1, 3, 6, 12, 24]) h,
      if (ownHours != null && !const [1, 3, 6, 12, 24].contains(ownHours)) ownHours,
    ];

    Future<void> save() async {
      final container = ProviderScope.containerOf(context, listen: false);
      final newName = name.text.trim();
      final newUrl = url.text.trim();
      nameError.value = newName.isEmpty ? hr(context, 'Введите название', 'Enter a name') : null;
      if (remote != null) {
        final uri = Uri.tryParse(newUrl);
        if (newUrl.isEmpty || uri == null || !uri.hasScheme || newUrl.contains(RegExp(r'\s'))) {
          urlError.value = hr(context, 'Неверная ссылка', 'Invalid link');
        } else if (newUrl != remote.url &&
            (ref.read(profilesNotifierProvider).valueOrNull ?? const <ProfileEntity>[]).any(
              (p) => p.id != profile.id && p is RemoteProfileEntity && p.url == newUrl,
            )) {
          urlError.value = hr(context, 'Такая подписка уже есть', 'This subscription is already added');
        } else {
          urlError.value = null;
        }
      }
      if (nameError.value != null || urlError.value != null) return;

      saving.value = true;
      try {
        final nextOverride = override.copyWith(
          name: newName == profile.name ? override.name : newName,
          isAutoUpdateDisable: remote == null ? override.isAutoUpdateDisable : !autoUpdate.value,
          updateInterval: remote == null ? override.updateInterval : hours.value,
        );
        final urlChanged = remote != null && newUrl != remote.url;
        final repo = await ref.read(profileRepositoryProvider.future);
        final saved = await repo
            .editDetails(
              profile.id,
              name: newName,
              url: urlChanged ? newUrl : null,
              userOverride: nextOverride,
              updateInterval: remote == null ? null : happEffectiveUpdateInterval(nextOverride, subHours),
            )
            .run();
        if (saved.isLeft()) {
          if (!context.mounted) return;
          ref
              .read(inAppNotificationControllerProvider)
              .showErrorToast(hr(context, 'Не удалось сохранить', 'Could not save'));
          return;
        }

        if (sort.value != ref.read(happProfileSortProvider(profile.id))) {
          await happSetProfileSort(container, profile.id, sort.value);
        }

        // the message under the card
        if (prefs != null) {
          final key = happAnnounceKey(profile.id);
          final text = message.text.trim();
          if (messageReset.value) {
            await prefs.remove(key);
          } else if (text != initialMessage.trim()) {
            // an empty text hides the row
            await prefs.setString(key, text);
          }
          ref.read(happAnnounceRevision.notifier).state++;
        }

        // a new link: its servers are fetched at once
        if (urlChanged) {
          final updated = remote.copyWith(url: newUrl, name: newName, userOverride: nextOverride);
          unawaited(
            ref.read(updateProfileNotifierProvider(profile.id).notifier).updateProfile(updated, restart: true),
          );
        }
        if (context.mounted) Navigator.of(context).pop(_EditorResult.saved);
      } finally {
        if (context.mounted) saving.value = false;
      }
    }

    String hoursLabel(int? h) => h == null
        ? hr(context, 'Как в подписке ($subHours ч)', 'As the subscription says (${subHours}h)')
        : hr(context, '$h ч', '${h}h');

    final section = theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              remote != null ? hr(context, 'Изменить подписку', 'Edit subscription') : hr(context, 'Изменить профиль', 'Edit profile'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              textInputAction: TextInputAction.next,
              maxLines: 1,
              onChanged: (_) => nameError.value = null,
              decoration: InputDecoration(
                labelText: hr(context, 'Название', 'Name'),
                errorText: nameError.value,
                border: const OutlineInputBorder(),
              ),
            ),
            if (remote != null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                maxLines: 1,
                onChanged: (_) => urlError.value = null,
                decoration: InputDecoration(
                  labelText: hr(context, 'Ссылка на подписку', 'Subscription link'),
                  errorText: urlError.value,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: message,
              minLines: 1,
              maxLines: 5,
              maxLength: 300,
              onChanged: (_) => messageReset.value = false,
              decoration: InputDecoration(
                labelText: hr(context, 'Сообщение', 'Message'),
                helperText: hr(
                  context,
                  'Текст под подпиской на главном экране. Пусто — не показывать',
                  'The text under the subscription on the home screen. Empty: not shown',
                ),
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
            if (subMessage != null && (ownMessage != null || message.text.trim() != subMessage.trim()))
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () {
                    message.text = subMessage;
                    messageReset.value = true;
                  },
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: Text(hr(context, 'Как в подписке', 'As the subscription says')),
                ),
              ),
            const SizedBox(height: 8),
            Text(hr(context, 'Сортировка серверов', 'Server sorting'), style: section),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final rule in happProfileSortRules)
                  ChoiceChip(
                    label: Text(happSortShortLabel(context, rule)),
                    selected: sort.value == rule,
                    onSelected: (_) => sort.value = rule,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                happSortHint(context, sort.value),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            if (remote != null) ...[
              const SizedBox(height: 8),
              Text(hr(context, 'Обновление', 'Updates'), style: section),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(hr(context, 'Автообновление', 'Auto update')),
                subtitle: Text(
                  hr(context, 'Обновлять подписку само, пока приложение работает', 'Update the subscription by itself while the app runs'),
                ),
                value: autoUpdate.value,
                onChanged: (v) => autoUpdate.value = v,
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: autoUpdate.value
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(hr(context, 'Интервал', 'Interval'), style: theme.textTheme.bodyMedium),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final h in choices)
                                ChoiceChip(
                                  label: Text(hoursLabel(h)),
                                  selected: hours.value == h,
                                  onSelected: (_) => hours.value = h,
                                ),
                            ],
                          ),
                          if (hours.value == null && subHours == null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                hr(
                                  context,
                                  'Подписка не задаёт интервал: выберите его, иначе автообновления не будет',
                                  'The subscription sets no interval: pick one, or there are no auto updates',
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
            if (expert) ...[
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.data_object_rounded),
                title: Text(hr(context, 'Редактор конфигурации', 'Config editor')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: saving.value ? null : () => Navigator.of(context).pop(_EditorResult.configEditor),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: saving.value ? null : save,
              child: saving.value
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(hr(context, 'Сохранить', 'Save')),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: saving.value ? null : () => Navigator.of(context).pop(_EditorResult.delete),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(
                remote != null ? hr(context, 'Удалить подписку', 'Delete subscription') : hr(context, 'Удалить профиль', 'Delete profile'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
