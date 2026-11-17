import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/happ/happ_home.dart';
import 'package:hiddify/features/happ/happify_ui_layout.dart';
import 'package:hiddify/features/home/widget/local_proxy_hint.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // «Как в Happ»: no bottom menu, so a gear top left (mirroring the «+») opens Settings
    final gearMode = ref.watch(happGearModeProvider);

    return Scaffold(
      backgroundColor: HappColors.of(context).background,
      appBar: AppBar(
        // Happ: no title, the bare background up to the top
        backgroundColor: HappColors.of(context).background,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        automaticallyImplyLeading: false,
        leadingWidth: gearMode ? 56 : null,
        leading: gearMode
            ? Padding(
                padding: const EdgeInsetsDirectional.only(start: 8),
                child: IconButton(
                  tooltip: t.pages.settings.title,
                  icon: Icon(Icons.settings_rounded, color: theme.colorScheme.primary),
                  onPressed: () => context.go('/settings'),
                ),
              )
            : null,
        actions: [
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Happ's light grey with its soft diagonal shapes, drawn once into its own layer
          const HappBackground(),
          // without the bottom menu the content keeps clear of the system's gesture bar itself
          Padding(
            padding: EdgeInsets.only(bottom: gearMode ? MediaQuery.paddingOf(context).bottom : 0),
            child: Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  // Happ's home: the round button, then a card per subscription with its servers
                  child: const HappHomeContent(),
                ),
              ),
              if (ref.watch(hasAnyProfileProvider).value ?? false)
                Positioned(
                  right: 0,
                  left: 0,
                  bottom: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    // tabs of either height stand on the bottom edge
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // in proxy mode, a smaller tab beside this one on how to point apps at the proxy
                      const Flexible(child: LocalProxyHint()),
                      Material(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                        ),
                        child: InkWell(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                          ),
                          onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
                          child: Container(
                            height: 32,
                            padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(t.pages.home.quickSettings),
                                const Gap(4),
                                const Icon(Icons.arrow_drop_up_rounded, size: 16),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          ),
        ],
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
