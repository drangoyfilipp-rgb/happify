// Titles for servers whose names repeat inside one subscription, as Happ writes them:
// «Стокгольм #1 | VLESS» and «Стокгольм #1 | Hysteria2». Display only: tags, ping cache keys,
// pins and the selection keep using the server's tag.

/// A server as its row shows it: [name] is the title as displayed (without flag or hidden
/// suffix), [type] the sing-box type ("vless", "hysteria2"), [detail] its transport or security
/// ("WS", "Reality", "XHTTP"), empty when unknown.
typedef HappTitleInput = ({String tag, String name, String type, String detail});

/// A short readable protocol name: VLESS, VMess, Trojan, Shadowsocks, Hysteria, Hysteria2, TUIC,
/// WireGuard, SSH; anything else in capitals.
String happProtocolLabel(String type) => switch (type.trim().toLowerCase()) {
  'vless' => 'VLESS',
  'vmess' => 'VMess',
  'trojan' => 'Trojan',
  'shadowsocks' || 'ss' => 'Shadowsocks',
  'hysteria' => 'Hysteria',
  'hysteria2' || 'hy2' => 'Hysteria2',
  'tuic' => 'TUIC',
  'wireguard' || 'awg' || 'wg' => 'WireGuard',
  'ssh' => 'SSH',
  final t => t.toUpperCase(),
};

/// The words that already name the protocol inside a server's name.
List<String> _protocolWords(String type) => switch (type.trim().toLowerCase()) {
  'hysteria' || 'hysteria2' || 'hy2' => const ['hysteria', 'hysteria2', 'hy2'],
  'shadowsocks' || 'ss' => const ['shadowsocks', 'ss'],
  'wireguard' || 'awg' || 'wg' => const ['wireguard', 'wg', 'awg', 'amneziawg'],
  final t => [t, happProtocolLabel(t).toLowerCase()],
};

/// Whether [name] already says the protocol, as a whole word: «Hysteria Стокгольм» does,
/// «Russia» does not say "ss".
bool happNameHasProtocol(String name, String type) {
  final lower = name.toLowerCase();
  for (final w in _protocolWords(type)) {
    if (w.isEmpty) continue;
    final re = RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(w)}(?![\\p{L}\\p{N}])', unicode: true);
    if (re.hasMatch(lower)) return true;
  }
  return false;
}

/// The transport, or else the security, of a sing-box outbound: "WS", "gRPC", "XHTTP",
/// "Reality", "TLS"; "TCP" when it has neither.
String happTransportDetail(Map<dynamic, dynamic> out) {
  final transport = out['transport'];
  final t = transport is Map ? transport['type'] : null;
  if (t is String && t.isNotEmpty && t.toLowerCase() != 'tcp') {
    return switch (t.toLowerCase()) {
      'ws' => 'WS',
      'grpc' => 'gRPC',
      'http' => 'HTTP',
      'httpupgrade' => 'HTTPUpgrade',
      'xhttp' => 'XHTTP',
      'quic' => 'QUIC',
      final x => x.toUpperCase(),
    };
  }
  final tls = out['tls'];
  if (tls is Map) {
    final reality = tls['reality'];
    if (reality is Map && reality['enabled'] == true) return 'Reality';
    if (tls['enabled'] == true) return 'TLS';
  }
  return 'TCP';
}

/// The title of each server, by tag. A name that occurs once stays as it is. A name that occurs
/// more than once gets « | <protocol>»; when name and protocol still repeat, « | <protocol>
/// <transport>». A name that already says its protocol is left alone.
Map<String, String> happServerTitles(Iterable<HappTitleInput> servers) {
  final list = servers.toList();
  String key(String name) => name.trim();
  final byName = <String, int>{};
  for (final s in list) {
    byName.update(key(s.name), (n) => n + 1, ifAbsent: () => 1);
  }
  final byNameProto = <String, int>{};
  for (final s in list) {
    byNameProto.update('${key(s.name)}\u0000${happProtocolLabel(s.type)}', (n) => n + 1, ifAbsent: () => 1);
  }
  return {
    for (final s in list)
      s.tag: () {
        final name = s.name.trim();
        if (s.type.trim().isEmpty || (byName[key(s.name)] ?? 0) < 2 || happNameHasProtocol(name, s.type)) {
          return s.name;
        }
        final proto = happProtocolLabel(s.type);
        final repeats = (byNameProto['${key(s.name)}\u0000$proto'] ?? 0) > 1;
        final detail = s.detail.trim();
        return repeats && detail.isNotEmpty ? '$name | $proto $detail' : '$name | $proto';
      }(),
  };
}
