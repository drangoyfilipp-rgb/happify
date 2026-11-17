import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happ_home.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the flag of a server name and the name without it', () {
    expect(happFlagCode('🇩🇪 DoDoVPN | VLESS'), 'DE');
    expect(happFlagCode('Антиглушилка'), isNull);
    expect(happCleanName('🇩🇪 DoDoVPN | VLESS'), 'DoDoVPN | VLESS');
    expect(happCleanName('Paris §hide§1'), 'Paris');
  });

  test("servers of a config with Happ's subtitle", () {
    final config = jsonEncode({
      'outbounds': [
        {'type': 'selector', 'tag': 'select'},
        {
          'type': 'vless',
          'tag': '🇸🇪 Stockholm',
          'server': 'example.com',
          'server_port': 443,
          'tls': {
            'enabled': true,
            'reality': {'enabled': true},
          },
        },
        {
          'type': 'vless',
          'tag': 'WS',
          'server': 'example.org',
          'server_port': 8443,
          'transport': {'type': 'ws'},
          'tls': {'enabled': true},
        },
        {'type': 'hysteria2', 'tag': 'Hy', 'server': 'h.example', 'server_port': 1234, 'tls': {'enabled': true}},
        {'type': 'direct', 'tag': 'direct'},
      ],
    });
    final servers = happServersOf(config);
    expect(servers.map((s) => s.tag), ['🇸🇪 Stockholm', 'WS', 'Hy']);
    expect(servers[0].subtitle, 'VLESS / TCP / REALITY | JSON');
    expect(servers[1].subtitle, 'VLESS / WS / TLS | JSON');
    expect(servers[2].subtitle, 'HYSTERIA / HYSTERIA / TLS | JSON');
    expect(servers[0].port, 443);
    expect(servers.map((s) => s.detail), ['Reality', 'WS', 'TLS']);
  });

  test("the core's delay: a fresh test, a timeout, the sort delay, or nothing", () {
    expect(happCoreDelay(OutboundInfo(tag: 'a', urlTestDelay: 187)), 187);
    expect(happCoreDelay(OutboundInfo(tag: 'a', urlTestDelay: 65535)), -1);
    expect(happCoreDelay(OutboundInfo(tag: 'a', urlTestDelay: 0, sortDelay: 240)), 240);
    expect(happCoreDelay(OutboundInfo(tag: 'a')), isNull);
  });

  test('the ping cache reads what the core measured and ignores junk', () async {
    SharedPreferences.setMockInitialValues({
      'happify_ping_p1': jsonEncode({'DE': 95, 'NL': -1}),
      'happify_ping_p2': '{broken',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(happReadPingCache(prefs, 'p1'), {'DE': 95, 'NL': -1});
    expect(happReadPingCache(prefs, 'p2'), isEmpty);
    expect(happReadPingCache(prefs, 'none'), isEmpty);
    expect(happReadPingCache(null, 'p1'), isEmpty);
  });
}
