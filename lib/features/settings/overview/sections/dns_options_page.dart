import 'package:flutter/material.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class DnsOptionsPage extends HookConsumerWidget {
  const DnsOptionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return Scaffold(
      appBar: AppBar(title: Text(t.pages.settings.dns.title)),
      body: ListView(
        children: [
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.remoteDnsAddress),
            icon: Icons.vpn_lock_rounded,
            preferences: ref.watch(ConfigOptions.remoteDnsAddress.notifier),
            title: t.pages.settings.dns.remoteDns,
          ),
          const HappifyHint('DNS для сайтов, которые идут через VPN. Запрос уходит через сервер, поэтому провайдер не видит, какие сайты ты открываешь.', 'DNS for the sites that go through the VPN. The query goes through the server, so the provider can\'t see which sites you open.'),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.remoteDnsDomainStrategy),
            preferences: ref.watch(ConfigOptions.remoteDnsDomainStrategy.notifier),
            choices: DomainStrategy.values,
            title: t.pages.settings.dns.remoteDnsDomainStrategy,
            icon: Icons.sync_alt_rounded,
            presentChoice: (value) => value.present(t),
          ),
          const HappifyHint('Какие адреса спрашивать у DNS: только IPv4, только IPv6 или оба. «Авто» подходит почти всегда.', 'Which addresses to ask DNS for: IPv4, IPv6 or both. Auto fits almost always.'),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.dns.enableFakeDns),
            subtitle: Text(hr(context, 'Приложение сразу получает временный адрес, а настоящий узнаёт сервер. Сайты открываются чуть быстрее, но редкие приложения могут работать хуже. Если не уверен, не включай.', 'Apps get a stand-in address at once and the server finds the real one. Sites open a bit faster, but a few apps may misbehave. Leave it off if unsure.')),
            secondary: const Icon(Icons.private_connectivity_rounded),
            value: ref.watch(ConfigOptions.enableFakeDns),
            onChanged: ref.read(ConfigOptions.enableFakeDns.notifier).update,
          ),
          ValuePreferenceWidget(
            title: t.pages.settings.dns.directDns,
            icon: Icons.public_rounded,
            value: ref.watch(ConfigOptions.directDnsAddress),
            preferences: ref.watch(ConfigOptions.directDnsAddress.notifier),
          ),
          const HappifyHint('DNS для сайтов, которые идут напрямую, без VPN (например, российские). По умолчанию Яндекс 77.88.8.8: так сайты отдают ближайшие к тебе адреса.', 'DNS for the sites that go direct, without the VPN. Yandex 77.88.8.8 by default, so sites give addresses close to you.'),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.directDnsDomainStrategy),
            preferences: ref.watch(ConfigOptions.directDnsDomainStrategy.notifier),
            choices: DomainStrategy.values,
            title: t.pages.settings.dns.directDnsDomainStrategy,
            icon: Icons.sync_alt_rounded,
            presentChoice: (value) => value.present(t),
          ),
          const HappifyHint('То же, что выше, но для прямых сайтов. Лучше оставить «Авто».', 'The same as above, for the direct sites. Best left on Auto.'),
          // SwitchListTile.adaptive(
          //   title: Text(t.pages.settings.dns.enableDnsRouting),
          //   secondary: const Icon(Icons.private_connectivity_rounded),
          //   value: ref.watch(ConfigOptions.enableDnsRouting),
          //   onChanged: ref.read(ConfigOptions.enableDnsRouting.notifier).update,
          // ),
        ],
      ),
    );
  }
}
