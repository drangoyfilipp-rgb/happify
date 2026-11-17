import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happ_switch_guard.dart';

void main() {
  group('happWithDeadline', () {
    test('returns the result when in time', () async {
      expect(
        await happWithDeadline<bool>(() async => true, deadline: const Duration(seconds: 1), fallback: false),
        isTrue,
      );
    });

    test('a call that never answers gives the fallback at the deadline', () {
      fakeAsync((fa) {
        bool? result;
        var timedOut = false;
        happWithDeadline<bool>(
          () => Completer<bool>().future,
          deadline: happSelectDeadline,
          fallback: false,
          onTimeout: () => timedOut = true,
        ).then((v) => result = v);
        fa.elapse(happSelectDeadline - const Duration(milliseconds: 1));
        expect(result, isNull);
        fa.elapse(const Duration(milliseconds: 2));
        expect(result, isFalse);
        expect(timedOut, isTrue);
      });
    });

    test('a throw gives the fallback, sync or async', () async {
      Object? seen;
      expect(
        await happWithDeadline<bool>(
          () => throw StateError('x'),
          deadline: const Duration(seconds: 1),
          fallback: false,
          onError: (e) => seen = e,
        ),
        isFalse,
      );
      expect(seen, isA<StateError>());
      expect(
        await happWithDeadline<bool>(
          () async => throw Exception(),
          deadline: const Duration(seconds: 1),
          fallback: false,
        ),
        isFalse,
      );
    });

    test('deadlines: pick under the row switch', () {
      expect(happSelectDeadline < happSwitchDeadline, isTrue);
      expect(happSelectDeadline.inSeconds, 5);
    });
  });

  group('HappLatestWins', () {
    test('a new tap makes the older one stale', () {
      final t = HappLatestWins();
      final a = t.begin();
      expect(t.isLatest(a), isTrue);
      final b = t.begin();
      expect(t.isLatest(a), isFalse);
      expect(t.isLatest(b), isTrue);
      t.cancelAll();
      expect(t.isLatest(b), isFalse);
    });

    test('only the latest tap clears the spinner, even when the old one ends last', () async {
      final taps = HappLatestWins();
      String? switching;
      final slow = Completer<bool>();
      Future<void> tap(String tag, Future<bool> core) async {
        final ticket = taps.begin();
        switching = tag;
        try {
          await core;
        } finally {
          if (taps.isLatest(ticket)) switching = null;
        }
      }

      final first = tap('lowest', slow.future);
      expect(switching, 'lowest');
      final second = tap('Prague', Future.value(true));
      expect(switching, 'Prague');
      await second;
      expect(switching, isNull);
      slow.complete(false);
      await first;
      expect(switching, isNull);
    });
  });

  group('HappSwitchActivity', () {
    test('counts a pick in flight and clears it on error', () async {
      expect(HappSwitchActivity.busy, isFalse);
      final gate = Completer<void>();
      final run = HappSwitchActivity.track(() => gate.future);
      expect(HappSwitchActivity.busy, isTrue);
      gate.complete();
      await run;
      expect(HappSwitchActivity.busy, isFalse);
      await expectLater(HappSwitchActivity.track<void>(() async => throw Exception()), throwsException);
      expect(HappSwitchActivity.busy, isFalse);
    });

    test('URL tests wait for a pick, at most the deadline', () {
      fakeAsync((fa) {
        final gate = Completer<void>();
        HappSwitchActivity.track(() => gate.future);
        bool? idle;
        HappSwitchActivity.waitIdle(max: const Duration(seconds: 5)).then((v) => idle = v);
        fa.elapse(const Duration(seconds: 1));
        expect(idle, isNull);
        gate.complete();
        fa.flushMicrotasks();
        expect(idle, isTrue);

        final stuck = Completer<void>();
        HappSwitchActivity.track(() => stuck.future);
        bool? idle2;
        HappSwitchActivity.waitIdle(max: const Duration(seconds: 5)).then((v) => idle2 = v);
        fa.elapse(const Duration(seconds: 5, milliseconds: 1));
        expect(idle2, isFalse);
        stuck.complete();
        fa.flushMicrotasks();
        expect(HappSwitchActivity.busy, isFalse);
      });
    });
  });

  group('HappPickLedger', () {
    test('an older pick answered late after the newest re-sends the newest', () {
      final l = HappPickLedger();
      final old = l.begin('select', 'lowest');
      final latest = l.begin('select', 'Prague');
      expect(l.isLatest('select', old), isFalse);
      expect(l.finish('select', latest, ok: true), isNull);
      expect(l.finish('select', old, ok: true), 'Prague');
    });

    test('nothing to re-send when the old one failed or the newest is not done', () {
      final l = HappPickLedger();
      final a = l.begin('select', 'A');
      final b = l.begin('select', 'B');
      expect(l.finish('select', a, ok: true), isNull); // newest still running: it lands after
      expect(l.finish('select', b, ok: true), isNull);
      final c = l.begin('select', 'C');
      final d = l.begin('select', 'D');
      expect(l.finish('select', d, ok: true), isNull);
      expect(l.finish('select', c, ok: false), isNull);
    });

    test('groups are separate', () {
      final l = HappPickLedger();
      final a = l.begin('select', 'A');
      l.begin('other', 'X');
      expect(l.isLatest('select', a), isTrue);
    });
  });
}
