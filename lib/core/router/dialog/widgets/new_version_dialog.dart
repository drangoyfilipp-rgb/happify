import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_updater.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A new release: "update now" downloads it and starts its installer where this install can
/// (AppUpdater), and opens the release page where it can not, or when the update failed.
class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key, this.canIgnore = true});

  final String currentVersion;
  final RemoteVersionEntity newVersion;
  final bool canIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final updater = ref.watch(appUpdaterProvider);
    final busy = updater is AppUpdaterDownloading || updater is AppUpdaterInstalling;
    // a failure left by an earlier dialog does not show in this one
    useEffect(() {
      Future.microtask(() {
        final s = ref.read(appUpdaterProvider);
        if (s is AppUpdaterFailed || s is AppUpdaterNeedsPermission) ref.read(appUpdaterProvider.notifier).reset();
      });
      return null;
    }, const []);

    Future<void> openPage() => UriUtils.tryLaunch(Uri.parse(newVersion.url));
    // a failed download opens the release page, where the APK can be taken by hand
    Future<void> update() async {
      final updating = await ref.read(appUpdaterProvider.notifier).update(newVersion);
      if (!updating || ref.read(appUpdaterProvider) is AppUpdaterFailed) await openPage();
    }

    // «Позже» puts this build off: the automatic check does not offer it again
    Future<void> later() async {
      if (canIgnore) await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
      if (context.mounted) context.pop();
    }

    final small = theme.textTheme.bodySmall;
    return PopScope(
      // the download goes on only while the dialog shows it
      canPop: !busy,
      child: AlertDialog(
        title: Text(hr(context, 'Доступна сборка ${newVersion.version}', 'Build ${newVersion.version} available')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hr(context, 'Сейчас: сборка $currentVersion', 'Installed: build $currentVersion'), style: small),
            ...switch (updater) {
              AppUpdaterDownloading(:final progress) => [
                const Gap(16),
                LinearProgressIndicator(value: progress),
                const Gap(6),
                Text(
                  hr(context, 'Загрузка', 'Downloading') + (progress == null ? '…' : ' ${(progress * 100).round()}%'),
                  style: small,
                ),
              ],
              AppUpdaterInstalling() => [
                const Gap(16),
                Text(hr(context, 'Открываю установщик…', 'Opening the installer…'), style: small),
              ],
              AppUpdaterNeedsPermission() => [
                const Gap(16),
                Text(
                  hr(
                    context,
                    'Разрешите Happify устанавливать приложения в открывшихся настройках и нажмите «Повторить».',
                    'Allow Happify to install apps in the settings that opened, then tap Try again.',
                  ),
                  style: small,
                ),
              ],
              AppUpdaterFailed(:final error) => [
                const Gap(16),
                Text(
                  '${hr(context, 'Не удалось скачать', 'Download failed')}\n${t.presentShortError(error)}',
                  style: small?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              AppUpdaterIdle() => const <Widget>[],
            },
          ],
        ),
        actions: switch (updater) {
          AppUpdaterDownloading() => [
            TextButton(onPressed: ref.read(appUpdaterProvider.notifier).cancel, child: Text(t.common.cancel)),
          ],
          AppUpdaterInstalling() => const <Widget>[],
          AppUpdaterFailed() => [
            TextButton(onPressed: openPage, child: Text(hr(context, 'Страница релиза', 'Release page'))),
            TextButton(onPressed: update, child: Text(hr(context, 'Повторить', 'Try again'))),
          ],
          AppUpdaterNeedsPermission() => [
            TextButton(onPressed: later, child: Text(hr(context, 'Позже', 'Later'))),
            TextButton(onPressed: update, child: Text(hr(context, 'Повторить', 'Try again'))),
          ],
          AppUpdaterIdle() => [
            TextButton(onPressed: later, child: Text(hr(context, 'Позже', 'Later'))),
            FilledButton(onPressed: update, child: Text(hr(context, 'Скачать', 'Download'))),
          ],
        },
      ),
    );
  }
}
