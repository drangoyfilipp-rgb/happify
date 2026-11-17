import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happify_server_sort.dart';
import 'package:hiddify/features/happ/reliability/happ_core_log.dart';
import 'package:hiddify/features/happ/reliability/happ_notify_rules.dart';
import 'package:hiddify/features/happ/reliability/happ_profile_sort.dart';
import 'package:hiddify/features/happ/reliability/happ_speed_plan.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';

HappSortItem s(String tag, int index, {int? ping}) => (tag: tag, name: tag, index: index, ping: ping, country: null);

void main() {
  group('sort per subscription', () {
    test('by ping: the untested and unanswered go last, in the subscription order', () {
      final items = [s('a', 0), s('b', 1, ping: 300), s('c', 2, ping: -1), s('d', 3, ping: 50), s('e', 4)];
      expect(happSortServers(items, ProxiesSort.delay, const {}), ['d', 'b', 'a', 'c', 'e']);
      // pinned still first
      expect(happSortServers(items, ProxiesSort.delay, const {'e'}), ['e', 'd', 'b', 'a', 'c']);
    });

    test('rules a subscription can take; anything else reads as no sorting', () {
      expect(happParseProfileSort(null), ProxiesSort.unsorted);
      expect(happParseProfileSort('delay'), ProxiesSort.delay);
      expect(happParseProfileSort('name'), ProxiesSort.name);
      expect(happParseProfileSort('country'), ProxiesSort.country);
      expect(happParseProfileSort('usage'), ProxiesSort.unsorted, reason: 'a servers-page-only rule');
      expect(happParseProfileSort('garbage'), ProxiesSort.unsorted);
    });

    test('migration: the old shared rule the user had set goes to every subscription without one', () {
      final writes = happSortMigration(
        migrated: false,
        legacy: 'delay',
        profileIds: ['p1', 'p2', 'p3'],
        existingKeys: {happSortKey('p2')},
      );
      expect(writes, {happSortKey('p1'): 'delay', happSortKey('p3'): 'delay'});
    });

    test('migration: nothing when never set, when it was «без сортировки», or once done', () {
      expect(happSortMigration(migrated: false, legacy: null, profileIds: ['p1'], existingKeys: {}), isEmpty);
      expect(happSortMigration(migrated: false, legacy: 'unsorted', profileIds: ['p1'], existingKeys: {}), isEmpty);
      expect(happSortMigration(migrated: true, legacy: 'name', profileIds: ['p1'], existingKeys: {}), isEmpty);
      expect(happSortMigration(migrated: false, legacy: 'upload', profileIds: ['p1'], existingKeys: {}), isEmpty);
    });

    test('a deleted subscription leaves no keys; global keys with the same start stay', () {
      const p1 = '0b9f6a2e-3c41-4d7a-9e55-1f2a3b4c5d6e';
      const gone = 'A1B2C3D4-E5F6-4789-8ABC-DEF012345678';
      expect(happProfileKeys(p1), contains(happSortKey(p1)));
      final orphans = happOrphanProfileKeys([
        happSortKey(p1),
        happSortKey(gone),
        'happify_speed_$gone',
        'happify_last_server_$gone',
        'happify_ping_on_open',
        happSortMigratedKey,
        'happify_ping_$p1',
        'proxies_sort_mode',
        // not a subscription id: kept whatever it is
        'happify_ping_interval',
        'happify_sort_gone',
        'happify_speed_1234',
      ], {p1});
      expect(orphans, unorderedEquals([happSortKey(gone), 'happify_speed_$gone', 'happify_last_server_$gone']));
    });

    test('profile ids: only UUIDs count', () {
      expect(happIsProfileIdLike('0b9f6a2e-3c41-4d7a-9e55-1f2a3b4c5d6e'), isTrue);
      expect(happIsProfileIdLike('on_open'), isFalse);
      expect(happIsProfileIdLike('0b9f6a2e3c414d7a9e551f2a3b4c5d6e'), isFalse);
      expect(happIsProfileIdLike(''), isFalse);
    });
  });

  group('notifications', () {
    test('defaults: only what needs the user is on', () {
      final on = {for (final t in HappNotifyType.values) t: happNotifyOn(t, null)};
      expect(on, {
        HappNotifyType.subExpiring: true,
        HappNotifyType.trafficLow: true,
        HappNotifyType.vpnProblem: true,
        HappNotifyType.serverSwitched: false,
        HappNotifyType.throttled: false,
        HappNotifyType.subUpdated: false,
        HappNotifyType.testResults: false,
      });
      expect(happNotifyOn(HappNotifyType.serverSwitched, true), isTrue);
      expect(happNotifyOn(HappNotifyType.vpnProblem, false), isFalse);
    });

    test('expiry: 3 days, then 1 day, each once; nothing when over or far', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(happExpiryWarning(expire: now.add(const Duration(days: 5)), now: now, sent: {}), isNull);
      expect(happExpiryWarning(expire: now.add(const Duration(days: 2, hours: 23)), now: now, sent: {}), 3);
      expect(happExpiryWarning(expire: now.add(const Duration(days: 2)), now: now, sent: {3}), isNull);
      expect(happExpiryWarning(expire: now.add(const Duration(hours: 20)), now: now, sent: {3}), 1);
      expect(happExpiryWarning(expire: now.add(const Duration(hours: 20)), now: now, sent: {}), 1, reason: 'the day one wins');
      expect(happExpiryWarning(expire: now.add(const Duration(hours: 2)), now: now, sent: {1, 3}), isNull);
      expect(happExpiryWarning(expire: now.subtract(const Duration(hours: 1)), now: now, sent: {}), isNull);
      expect(happExpiryWarning(expire: DateTime(2999), now: now, sent: {}), isNull);
    });

    test('expiry record: a renewal (new end date) starts over', () {
      final end = DateTime(2026, 11, 18);
      final raw = happWriteExpirySent(end, {3});
      expect(happReadExpirySent(raw, end), {3});
      expect(happReadExpirySent(raw, DateTime(2026, 12, 18)), isEmpty);
      expect(happReadExpirySent(null, end), isEmpty);
      expect(happReadExpirySent('junk', end), isEmpty);
    });

    test('ids: each kind keeps to its own block of a thousand, whatever the subscription', () {
      final ids = <HappNotifyType, Set<int>>{};
      for (final t in HappNotifyType.values) {
        final base = happNotifyBaseId + t.index * 1000;
        final mine = {
          t.idFor(),
          for (var i = 0; i < 300; i++) t.idFor('profile-$i-${i * 7919}'),
          t.idFor('0b9f6a2e-3c41-4d7a-9e55-1f2a3b4c5d6e'),
        };
        for (final id in mine) {
          expect(id, inInclusiveRange(base, base + 999), reason: '$t');
        }
        ids[t] = mine;
      }
      for (final a in HappNotifyType.values) {
        for (final b in HappNotifyType.values) {
          if (a != b) expect(ids[a]!.intersection(ids[b]!), isEmpty, reason: '$a / $b');
        }
      }
      // stable: the same subscription, the same id
      expect(HappNotifyType.subExpiring.idFor('x'), HappNotifyType.subExpiring.idFor('x'));
      expect(happStableHash('abc'), happStableHash('abc'));
      expect(happStableHash('abc'), isNonNegative);
    });

    test('«нет интернета»: at most once in 30 minutes', () {
      final t = DateTime(2026, 11, 16, 10);
      expect(happNoInternetNotifyDue(null, t), isTrue);
      expect(happNoInternetNotifyDue(t, t.add(const Duration(minutes: 10))), isFalse);
      expect(happNoInternetNotifyDue(t, t.add(const Duration(minutes: 29, seconds: 59))), isFalse);
      expect(happNoInternetNotifyDue(t, t.add(const Duration(minutes: 30))), isTrue);
    });

    test('days left: counted up, worded right', () {
      final now = DateTime(2026, 11, 16, 12);
      expect(happDaysLeft(expire: now.add(const Duration(hours: 20)), now: now), 1);
      expect(happDaysLeft(expire: now.add(const Duration(days: 1, hours: 2)), now: now), 2);
      expect(happDaysLeft(expire: now.add(const Duration(days: 3)), now: now), 3);
      expect(happDaysLeft(expire: now.add(const Duration(days: 2, hours: 23)), now: now), 3);
      expect(happDaysLeft(expire: now.subtract(const Duration(hours: 1)), now: now), 1);
      expect(happDaysLeftText(1, ru: true), 'Остался 1 день');
      expect(happDaysLeftText(2, ru: true), 'Осталось 2 дня');
      expect(happDaysLeftText(3, ru: true), 'Осталось 3 дня');
      expect(happDaysLeftText(5, ru: true), 'Осталось 5 дней');
      expect(happDaysLeftText(11, ru: true), 'Осталось 11 дней');
      expect(happDaysLeftText(21, ru: true), 'Остался 21 день');
      expect(happDaysLeftText(1, ru: false), '1 day left');
      expect(happDaysLeftText(2, ru: false), '2 days left');
    });

    test('traffic: a tenth or less left of a real limit', () {
      const gb = 1 << 30;
      expect(happTrafficLow(used: 95 * gb, total: 100 * gb), isTrue);
      expect(happTrafficLow(used: 90 * gb, total: 100 * gb), isTrue);
      expect(happTrafficLow(used: 80 * gb, total: 100 * gb), isFalse);
      expect(happTrafficLow(used: 5 * gb, total: 0), isFalse, reason: 'unlimited');
      expect(happTrafficLow(used: 0, total: 20 * 1099511627776), isFalse, reason: 'unlimited, as the card says');
    });
  });

  group('speed test plan', () {
    test('a fast link: a second step sized for ~3 s, capped so the total stays ≤ 5 MB', () {
      // 1 MB in 0.1 s at 10 MB/s: 30 MB wanted, 4 MB allowed
      final second = happSpeedSecondStep(
        firstBytes: happSpeedFirstBytes,
        firstTook: const Duration(milliseconds: 100),
        firstSpeed: 10 << 20,
      );
      expect(second, happSpeedMaxTotal - happSpeedFirstBytes);
      expect(happSpeedFirstBytes + second!, lessThanOrEqualTo(happSpeedMaxTotal));
    });

    test('a middling link: the second step is what 3 s would move, at least 2 MB in all', () {
      // 1 MB in 1.5 s ≈ 700 KB/s → ~2.1 MB for 3 s
      final second = happSpeedSecondStep(
        firstBytes: happSpeedFirstBytes,
        firstTook: const Duration(milliseconds: 1500),
        firstSpeed: 700 * 1024,
      )!;
      expect(second, 700 * 1024 * 3);
      expect(happSpeedFirstBytes + second, inInclusiveRange(happSpeedMinTotal, happSpeedMaxTotal));
      // slower: never under the 2 MB total
      final slow = happSpeedSecondStep(
        firstBytes: happSpeedFirstBytes,
        firstTook: const Duration(milliseconds: 2900),
        firstSpeed: 300 * 1024,
      )!;
      expect(happSpeedFirstBytes + slow, happSpeedMinTotal);
    });

    test('early stop: a slow first step (≥ 3 s) or a failed one is the whole test', () {
      expect(
        happSpeedSecondStep(firstBytes: happSpeedFirstBytes, firstTook: const Duration(seconds: 4), firstSpeed: 250000),
        isNull,
      );
      expect(happSpeedSecondStep(firstBytes: happSpeedFirstBytes, firstTook: Duration.zero, firstSpeed: 0), isNull);
      expect(happSpeedResult(first: 100, second: 200), 200);
      expect(happSpeedResult(first: 100, second: -1), 100);
      expect(happSpeedResult(first: -1), 0);
    });

    test('a step waits for the core: until its download test is over, or the timeout', () {
      ({int bps, bool running})? poll({bool saw = false, bool testing = false, int? speed, int? before, int ms = 0}) =>
          happSpeedPoll(sawTesting: saw, testing: testing, speed: speed, before: before, elapsed: Duration(milliseconds: ms));
      // the core answered but has not marked the server yet: wait
      expect(poll(speed: 0, before: 0, ms: 200), isNull);
      // downloading: wait, well past the old 3 s
      expect(poll(saw: true, testing: true, speed: 0, ms: 3000), isNull);
      expect(poll(saw: true, testing: true, speed: 0, ms: 30000), isNull);
      // over: its speed, the step is done
      expect(poll(saw: true, speed: 900000, before: 0, ms: 8000), (bps: 900000, running: false));
      // over with no speed: failed
      expect(poll(saw: true, speed: -1, before: 0, ms: 8000), (bps: 0, running: false));
      // so fast the mark was missed: a new speed counts
      expect(poll(speed: 5000000, before: 1, ms: 300), (bps: 5000000, running: false));
      // the old speed is not a result
      expect(poll(speed: 777, before: 777, ms: 300), isNull);
      // never started
      expect(poll(speed: 777, before: 777, ms: 3000), (bps: 0, running: false));
      // still downloading at the timeout: nothing else may start
      expect(poll(saw: true, testing: true, speed: 0, ms: happSpeedStepTimeout.inMilliseconds), (bps: 0, running: true));
    });

    test('sequence: a slow first step (measured to its real end) is the whole test', () {
      // the core took 6 s for the first megabyte: no second step
      final first = happSpeedPoll(sawTesting: true, testing: false, speed: 170000, before: 0, elapsed: const Duration(seconds: 6))!;
      expect(happSpeedSecondStep(firstBytes: happSpeedFirstBytes, firstTook: const Duration(seconds: 6), firstSpeed: first.bps), isNull);
      expect(happSpeedResult(first: first.bps), 170000);
      // a timed-out first step gives nothing to size a second one from
      final stuck = happSpeedPoll(sawTesting: true, testing: true, speed: 0, before: 0, elapsed: happSpeedStepTimeout)!;
      expect(stuck.running, isTrue);
      expect(happSpeedSecondStep(firstBytes: happSpeedFirstBytes, firstTook: happSpeedStepTimeout, firstSpeed: stuck.bps), isNull);
    });

    test('results are kept for an hour', () {
      final now = DateTime(2026, 11, 15, 12);
      final raw = happWriteSpeedCache(const {}, {'a': 1250000}, now);
      final cache = happReadSpeedCache(raw);
      expect(happFreshSpeed(cache, 'a', now.add(const Duration(minutes: 59))), 1250000);
      expect(happFreshSpeed(cache, 'a', now.add(const Duration(minutes: 61))), isNull);
      // old ones are dropped on the next write
      final later = happWriteSpeedCache(cache, {'b': 1}, now.add(const Duration(hours: 2)));
      expect(happReadSpeedCache(later).keys, ['b']);
      expect(happReadSpeedCache('not json'), isEmpty);
    });

    test('labels and the top five', () {
      expect(happSpeedLabel(1250000, ru: true), '↓ 10 Мбит/с');
      expect(happSpeedLabel(300000, ru: true), '↓ 2,4 Мбит/с');
      expect(happSpeedLabel(300000, ru: false), '↓ 2.4 Mbit/s');
      expect(happTopByPing({'a': 300, 'b': null, 'c': -1, 'd': 40, 'e': 90, 'f': 10, 'g': 500, 'h': 70}), [
        'f',
        'd',
        'h',
        'e',
        'a',
      ]);
    });
  });

  group('core log', () {
    test('a failed dial through a proxy', () {
      final f = happParseCoreFailure(
        'ERROR [3263484049 10.0s] connection: open connection to www.google.com:443 using outbound/vless[🇨🇿 Прага #1]: dial tcp 1.2.3.4:443: i/o timeout',
      )!;
      expect(f.host, 'www.google.com');
      expect(f.port, 443);
      expect(f.outboundType, 'vless');
      expect(f.outboundTag, '🇨🇿 Прага #1');
      expect(f.kind, HappFailureKind.timeout);
      expect(f.viaProxy, isTrue);
      expect(f.connectionId, '3263484049');
    });

    test('direct, reset, refused, dns, tls', () {
      final direct = happParseCoreFailure(
        '[77 0ms] connection: open packet connection to [2a00:1450::1]:443 using outbound/direct[direct]: connection refused',
      )!;
      expect(direct.direct, isTrue);
      expect(direct.viaProxy, isFalse);
      expect(direct.host, '2a00:1450::1');
      expect(direct.kind, HappFailureKind.refused);
      expect(
        happParseCoreFailure('ERROR [12 3.1s] connection: connection download closed: read tcp 1:2: connection reset by peer')?.kind,
        HappFailureKind.reset,
      );
      expect(
        happParseCoreFailure('ERROR [12 3.1s] connection: connection upload closed: use of closed network connection'),
        isNull,
        reason: 'an ordinary close is not a failure',
      );
      expect(happClassifyError('dial tcp: lookup example.com: no such host'), HappFailureKind.dns);
      expect(happClassifyError('tls: handshake failure'), HappFailureKind.tls);
      expect(happClassifyError('reality verification failed'), HappFailureKind.tls);
      expect(happParseCoreFailure('INFO router: updated default interface wlan0'), isNull);
    });

    test('package of a connection', () {
      expect(happPackageOfProcessPath('org.telegram.messenger (org.telegram.messenger)'), 'org.telegram.messenger');
      expect(happPackageOfProcessPath('10123'), isNull);
      expect(happPackageOfProcessPath(''), isNull);
      expect(happPackageOfProcessPath(null), isNull);
    });
  });
}
