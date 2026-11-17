import 'package:flutter/material.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';

// «Сортировка серверов»: each subscription keeps its own rule, chosen in its «Изменить» sheet
// (reliability/happ_profile_sort.dart). The servers page keeps its own sort ("proxies_sort_mode").

/// What the settings call [sort].
String happSortLabel(BuildContext context, ProxiesSort sort) => switch (sort) {
  ProxiesSort.unsorted => hr(context, 'Без сортировки', 'No sorting'),
  ProxiesSort.delay => hr(context, 'Сортировать по пингу', 'Sort by ping'),
  ProxiesSort.name => hr(context, 'Сортировать по алфавиту', 'Sort alphabetically'),
  ProxiesSort.country => hr(context, 'Сортировать по стране', 'Sort by country'),
  ProxiesSort.usage => hr(context, 'По трафику (страница серверов)', 'By traffic (servers page)'),
  ProxiesSort.upload => hr(context, 'По отдаче (страница серверов)', 'By upload (servers page)'),
  ProxiesSort.download => hr(context, 'По загрузке (страница серверов)', 'By download (servers page)'),
};

/// The short name of a rule, for a chip: «Без сортировки», «По пингу», «По алфавиту», «По стране».
String happSortShortLabel(BuildContext context, ProxiesSort sort) => switch (sort) {
  ProxiesSort.unsorted => hr(context, 'Без сортировки', 'No sorting'),
  ProxiesSort.delay => hr(context, 'По пингу', 'By ping'),
  ProxiesSort.name => hr(context, 'По алфавиту', 'A–Z'),
  ProxiesSort.country => hr(context, 'По стране', 'By country'),
  _ => happSortLabel(context, sort),
};

String happSortHint(BuildContext context, ProxiesSort sort) => switch (sort) {
  ProxiesSort.unsorted => hr(context, 'Как в подписке', 'As in the subscription'),
  ProxiesSort.delay => hr(
    context,
    'Самые быстрые сверху; без ответа и непроверенные в конце',
    'Fastest first; unanswered and untested last',
  ),
  ProxiesSort.name => hr(context, 'От A до Z и от А до Я', 'A to Z'),
  ProxiesSort.country => hr(context, 'По флагу в названии сервера', 'By the flag in the server name'),
  _ => '',
};

/// A server as the sort sees it: [name] as its row shows it, [index] its place in the
/// subscription, [ping] in ms (null untested, below 0 no answer), [country] a code such as "DE".
typedef HappSortItem = ({String tag, String name, int index, int? ping, String? country});

/// The tags of [items] in the order the rows take: pinned ones first, each part ordered by [sort];
/// whatever ties keeps the subscription's order. The rules the home card does not know (the
/// servers page's traffic and speed sorts) keep the subscription's order there.
List<String> happSortServers(List<HappSortItem> items, ProxiesSort sort, Set<String> pinned) {
  int bySort(HappSortItem a, HappSortItem b) {
    final r = switch (sort) {
      ProxiesSort.delay => _comparePing(a.ping, b.ping),
      ProxiesSort.name => happCompareNames(a.name, b.name),
      ProxiesSort.country => _compareCountry(a, b),
      _ => 0,
    };
    return r != 0 ? r : a.index.compareTo(b.index);
  }

  final sorted = [...items]
    ..sort((a, b) {
      final pa = pinned.contains(a.tag);
      final pb = pinned.contains(b.tag);
      if (pa != pb) return pa ? -1 : 1;
      return bySort(a, b);
    });
  return [for (final s in sorted) s.tag];
}

int _comparePing(int? a, int? b) {
  final okA = a != null && a >= 0;
  final okB = b != null && b >= 0;
  if (okA && okB) return a.compareTo(b);
  if (okA) return -1;
  if (okB) return 1;
  return 0;
}

/// By country code; servers without one after every country, by name.
int _compareCountry(HappSortItem a, HappSortItem b) {
  final ca = (a.country ?? '').toUpperCase();
  final cb = (b.country ?? '').toUpperCase();
  if (ca.isEmpty != cb.isEmpty) return ca.isEmpty ? 1 : -1;
  final c = ca.compareTo(cb);
  return c != 0 ? c : happCompareNames(a.name, b.name);
}

final _flagPair = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

/// The country of the first flag in [name], such as "DE"; null when it has none.
String? happCountryFromName(String name) {
  final m = _flagPair.firstMatch(name);
  if (m == null) return null;
  return String.fromCharCodes(m[0]!.runes.map((r) => r - 0x1F1E6 + 0x41));
}

/// Alphabetical order for server names: letters and digits only (emoji, flags and signs in front
/// are skipped), case ignored, Latin before Cyrillic, «ё» with «е», and numbers by their value
/// («#2» before «#10»).
int happCompareNames(String a, String b) {
  final ka = _nameKey(a);
  final kb = _nameKey(b);
  var i = 0;
  var j = 0;
  while (i < ka.length && j < kb.length) {
    final ca = ka.codeUnitAt(i);
    final cb = kb.codeUnitAt(j);
    if (_isDigit(ca) && _isDigit(cb)) {
      final si = i;
      final sj = j;
      while (i < ka.length && _isDigit(ka.codeUnitAt(i))) {
        i++;
      }
      while (j < kb.length && _isDigit(kb.codeUnitAt(j))) {
        j++;
      }
      final na = BigInt.parse(ka.substring(si, i));
      final nb = BigInt.parse(kb.substring(sj, j));
      final c = na.compareTo(nb);
      if (c != 0) return c;
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    i++;
    j++;
  }
  final c = (ka.length - i).compareTo(kb.length - j);
  if (c != 0) return c;
  // the same letters: the exact names decide, so the order is always the same
  return a.compareTo(b);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

final _lead = RegExp(r'^[^\p{L}\p{N}]+', unicode: true);

String _nameKey(String name) => name.replaceAll(_flagPair, '').replaceFirst(_lead, '').toLowerCase().replaceAll('ё', 'е');
