import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happ_ping_plan.dart';
import 'package:hiddify/features/happ/reliability/happ_speed_plan.dart';

void main() {
  final t0 = DateTime(2026, 11, 16, 19);

  group('happTopFreshByPing', () {
    HappPingSample s(String tag, int delay, {DateTime? at, bool group = false, bool visible = true}) =>
        (tag: tag, isGroup: group, visible: visible, delay: delay, testedAt: at);
    final fresh = t0.add(const Duration(seconds: 2));
    final stale = t0.subtract(const Duration(minutes: 5));

    test('lowest fresh pings first, 5 of them', () {
      final r = happTopFreshByPing([
        s('a', 300, at: fresh),
        s('b', 40, at: fresh),
        s('c', 90, at: fresh),
        s('d', 10, at: fresh),
        s('e', 500, at: fresh),
        s('f', 70, at: fresh),
        s('g', 1200, at: fresh),
      ], t0);
      expect(r, ['d', 'b', 'f', 'c', 'a']);
    });

    test('no ping, failed, timeout, groups and hidden ones are left out', () {
      final r = happTopFreshByPing([
        s('none', 0, at: fresh),
        s('neg', -1, at: fresh),
        s('timeout', 65535, at: fresh),
        s('lowest', 5, at: fresh, group: true),
        s('balance', 6, at: fresh, group: true),
        s('hidden', 7, at: fresh, visible: false),
        s('ok', 120, at: fresh),
      ], t0);
      expect(r, ['ok']);
    });

    test('a ping from before the test does not count while fresh ones exist', () {
      final r = happTopFreshByPing([s('old-fast', 20, at: stale), s('new', 200, at: fresh), s('notime', 15)], t0);
      expect(r, ['new']);
    });

    test('no fresh ping at all: the working ones of this run', () {
      final r = happTopFreshByPing([s('x', 300, at: stale), s('y', 100, at: stale), s('z', 0)], t0);
      expect(r, ['y', 'x']);
    });

    test('ties by name, stable', () {
      expect(happTopFreshByPing([s('b', 50, at: fresh), s('a', 50, at: fresh)], t0, count: 1), ['a']);
    });
  });

  group('happPingRowDone', () {
    test('not asked yet: not done', () {
      expect(happPingRowDone(delay: 80, testedAt: t0, startedAt: null, now: t0), isFalse);
    });
    test('a working result since the start: done', () {
      expect(
        happPingRowDone(delay: 80, testedAt: t0.add(const Duration(seconds: 1)), startedAt: t0, now: t0.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
    test('the same value as before, measured again: done (not stuck on «no change»)', () {
      expect(
        happPingRowDone(delay: 80, testedAt: t0.add(const Duration(milliseconds: 900)), startedAt: t0, now: t0.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
    test('an old result: not done before the deadline', () {
      expect(
        happPingRowDone(delay: 80, testedAt: t0.subtract(const Duration(minutes: 1)), startedAt: t0, now: t0.add(const Duration(seconds: 5))),
        isFalse,
      );
    });
    test('the core\'s 1 s miss is not final: waits for the next attempt', () {
      expect(
        happPingRowDone(delay: 65535, testedAt: t0.add(const Duration(seconds: 1)), startedAt: t0, now: t0.add(const Duration(seconds: 2))),
        isFalse,
      );
    });
    test('always done at the deadline', () {
      expect(happPingRowDone(delay: 0, testedAt: null, startedAt: t0, now: t0.add(happPingRowDeadline)), isTrue);
      expect(happPingRowDeadline, greaterThan(const Duration(seconds: 10)));
    });
  });

  test('happPingWaves splits in order', () {
    expect(happPingWaves(['a', 'b', 'c', 'd', 'e'], size: 2), [
      ['a', 'b'],
      ['c', 'd'],
      ['e'],
    ]);
    expect(happPingWaves(const []), isEmpty);
  });

  group('happGroupNowLabel', () {
    String d(String tag) => 'T:$tag';
    test('the member in use', () {
      expect(happGroupNowLabel(selectedTag: 'sto', groupTag: 'balance', display: d, members: 9, ru: true), 'Сейчас: T:sto');
      expect(happGroupNowLabel(selectedTag: 'sto', groupTag: 'lowest', display: d, members: 9, ru: false), 'Now: T:sto');
    });
    test('none yet: the count', () {
      expect(happGroupNowLabel(selectedTag: '', groupTag: 'balance', display: d, members: 9, ru: true), 'Серверов: 9');
      expect(happGroupNowLabel(selectedTag: 'balance', groupTag: 'balance', display: d, members: 0, ru: true), 'Выбирает сервер…');
    });
  });

  test('a server that passed the speed test is pinged again when its ping failed', () {
    expect(happRepingAfterSpeed(bps: 4000000, delay: 65535), isTrue);
    expect(happRepingAfterSpeed(bps: 4000000, delay: 0), isTrue);
    expect(happRepingAfterSpeed(bps: 4000000, delay: 90), isFalse);
    expect(happRepingAfterSpeed(bps: 0, delay: 65535), isFalse);
  });

  test('happTopByPing leaves out timeouts too', () {
    expect(happTopByPing({'a': 65535, 'b': 30, 'c': null, 'd': -1}), ['b']);
  });
}
