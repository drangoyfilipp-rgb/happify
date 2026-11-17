import 'package:flutter/material.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/optional_range.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class TlsTricksPage extends HookConsumerWidget {
  const TlsTricksPage({super.key});

  String _presentFragmentPackets(TranslationsEn t, String value) => switch (value) {
    "tlshello" => t.pages.settings.tlsTricks.packetsTlsHello,
    "1-1" => t.pages.settings.tlsTricks.packets1_1,
    "1-2" => t.pages.settings.tlsTricks.packets1_2,
    "1-3" => t.pages.settings.tlsTricks.packets1_3,
    "1-4" => t.pages.settings.tlsTricks.packets1_4,
    "1-5" => t.pages.settings.tlsTricks.packets1_5,
    _ => value,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final canChangeOption = ref.watch(ConfigOptions.enableTlsFragment);
    return Scaffold(
      appBar: AppBar(title: Text(t.pages.settings.tlsTricks.title)),
      body: ListView(
        children: [
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.tlsTricks.enable),
            subtitle: Text(hr(context, 'Режет начало защищённого соединения на кусочки, чтобы фильтр провайдера (DPI) не узнал, к какому серверу ты подключаешься. Включай, только если серверы перестали подключаться. Подключение станет чуть медленнее.', 'Splits the start of the secure connection into pieces so the provider\'s filter (DPI) can\'t tell which server you reach. Turn it on only if servers stop connecting. Connecting gets a bit slower.')),
            value: ref.watch(ConfigOptions.enableTlsFragment),
            secondary: const Icon(Icons.content_cut_rounded),
            onChanged: ref.read(ConfigOptions.enableTlsFragment.notifier).update,
          ),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.fragmentPackets),
            preferences: ref.watch(ConfigOptions.fragmentPackets.notifier),
            choices: const ["tlshello", "1-1", "1-2", "1-3", "1-4", "1-5"],
            title: t.pages.settings.tlsTricks.packets,
            icon: Icons.layers_rounded,
            presentChoice: (value) => _presentFragmentPackets(t, value),
            enabled: canChangeOption,
          ),
          const HappifyHint('Что резать. tlshello — только первое сообщение TLS, обычно этого хватает.', 'What to split. tlshello is only the first TLS message, usually enough.'),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.tlsFragmentSize),
            preferences: ref.watch(ConfigOptions.tlsFragmentSize.notifier),
            title: t.pages.settings.tlsTricks.size,
            icon: Icons.straighten_rounded,
            inputToValue: OptionalRange.tryParse,
            presentValue: (value) => value.present(t),
            formatInputValue: (value) => value.format(),
            enabled: canChangeOption,
          ),
          const HappifyHint('Размер кусочков в байтах. Меньше — надёжнее обходит фильтр, но медленнее.', 'Piece size in bytes. Smaller gets past the filter more reliably but is slower.'),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.tlsFragmentSleep),
            preferences: ref.watch(ConfigOptions.tlsFragmentSleep.notifier),
            title: t.pages.settings.tlsTricks.sleep,
            icon: Icons.snooze_rounded,
            inputToValue: OptionalRange.tryParse,
            presentValue: (value) => value.present(t),
            formatInputValue: (value) => value.format(),
            enabled: canChangeOption,
          ),
          const HappifyHint('Пауза между кусочками в миллисекундах. Помогает против умных фильтров, но добавляет задержку.', 'Pause between pieces in milliseconds. Helps against smart filters but adds delay.'),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.tlsTricks.mixedSniCase.enable),
            subtitle: Text(hr(context, 'Пишет имя сервера вперемешку большими и маленькими буквами (ExAmPlE.com). Сбивает простые фильтры.', 'Writes the server name in mixed case (ExAmPlE.com). Throws off simple filters.')),
            value: ref.watch(ConfigOptions.enableTlsMixedSniCase),
            secondary: const Icon(Icons.text_fields_rounded),
            onChanged: canChangeOption ? ref.read(ConfigOptions.enableTlsMixedSniCase.notifier).update : null,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.tlsTricks.padding.enable),
            subtitle: Text(hr(context, 'Добавляет случайные байты к началу соединения, чтобы его труднее было распознать.', 'Adds random bytes to the start of the connection so it\'s harder to recognize.')),
            value: ref.watch(ConfigOptions.enableTlsPadding),
            secondary: const Icon(Icons.expand_rounded),
            onChanged: canChangeOption ? ref.read(ConfigOptions.enableTlsPadding.notifier).update : null,
          ),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.tlsPaddingSize),
            preferences: ref.watch(ConfigOptions.tlsPaddingSize.notifier),
            title: t.pages.settings.tlsTricks.padding.size,
            icon: Icons.straighten_rounded,
            inputToValue: OptionalRange.tryParse,
            presentValue: (value) => value.format(),
            formatInputValue: (value) => value.format(),
            enabled: canChangeOption,
          ),
        ],
      ),
    );
  }
}
