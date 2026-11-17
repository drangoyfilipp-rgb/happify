import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happify_server_titles.dart';

void main() {
  HappTitleInput s(String tag, String name, String type, [String detail = '']) =>
      (tag: tag, name: name, type: type, detail: detail);

  test('a repeated name gets its protocol, a unique one stays as it is', () {
    final titles = happServerTitles([
      s('a', 'Стокгольм #1', 'vless', 'Reality'),
      s('b', 'Стокгольм #1 ', 'hysteria2', 'TLS'),
      s('c', 'Франкфурт #1', 'vmess', 'WS'),
      s('d', 'Франкфурт #1', 'trojan', 'TLS'),
      s('e', 'Амстердам', 'vless', 'Reality'),
    ]);
    expect(titles['a'], 'Стокгольм #1 | VLESS');
    expect(titles['b'], 'Стокгольм #1 | Hysteria2');
    expect(titles['c'], 'Франкфурт #1 | VMess');
    expect(titles['d'], 'Франкфурт #1 | Trojan');
    expect(titles['e'], 'Амстердам');
  });

  test('the same name and protocol get the transport too; fully identical stay identical', () {
    final titles = happServerTitles([
      s('a', 'Paris', 'vless', 'WS'),
      s('b', 'Paris', 'vless', 'Reality'),
      s('c', 'Paris', 'vless', 'XHTTP'),
      s('d', 'Paris', 'shadowsocks', 'TCP'),
      s('e', 'Oslo', 'vless', 'WS'),
      s('f', 'Oslo', 'vless', 'WS'),
    ]);
    expect(titles['a'], 'Paris | VLESS WS');
    expect(titles['b'], 'Paris | VLESS Reality');
    expect(titles['c'], 'Paris | VLESS XHTTP');
    expect(titles['d'], 'Paris | Shadowsocks');
    expect(titles['e'], titles['f']);
  });

  test('a name that already says its protocol is left alone', () {
    final titles = happServerTitles([
      s('a', 'DoDoVPN | Hysteria | TikTok', 'hysteria2', 'TLS'),
      s('b', 'DoDoVPN | Hysteria | TikTok', 'vless', 'Reality'),
      s('c', 'Russia', 'shadowsocks'),
      s('d', 'Russia', 'tuic'),
    ]);
    expect(titles['a'], 'DoDoVPN | Hysteria | TikTok');
    expect(titles['b'], 'DoDoVPN | Hysteria | TikTok | VLESS');
    expect(titles['c'], 'Russia | Shadowsocks');
    expect(titles['d'], 'Russia | TUIC');
  });

  test('labels and transports', () {
    expect(happProtocolLabel('wireguard'), 'WireGuard');
    expect(happProtocolLabel('ssh'), 'SSH');
    expect(happProtocolLabel('hysteria'), 'Hysteria');
    expect(happTransportDetail({'type': 'vless', 'transport': {'type': 'ws'}, 'tls': {'enabled': true}}), 'WS');
    expect(happTransportDetail({'type': 'vless', 'tls': {'enabled': true, 'reality': {'enabled': true}}}), 'Reality');
    expect(happTransportDetail({'type': 'vless'}), 'TCP');
  });
}
