import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_profile_editor.dart';
import 'package:hiddify/features/happ/happify_server_sort.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

HappSortItem s(String tag, int index, {int? ping, String? country, String? name}) =>
    (tag: tag, name: name ?? tag, index: index, ping: ping, country: country);

void main() {
  final items = [
    s('Стокгольм #10', 0, ping: 120, country: 'SE'),
    s('Amsterdam', 1, ping: -1, country: 'NL'),
    s('Берлин', 2, country: 'DE'),
    s('Стокгольм #2', 3, ping: 80, country: 'SE'),
    s('Ёлки', 4, ping: 40),
  ];

  test('no sorting keeps the subscription order', () {
    expect(happSortServers(items, ProxiesSort.unsorted, const {}), [
      'Стокгольм #10',
      'Amsterdam',
      'Берлин',
      'Стокгольм #2',
      'Ёлки',
    ]);
  });

  test('by ping: fastest first, no answer and untested last in their order', () {
    expect(happSortServers(items, ProxiesSort.delay, const {}), [
      'Ёлки',
      'Стокгольм #2',
      'Стокгольм #10',
      'Amsterdam',
      'Берлин',
    ]);
  });

  test('alphabetically: Latin, then Cyrillic with ё as е, numbers by value', () {
    expect(happSortServers(items, ProxiesSort.name, const {}), [
      'Amsterdam',
      'Берлин',
      'Ёлки',
      'Стокгольм #2',
      'Стокгольм #10',
    ]);
    expect(happCompareNames('🇩🇪 Berlin', 'amsterdam'), greaterThan(0));
    expect(happCompareNames('📌 b', 'A'), greaterThan(0));
  });

  test('by country: by code, then by name; no country last', () {
    expect(happSortServers(items, ProxiesSort.country, const {}), [
      'Берлин',
      'Amsterdam',
      'Стокгольм #2',
      'Стокгольм #10',
      'Ёлки',
    ]);
  });

  test('pinned servers stay on top, sorted among themselves', () {
    expect(happSortServers(items, ProxiesSort.delay, const {'Берлин', 'Стокгольм #10'}), [
      'Стокгольм #10',
      'Берлин',
      'Ёлки',
      'Стокгольм #2',
      'Amsterdam',
    ]);
  });

  test('the rules of the servers page alone keep the subscription order on home', () {
    expect(happSortServers(items, ProxiesSort.usage, const {}), [for (final i in items) i.tag]);
  });

  test('the country of a flag in a name', () {
    expect(happCountryFromName('🇩🇪 Berlin'), 'DE');
    expect(happCountryFromName('Berlin'), isNull);
  });

  test('auto update: off, own interval, the subscription one, or none', () {
    expect(happEffectiveUpdateInterval(const UserOverride(isAutoUpdateDisable: true, updateInterval: 3), 6), isNull);
    expect(happEffectiveUpdateInterval(const UserOverride(updateInterval: 3), 6), const Duration(hours: 3));
    expect(happEffectiveUpdateInterval(const UserOverride(updateInterval: 0), 6), const Duration(hours: 6));
    expect(happEffectiveUpdateInterval(const UserOverride(), null), isNull);
  });

  test('saved results of the removed check are dropped, the rest stays', () async {
    SharedPreferences.setMockInitialValues({
      'happify_gemini_p1': '{}',
      'happify_ping_p1': '{}',
      'happify_announce_p1': 'hi',
    });
    final prefs = await SharedPreferences.getInstance();
    await happRemoveObsoletePrefs(prefs);
    expect(prefs.getKeys(), {'happify_ping_p1', 'happify_announce_p1'});
  });
}
