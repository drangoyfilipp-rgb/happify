import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_machine.dart';

/// Drives the machine the way the runtime does, on a fake clock.
class Sim {
  Sim({bool autoSwitch = true}) : m = HappFailoverMachine(autoSwitch: autoSwitch);

  final HappFailoverMachine m;
  DateTime now = DateTime(2026, 11, 15, 12);
  final switches = <String>[];

  void wait(Duration d) => now = now.add(d);

  HappFailoverStep probe(bool ok) => m.onProbe(ok: ok, now: now);

  /// Three failed probes ten seconds apart, as the runtime schedules them.
  HappFailoverStep failThreeTimes() {
    HappFailoverStep? step;
    for (var i = 0; i < 3; i++) {
      step = probe(false);
      if (i < 2) {
        expect(step.probeIn, const Duration(seconds: 10), reason: 'a failure is checked again after 10 s');
        wait(step.probeIn!);
      }
    }
    return step!;
  }

  HappFailoverStep? apply(HappFailoverStep? step) {
    if (step?.switchTo != null) switches.add(step!.switchTo!);
    return step;
  }
}

void main() {
  group('failover state machine', () {
    test('a single timeout never switches', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      final step = s.probe(false);
      expect(step.level, HappLiveness.warn);
      expect(step.checkDirect, isFalse);
      expect(step.pickReplacement, isFalse);
      expect(step.switchTo, isNull);
      s.wait(step.probeIn!);
      final ok = s.probe(true);
      expect(ok.level, HappLiveness.ok);
      expect(s.m.fails, 0);
      expect(s.m.current, 'Прага');
    });

    test('two failures then a success never switch; the count starts over', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.probe(false);
      s.wait(const Duration(seconds: 10));
      expect(s.probe(false).level, HappLiveness.warn);
      s.wait(const Duration(seconds: 10));
      s.probe(true);
      s.wait(const Duration(seconds: 60));
      final step = s.probe(false);
      expect(step.level, HappLiveness.warn, reason: 'one new failure, not the third');
      expect(step.checkDirect, isFalse);
    });

    test('3 failures and the direct internet works: the best live server is picked', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      final third = s.failThreeTimes();
      expect(third.level, HappLiveness.bad);
      expect(third.checkDirect, isTrue);
      final direct = s.m.onDirect(ok: true, now: s.now);
      expect(direct.pickReplacement, isTrue);
      expect(direct.level, HappLiveness.switching);
      final chosen = happChooseReplacement(
        current: 'Прага',
        servers: const [
          (tag: 'Прага', family: 'reality', country: 'CZ'),
          (tag: 'Хельсинки', family: 'reality', country: 'FI'),
          (tag: 'Стокгольм', family: 'reality', country: 'SE'),
        ],
        delays: const {'Прага': null, 'Хельсинки': 90, 'Стокгольм': 70},
      );
      expect(chosen?.tag, 'Стокгольм');
      expect(chosen?.protocolFallback, isFalse);
      final sw = s.apply(s.m.onReplacement(chosen!.tag, now: s.now))!;
      expect(sw.switchTo, 'Стокгольм');
      expect(s.m.current, 'Стокгольм');
      expect(s.m.preferred, 'Прага', reason: 'the user\'s choice is remembered, not overwritten');
      expect(sw.probeIn, isNotNull, reason: 'the new server is checked right away');
    });

    test('3 failures and no direct internet: «нет интернета», nothing switched', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      final step = s.m.onDirect(ok: false, now: s.now);
      expect(step.level, HappLiveness.noInternet);
      expect(step.pickReplacement, isFalse);
      expect(step.switchTo, isNull);
      expect(s.m.current, 'Прага');
      expect(step.probeIn, const Duration(seconds: 30));
      // the network comes back, the same server answers: green again, still the same server
      s.wait(step.probeIn!);
      expect(s.probe(true).level, HappLiveness.ok);
      expect(s.m.current, 'Прага');
    });

    test('with the screen off and no internet nothing is scheduled', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.m.onScreen(on: false, now: s.now);
      s.failThreeTimes();
      expect(s.m.onDirect(ok: false, now: s.now).probeIn, isNull);
    });

    test('back to the preferred server after it answers 2 probes in a row', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      s.apply(s.m.onReplacement('Хельсинки', now: s.now));
      s.wait(const Duration(seconds: 5));
      var step = s.probe(true);
      expect(step.probePreferred, isFalse, reason: 'not before the hold (2 min) has passed');
      // a minute later: still held
      s.wait(const Duration(seconds: 60));
      expect(s.probe(true).probePreferred, isFalse);
      s.wait(const Duration(seconds: 60));
      step = s.probe(true);
      expect(step.probePreferred, isTrue);
      expect(s.apply(s.m.onPreferredProbe(ok: true, now: s.now)), isNull, reason: 'one success is not enough');
      s.wait(const Duration(seconds: 60));
      step = s.probe(true);
      expect(step.probePreferred, isTrue);
      final back = s.apply(s.m.onPreferredProbe(ok: true, now: s.now))!;
      expect(back.switchTo, 'Прага');
      expect(back.returning, isTrue);
      expect(s.m.current, 'Прага');
      expect(s.switches, ['Хельсинки', 'Прага']);
    });

    test('a failed probe of the preferred server resets its streak', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      s.m.onReplacement('Хельсинки', now: s.now);
      s.wait(const Duration(minutes: 3));
      s.probe(true);
      s.m.onPreferredProbe(ok: true, now: s.now);
      s.wait(const Duration(seconds: 60));
      s.probe(true);
      expect(s.m.onPreferredProbe(ok: false, now: s.now), isNull);
      s.wait(const Duration(seconds: 60));
      s.probe(true);
      expect(s.m.onPreferredProbe(ok: true, now: s.now), isNull, reason: 'the streak started over');
      expect(s.m.current, 'Хельсинки');
    });

    test('no flapping: a server that fails again soon after coming back waits twice as long', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);

      void switchAway(String to) {
        s.failThreeTimes();
        s.m.onDirect(ok: true, now: s.now);
        s.apply(s.m.onReplacement(to, now: s.now));
      }

      Duration timeToReturn() {
        final start = s.now;
        var oks = 0;
        for (var i = 0; i < 120; i++) {
          s.wait(const Duration(seconds: 60));
          final step = s.probe(true);
          if (step.probePreferred) {
            final back = s.apply(s.m.onPreferredProbe(ok: true, now: s.now));
            oks++;
            if (back?.switchTo == 'Прага') return s.now.difference(start);
          }
        }
        fail('never came back ($oks)');
      }

      switchAway('Хельсинки');
      final first = timeToReturn();
      expect(first, lessThanOrEqualTo(const Duration(minutes: 4)));
      // fails again a minute after coming back: the next return is held twice as long
      s.wait(const Duration(minutes: 1));
      switchAway('Хельсинки');
      expect(s.m.returnHold, const Duration(minutes: 4));
      final second = timeToReturn();
      expect(second, greaterThan(first));
      s.wait(const Duration(minutes: 1));
      switchAway('Хельсинки');
      expect(s.m.returnHold, const Duration(minutes: 8));
      // within an hour at most 4 switches, not one every minute
      expect(s.switches.length, lessThanOrEqualTo(6));
      // stays up for half an hour after coming back: the hold is back to normal
      timeToReturn();
      for (var i = 0; i < 31; i++) {
        s.wait(const Duration(minutes: 1));
        s.probe(true);
      }
      expect(s.m.returnHold, const Duration(minutes: 2));
    });

    test('switching off: the indicator still turns red, nothing is switched', () {
      final s = Sim(autoSwitch: false);
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      final step = s.m.onDirect(ok: true, now: s.now);
      expect(step.level, HappLiveness.bad);
      expect(step.pickReplacement, isFalse);
      expect(step.switchTo, isNull);
    });

    test('lowest and balance are never switched away from; the core is asked to test again', () {
      final s = Sim();
      s.m.start(current: 'lowest', currentIsGroup: true);
      s.failThreeTimes();
      final step = s.m.onDirect(ok: true, now: s.now);
      expect(step.pickReplacement, isFalse);
      expect(step.switchTo, isNull);
      expect(step.refreshGroup, isTrue);
      // again within a minute: not asked again
      s.wait(const Duration(seconds: 10));
      s.failThreeTimes();
      expect(s.m.onDirect(ok: true, now: s.now).refreshGroup, isFalse);
      expect(s.m.current, 'lowest');
    });

    test('a manual pick becomes the preferred server and clears the state', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      s.m.onReplacement('Хельсинки', now: s.now);
      s.m.userSelected('Стокгольм', isGroup: false);
      expect(s.m.preferred, 'Стокгольм');
      expect(s.m.autoSince, isNull);
      s.wait(const Duration(minutes: 5));
      expect(s.probe(true).probePreferred, isFalse, reason: 'already on the user\'s server');
    });

    test('no server answers: red, checked again later, nothing switched', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      final step = s.m.onReplacement(null, now: s.now);
      expect(step.level, HappLiveness.bad);
      expect(step.switchTo, isNull);
      expect(step.probeIn, const Duration(seconds: 30));
    });

    test('the failed server is not chosen again for a while', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      expect(s.m.isBad('Прага', s.now), isTrue);
      s.wait(const Duration(minutes: 6));
      s.probe(true);
      expect(s.m.isBad('Прага', s.now), isFalse);
    });

    test('passive signal: probes at once, but not during a check nor right after a probe', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.probe(true);
      s.wait(const Duration(seconds: 5));
      expect(s.m.onPassiveSignal(now: s.now), isNull, reason: 'a probe ran 5 s ago');
      s.wait(const Duration(seconds: 20));
      expect(s.m.onPassiveSignal(now: s.now)?.probeIn, Duration.zero);
      s.probe(false);
      expect(s.m.onPassiveSignal(now: s.now.add(const Duration(seconds: 30))), isNull, reason: 'a check is under way');
    });

    test('screen off stops the periodic probe; screen on brings an early one', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      expect(s.probe(true).probeIn, const Duration(seconds: 60));
      final off = s.m.onScreen(on: false, now: s.now)!;
      expect(off.probeIn, isNull);
      s.wait(const Duration(seconds: 1));
      expect(s.probe(true).probeIn, isNull, reason: 'no periodic probe with the screen off');
      s.wait(const Duration(minutes: 10));
      expect(s.m.onScreen(on: true, now: s.now)?.probeIn, const Duration(seconds: 1));
      // a failure with the screen off still gets its 10 s rechecks
      s.m.onScreen(on: false, now: s.now);
      expect(s.probe(false).probeIn, const Duration(seconds: 10));
      expect(s.m.onScreen(on: true, now: s.now), isNull, reason: 'the recheck keeps its time');
    });

    test('screen off: nothing is scheduled on a timer once a check has ended', () {
      // all dead, switching off, group refresh, no internet: no repeat while the screen is off
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.m.onScreen(on: false, now: s.now);
      s.failThreeTimes();
      expect(s.m.onDirect(ok: false, now: s.now).probeIn, isNull, reason: 'no internet');
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      expect(s.m.onReplacement(null, now: s.now).probeIn, isNull, reason: 'no server answers');

      final off = Sim(autoSwitch: false);
      off.m.start(current: 'Прага', currentIsGroup: false);
      off.m.onScreen(on: false, now: off.now);
      off.failThreeTimes();
      expect(off.m.onDirect(ok: true, now: off.now).probeIn, isNull, reason: 'switching off');

      final g = Sim();
      g.m.start(current: 'lowest', currentIsGroup: true);
      g.m.onScreen(on: false, now: g.now);
      g.failThreeTimes();
      final refresh = g.m.onDirect(ok: true, now: g.now);
      expect(refresh.refreshGroup, isTrue);
      expect(refresh.probeIn, isNull, reason: 'the group is retested, not polled');

      // the screen on again: the same states recheck on their timer
      final on = Sim();
      on.m.start(current: 'Прага', currentIsGroup: false);
      on.failThreeTimes();
      expect(on.m.onDirect(ok: false, now: on.now).probeIn, const Duration(seconds: 30));
    });

    test('a server the core selected by itself is in use, never the user\'s choice', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      final step = s.m.coreSelected('Хельсинки', isGroup: false, now: s.now)!;
      expect(step.probeIn, const Duration(seconds: 5));
      expect(s.m.current, 'Хельсинки');
      expect(s.m.preferred, 'Прага');
      expect(s.m.autoSince, s.now);
      expect(s.m.coreSelected('Хельсинки', isGroup: false, now: s.now), isNull);
      s.m.coreSelected('Прага', isGroup: false, now: s.now);
      expect(s.m.onPreferred, isTrue);
      expect(s.m.autoSince, isNull);
    });

    test('a switch the core refused: the old server stays in use and is checked again', () {
      final s = Sim();
      s.m.start(current: 'Прага', currentIsGroup: false);
      s.failThreeTimes();
      s.m.onDirect(ok: true, now: s.now);
      s.m.onReplacement('Хельсинки', now: s.now);
      final back = s.m.switchFailed(previous: 'Прага', previousIsGroup: false, now: s.now);
      expect(s.m.current, 'Прага');
      expect(s.m.onPreferred, isTrue);
      expect(s.m.autoSince, isNull);
      expect(back.probeIn, const Duration(seconds: 10));
      expect(back.level, HappLiveness.warn);
    });

    test('traffic lights', () {
      expect(HappLiveness.ok.light, 1);
      expect(HappLiveness.warn.light, 2);
      expect(HappLiveness.bad.light, 3);
      expect(HappLiveness.switching.light, 3);
      expect(HappLiveness.noInternet.light, 3);
      expect(HappLiveness.idle.light, 0);
    });
  });

  group('replacement choice', () {
    const servers = [
      (tag: 'Прага VLESS', family: 'reality', country: 'CZ'),
      (tag: 'Прага HY2', family: 'hysteria', country: 'CZ'),
      (tag: 'Хельсинки VLESS', family: 'reality', country: 'FI'),
      (tag: 'Хельсинки HY2', family: 'hysteria', country: 'FI'),
      (tag: 'Стокгольм WS', family: 'vless-tls', country: 'SE'),
    ];

    test('protocol fallback: every hysteria server fails, Reality first', () {
      final r = happChooseReplacement(
        current: 'Прага HY2',
        servers: servers,
        delays: const {'Хельсинки HY2': -1, 'Прага VLESS': 140, 'Хельсинки VLESS': 120, 'Стокгольм WS': 50},
      );
      expect(r?.protocolFallback, isTrue);
      expect(r?.tag, 'Прага VLESS', reason: 'Reality first, the same country when nearly as fast');
    });

    test('protocol fallback from Reality picks the fastest other protocol', () {
      final r = happChooseReplacement(
        current: 'Прага VLESS',
        servers: servers,
        delays: const {'Хельсинки VLESS': null, 'Прага HY2': 300, 'Хельсинки HY2': 80, 'Стокгольм WS': 60},
      );
      expect(r?.protocolFallback, isTrue);
      expect(r?.tag, 'Стокгольм WS');
    });

    test('same protocol still alive: no fallback, the fastest live one', () {
      final r = happChooseReplacement(
        current: 'Прага VLESS',
        servers: servers,
        delays: const {'Хельсинки VLESS': 200, 'Прага HY2': 40, 'Стокгольм WS': 500},
      );
      expect(r?.protocolFallback, isFalse);
      expect(r?.tag, 'Прага HY2');
    });

    test('nothing answers', () {
      expect(happChooseReplacement(current: 'Прага VLESS', servers: servers, delays: const {}), isNull);
    });

    test('excluded (recently failed) servers are skipped', () {
      final r = happChooseReplacement(
        current: 'Прага VLESS',
        servers: servers,
        delays: const {'Хельсинки VLESS': 50, 'Стокгольм WS': 90},
        exclude: const {'Хельсинки VLESS'},
      );
      expect(r?.tag, 'Стокгольм WS');
    });

    test('protocol families', () {
      expect(happProtocolFamily('vless', 'VLESS / TCP / REALITY | JSON'), 'reality');
      expect(happProtocolFamily('hysteria2', 'HYSTERIA / HYSTERIA / TLS | JSON'), 'hysteria');
      expect(happProtocolFamily('vless', 'VLESS / WS / TLS | JSON'), 'vless-tls');
      expect(happProtocolFamily('trojan', 'TROJAN / TCP / TLS | JSON'), 'trojan-tls');
      expect(happProtocolFamily('shadowsocks', 'SHADOWSOCKS / TCP | JSON'), 'shadowsocks');
      expect(happProtocolFamily('vmess', 'VMESS / TCP | JSON'), 'vmess');
    });
  });

  group('failure burst', () {
    test('four failures to two hosts within 10 s fire once', () {
      final b = HappFailureBurst();
      final t = DateTime(2026);
      expect(b.add(t, 'a.com'), isFalse);
      expect(b.add(t.add(const Duration(seconds: 1)), 'a.com'), isFalse);
      expect(b.add(t.add(const Duration(seconds: 2)), 'b.com'), isFalse);
      expect(b.add(t.add(const Duration(seconds: 3)), 'b.com'), isTrue);
      expect(b.add(t.add(const Duration(seconds: 4)), 'c.com'), isFalse, reason: 'counts again from zero');
    });

    test('one broken site is not a burst', () {
      final b = HappFailureBurst();
      final t = DateTime(2026);
      for (var i = 0; i < 10; i++) {
        expect(b.add(t.add(Duration(seconds: i)), 'broken.example'), isFalse);
      }
    });

    test('failures spread out over time are not a burst', () {
      final b = HappFailureBurst();
      final t = DateTime(2026);
      for (var i = 0; i < 10; i++) {
        expect(b.add(t.add(Duration(seconds: i * 6)), 'h$i'), isFalse);
      }
    });
  });
}
