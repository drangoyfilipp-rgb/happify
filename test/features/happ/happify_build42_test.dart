import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happ_sub_update.dart';
import 'package:hiddify/features/happ/happify_traffic_saving.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_runtime.dart';

void main() {
  final t0 = DateTime(2026, 11, 17, 10);
  const every = Duration(minutes: 15);

  group('happUpdateCheckDue', () {
    test('first run is due', () => expect(happUpdateCheckDue(null, t0, every), isTrue));
    test('15 min after the previous start is due, even a few seconds short', () {
      expect(happUpdateCheckDue(t0, t0.add(every), every), isTrue);
      expect(happUpdateCheckDue(t0.add(const Duration(seconds: 20)), t0.add(every), every), isTrue);
    });
    test('a few minutes later is too soon', () {
      expect(happUpdateCheckDue(t0, t0.add(const Duration(minutes: 5)), every), isFalse);
    });
  });

  group('happProfileUpdateDue', () {
    test('off: null or zero interval', () {
      expect(happProfileUpdateDue(interval: null, lastUpdate: t0, now: t0.add(const Duration(days: 1))), isFalse);
      expect(happProfileUpdateDue(interval: Duration.zero, lastUpdate: t0, now: t0.add(const Duration(days: 1))), isFalse);
    });
    test('hourly: an update that ended 10 s late does not wait an extra round', () {
      final last = t0.add(const Duration(seconds: 10));
      expect(happProfileUpdateDue(interval: const Duration(hours: 1), lastUpdate: last, now: t0.add(const Duration(hours: 1))), isTrue);
    });
    test('hourly: 45 min after is not due', () {
      expect(
        happProfileUpdateDue(interval: const Duration(hours: 1), lastUpdate: t0, now: t0.add(const Duration(minutes: 45))),
        isFalse,
      );
    });
  });

  group('happEffectiveUpdateEvery', () {
    test('as set without saving', () {
      expect(
        happEffectiveUpdateEvery(const Duration(hours: 1), saving: false, stretch: happSavingUpdateInterval),
        const Duration(hours: 1),
      );
    });
    test('saving: 1 h becomes 6 h', () {
      expect(
        happEffectiveUpdateEvery(const Duration(hours: 1), saving: true, stretch: happSavingUpdateInterval),
        const Duration(hours: 6),
      );
    });
    test('off stays off', () {
      expect(happEffectiveUpdateEvery(null, saving: true, stretch: happSavingUpdateInterval), isNull);
      expect(happEffectiveUpdateEvery(Duration.zero, saving: false, stretch: happSavingUpdateInterval), isNull);
    });
  });

  group('happSubUpdateNeedsReload', () {
    test('same bytes, same override: no reload', () {
      expect(
        happSubUpdateNeedsReload(before: [1, 2, 3], after: [1, 2, 3], overrideBefore: '{}', overrideAfter: '{}'),
        isFalse,
      );
    });
    test('changed bytes: reload', () {
      expect(
        happSubUpdateNeedsReload(before: [1, 2, 3], after: [1, 2, 4], overrideBefore: '{}', overrideAfter: '{}'),
        isTrue,
      );
      expect(
        happSubUpdateNeedsReload(before: [1, 2], after: [1, 2, 3], overrideBefore: '{}', overrideAfter: '{}'),
        isTrue,
      );
    });
    test('unknown file: reload', () {
      expect(happSubUpdateNeedsReload(before: null, after: [1], overrideBefore: '', overrideAfter: ''), isTrue);
      expect(happSubUpdateNeedsReload(before: [1], after: null, overrideBefore: '', overrideAfter: ''), isTrue);
    });
    test('changed override: reload', () {
      expect(
        happSubUpdateNeedsReload(before: [1], after: [1], overrideBefore: '{}', overrideAfter: '{"keep-top":5}'),
        isTrue,
      );
    });
  });

  test('happProbeTimeout: longer for a recheck', () {
    expect(happProbeTimeout(0), const Duration(seconds: 5));
    expect(happProbeTimeout(1), const Duration(seconds: 10));
    expect(happProbeTimeout(2), const Duration(seconds: 10));
  });
}
