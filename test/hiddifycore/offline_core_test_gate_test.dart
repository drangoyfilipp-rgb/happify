import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/hiddifycore/offline_core_test_gate.dart';

void main() {
  group('happPingRoute', () {
    test('connected to this subscription: the live core tests it', () {
      expect(happPingRoute(connected: true, thisIsActive: true, offlineCapable: true), HappPingRoute.live);
      expect(happPingRoute(connected: true, thisIsActive: true, offlineCapable: false), HappPingRoute.live);
    });

    test('connected to another subscription: never a test core, the connection stays', () {
      expect(happPingRoute(connected: true, thisIsActive: false, offlineCapable: true), HappPingRoute.busyOther);
      expect(happPingRoute(connected: true, thisIsActive: false, offlineCapable: false), HappPingRoute.busyOther);
    });

    test('nothing connected: a proxy-only test core where the platform allows it', () {
      expect(happPingRoute(connected: false, thisIsActive: true, offlineCapable: true), HappPingRoute.offline);
      expect(happPingRoute(connected: false, thisIsActive: false, offlineCapable: true), HappPingRoute.offline);
      expect(happPingRoute(connected: false, thisIsActive: false, offlineCapable: false), HappPingRoute.unsupported);
    });
  });

  group('OfflineCoreTestGate', () {
    test('connecting waits until the test core is stopped and the settings are back', () async {
      final gate = OfflineCoreTestGate();
      final log = <String>[];
      final test = gate.run(() async {
        log.add('test core started');
        await gate.onCancel;
        // cleaning up takes a while: stop the core, put the settings back
        await Future<void>.delayed(const Duration(milliseconds: 50));
        log.add('test core stopped, settings restored');
        return 'done';
      });
      await Future<void>.delayed(Duration.zero);
      expect(gate.busy, isTrue);

      Future<void> connect() async {
        await gate.cancelAndWait();
        log.add('connect');
      }

      await connect();
      expect(await test, 'done');
      expect(log, ['test core started', 'test core stopped, settings restored', 'connect']);
      expect(gate.busy, isFalse);
    });

    test('one test at a time', () async {
      final gate = OfflineCoreTestGate();
      final release = Completer<void>();
      final first = gate.run(() async {
        await release.future;
        return 1;
      });
      expect(await gate.run(() async => 2), isNull);
      release.complete();
      expect(await first, 1);
      expect(await gate.run(() async => 3), 3);
    });

    test('connecting with no test under way does not wait', () async {
      final gate = OfflineCoreTestGate();
      await gate.cancelAndWait().timeout(const Duration(milliseconds: 100));
      expect(gate.busy, isFalse);
      expect(gate.cancelled, isFalse);
    });

    test('a test that fails still frees the gate', () async {
      final gate = OfflineCoreTestGate();
      await expectLater(gate.run<void>(() async => throw StateError('core refused')), throwsStateError);
      expect(gate.busy, isFalse);
      expect(await gate.run(() async => 'again'), 'again');
    });

    test('no test starts while a connection is being made', () async {
      final gate = OfflineCoreTestGate();
      final connecting = Completer<void>();
      final log = <String>[];
      final connect = gate.exclusive(() async {
        log.add('connect started');
        await connecting.future;
        log.add('connected');
        return 'up';
      });
      await Future<void>.delayed(Duration.zero);
      // the speedometer pressed mid-connect: refused, nothing runs
      expect(
        await gate.run(() async {
          log.add('test core');
          return 1;
        }),
        isNull,
      );
      connecting.complete();
      expect(await connect, 'up');
      expect(log, ['connect started', 'connected']);
      expect(gate.held, isFalse);
    });

    test('a test running when connect is pressed is called off first', () async {
      final gate = OfflineCoreTestGate();
      final log = <String>[];
      final test = gate.run(() async {
        await gate.onCancel;
        log.add('test core stopped');
      });
      await Future<void>.delayed(Duration.zero);
      await gate.exclusive(() async => log.add('connect'));
      await test;
      expect(log, ['test core stopped', 'connect']);
    });
  });
}
