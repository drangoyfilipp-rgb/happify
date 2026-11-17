import 'package:flutter/material.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/profile/add/phone_import/phone_import_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// «Вид интерфейса»: whether this device can take the Happ layout at all. Desktop and Android TV
/// keep their side rail / bottom menu, whose focus navigation the gear would break.
final happUiLayoutSupportedProvider = Provider<bool>((ref) {
  if (PlatformUtils.isDesktop) return false;
  return !(ref.watch(isAndroidTvProvider).valueOrNull ?? false);
});

/// The Happ layout is in use: no bottom menu, a gear top left on the home screen. Only on the
/// phone layout (the bottom menu's breakpoint); wider screens keep their side rail.
final happGearModeProvider = Provider<bool>((ref) {
  if (ref.watch(HappifyPrefs.uiLayout) != 'happ') return false;
  if (!ref.watch(happUiLayoutSupportedProvider)) return false;
  return ref.watch(isMobileBreakpointProvider) ?? false;
});

/// Настройки → Общие → «Вид интерфейса»: «Нижнее меню» or «Как в Happ». Applies at once.
class HappUiLayoutTile extends ConsumerWidget {
  const HappUiLayoutTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(happUiLayoutSupportedProvider)) return const SizedBox.shrink();
    final current = ref.watch(HappifyPrefs.uiLayout) == 'happ' ? 'happ' : 'bottom';
    String name(String v) => v == 'happ' ? hr(context, 'Как в Happ', 'Like Happ') : hr(context, 'Нижнее меню', 'Bottom menu');
    return ListTile(
      leading: const Icon(Icons.dashboard_customize_rounded),
      title: Text(hr(context, 'Вид интерфейса', 'Interface layout')),
      subtitle: Text(name(current)),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(hr(context, 'Вид интерфейса', 'Interface layout')),
            children: [
              for (final v in const ['bottom', 'happ'])
                ListTile(
                  leading: Icon(v == current ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
                  title: Text(name(v)),
                  subtitle: Text(
                    v == 'happ'
                        ? hr(context, 'Без нижнего меню, настройки — шестерёнка слева вверху', 'No bottom menu; settings behind the gear at the top left')
                        : hr(context, 'Главная и Настройки внизу экрана', 'Home and Settings at the bottom'),
                  ),
                  onTap: () => Navigator.of(context).pop(v),
                ),
            ],
          ),
        );
        if (picked != null) await ref.read(HappifyPrefs.uiLayout.notifier).update(picked);
      },
    );
  }
}
