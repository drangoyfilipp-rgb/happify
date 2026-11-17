import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/happ/reliability/happ_speed_plan.dart';
import 'package:hiddify/features/happ/reliability/happ_wifi_status.dart';
import 'package:hiddify/features/proxy/model/connection_health.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';

OutboundInfo _proxy(String tag, int delay) => OutboundInfo(tag: tag, urlTestDelay: delay);

ConnectionHealth _health({required int pick, ChainStatus chain = ChainStatus.off}) => ConnectionHealth.from(
  const Connected(),
  OutboundGroupList(
    items: [
      OutboundGroup(tag: 'select', items: [_proxy('Стокгольм #1', pick)]),
      OutboundGroup(tag: 'lowest', items: [_proxy('fast', 80)]),
    ],
  ),
  chain,
);

void main() {
  group('trusted Wi-Fi status', () {
    test('a name is a name', () {
      final r = happWifiStatusOf({'wifi': true, 'ssid': 'Home', 'permission': true, 'location': true});
      expect(r.status, HappWifiStatus.named);
      expect(r.ssid, 'Home');
    });
    test('on Wi-Fi under the VPN without location access asks for it, not «не подключён»', () {
      final r = happWifiStatusOf({'wifi': true, 'ssid': null, 'permission': false, 'location': true});
      expect(r.status, HappWifiStatus.needPermission);
    });
    test('location turned off on the phone', () {
      final r = happWifiStatusOf({'wifi': true, 'ssid': null, 'permission': true, 'location': false});
      expect(r.status, HappWifiStatus.locationOff);
    });
    test('permission and location on but no name', () {
      expect(happWifiStatusOf({'wifi': true, 'permission': true, 'location': true}).status, HappWifiStatus.hidden);
    });
    test('really not on Wi-Fi', () {
      expect(happWifiStatusOf({'wifi': false, 'permission': false}).status, HappWifiStatus.notOnWifi);
    });
    test('no answer', () {
      expect(happWifiStatusOf(null).status, HappWifiStatus.notOnWifi);
      expect(happWifiStatusOf({'ssid': ''}).status, HappWifiStatus.notOnWifi);
    });
  });

  group('connection check', () {
    test('no chain: the hop step is ok, not «: подключение…» forever', () {
      final h = _health(pick: 196);
      expect(healthSheetHopState(null, h), HealthState.ok);
    });
    test('card hop states map as before', () {
      final h = _health(pick: 196, chain: ChainStatus.extraSecurity);
      expect(healthSheetHopState(StepStatus.connected, h), HealthState.ok);
      expect(healthSheetHopState(StepStatus.failed, h), HealthState.failed);
      expect(healthSheetHopState(StepStatus.waiting, h), HealthState.blocked);
      expect(healthSheetHopState(StepStatus.connecting, h), HealthState.pending);
    });
    test('pending turns failed after the deadline, nothing else changes', () {
      expect(healthWithDeadline(HealthState.pending, const Duration(seconds: 9)), HealthState.pending);
      expect(healthWithDeadline(HealthState.pending, healthCheckTimeout), HealthState.failed);
      expect(healthWithDeadline(HealthState.ok, const Duration(minutes: 1)), HealthState.ok);
      expect(healthWithDeadline(HealthState.blocked, const Duration(minutes: 1)), HealthState.blocked);
      expect(healthCheckTimeout, lessThanOrEqualTo(const Duration(seconds: 10)));
    });
    test('an untested pick ends as failed after the deadline', () {
      final h = _health(pick: 0);
      expect(h.pick, HealthState.pending);
      expect(healthWithDeadline(h.pick, const Duration(seconds: 11)), HealthState.failed);
    });
  });

  group('find the fastest', () {
    test('ranks by speed, failures last in test order', () {
      final tags = ['a', 'b', 'c', 'd', 'e'];
      final ranked = happRankSpeeds(tags, {'a': 1000, 'b': -1, 'c': 5000, 'd': 3000});
      expect(ranked.map((r) => r.tag).toList(), ['c', 'd', 'a', 'b', 'e']);
      expect(ranked.last.bps, 0);
      expect(happSpeedWinner(ranked), 'c');
    });
    test('no winner when every server failed', () {
      final ranked = happRankSpeeds(['a', 'b'], {'a': -1, 'b': 0});
      expect(happSpeedWinner(ranked), isNull);
      expect(happSpeedWinner(const []), isNull);
    });
    test('progress label', () {
      expect(happSpeedProgressLabel(2, 5), '2/5');
    });
    test('the next server waits for the core, at most the drain timeout', () {
      expect(happSpeedMayStartNext(testing: false, waited: Duration.zero), isTrue);
      expect(happSpeedMayStartNext(testing: true, waited: const Duration(seconds: 5)), isFalse);
      expect(happSpeedMayStartNext(testing: true, waited: happSpeedDrainTimeout), isTrue);
    });
    test('a server can never take longer than its two steps allow', () {
      expect(happSpeedServerTimeout, greaterThan(happSpeedStepTimeout));
      expect(happSpeedServerTimeout, lessThan(happSpeedStepTimeout * 3));
    });
  });
}
