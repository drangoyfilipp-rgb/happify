// What the core's log says about connections that failed: the passive signal of «Автопереключение
// при сбое» and the records of «Диагностика». The core (sing-box 1.13) writes, at the error level
// the app already listens to:
//   ERROR [3263484049 10.0s] connection: open connection to www.google.com:443 using outbound/vless[Прага]: dial tcp 1.2.3.4:443: i/o timeout
//   ERROR [123 0ms] connection: open packet connection to 8.8.8.8:53 using outbound/direct[direct]: …
//   ERROR [12 3.1s] connection: connection download closed: read tcp …: connection reset by peer
// Nothing here costs traffic: the lines are read as they come.

enum HappFailureKind { timeout, reset, refused, dns, tls, other }

class HappCoreFailure {
  const HappCoreFailure({
    required this.kind,
    required this.detail,
    this.host,
    this.port,
    this.outboundType,
    this.outboundTag,
    this.connectionId,
  });

  final HappFailureKind kind;

  /// The error as the core wrote it, after the destination.
  final String detail;

  /// The site (a domain, or an IP when the domain is unknown); null when the line does not say.
  final String? host;
  final int? port;

  /// "direct", "vless", "hysteria2"…; null when the line does not say.
  final String? outboundType;
  final String? outboundTag;

  /// The core's id of the connection, the number after "[".
  final String? connectionId;

  bool get direct => outboundType == 'direct' || outboundType == 'block';

  /// Whether it says anything about the tunnel: failed through a proxy (not direct, not a
  /// connection the app or the site closed normally).
  bool get viaProxy => outboundType != null && !direct;
}

final _open = RegExp(r'open (?:packet )?connection to (\S+?) using outbound/([\w.-]+)\[(.*?)\]: (.*)$');
final _listen = RegExp(r'listen packet connection using outbound/([\w.-]+)\[(.*?)\]: (.*)$');
final _closed = RegExp(r'connection (?:upload|download) (?:closed|handshake): (.*)$');
final _dns = RegExp(r'(?:exchange failed for|lookup) ([^\s:]+?)\.?(?: IN \w+)?: (.*)$');
final _id = RegExp(r'\[(\d+)(?:\s[^\]]*)?\]');

/// The failure a core log line reports; null for any other line.
HappCoreFailure? happParseCoreFailure(String line) {
  final id = _id.firstMatch(line)?.group(1);
  final open = _open.firstMatch(line);
  if (open != null) {
    final (host, port) = _splitDestination(open.group(1)!);
    final detail = open.group(4)!;
    return HappCoreFailure(
      kind: happClassifyError(detail),
      detail: detail,
      host: host,
      port: port,
      outboundType: open.group(2),
      outboundTag: open.group(3),
      connectionId: id,
    );
  }
  final listen = _listen.firstMatch(line);
  if (listen != null) {
    final detail = listen.group(3)!;
    return HappCoreFailure(
      kind: happClassifyError(detail),
      detail: detail,
      outboundType: listen.group(1),
      outboundTag: listen.group(2),
      connectionId: id,
    );
  }
  final closed = _closed.firstMatch(line);
  if (closed != null) {
    final detail = closed.group(1)!;
    final kind = happClassifyError(detail);
    // a closed connection is only a failure when it was cut, not when it ended
    if (kind != HappFailureKind.reset && kind != HappFailureKind.timeout) return null;
    return HappCoreFailure(kind: kind, detail: detail, connectionId: id);
  }
  if (line.contains('dns') || line.contains('lookup')) {
    final dns = _dns.firstMatch(line);
    if (dns != null) {
      return HappCoreFailure(kind: HappFailureKind.dns, detail: dns.group(2)!, host: dns.group(1), connectionId: id);
    }
  }
  return null;
}

/// What kind of error [detail] is.
HappFailureKind happClassifyError(String detail) {
  final d = detail.toLowerCase();
  if (d.contains('no such host') || d.contains('lookup ') || d.contains('dns') || d.contains('name resolution')) {
    return HappFailureKind.dns;
  }
  if (d.contains('timeout') || d.contains('timed out') || d.contains('deadline exceeded')) return HappFailureKind.timeout;
  if (d.contains('refused')) return HappFailureKind.refused;
  if (d.contains('reset') || d.contains('broken pipe') || d.contains('connection aborted') || d.endsWith('eof')) {
    return HappFailureKind.reset;
  }
  if (d.contains('tls') || d.contains('handshake') || d.contains('certificate') || d.contains('reality')) {
    return HappFailureKind.tls;
  }
  return HappFailureKind.other;
}

(String?, int?) _splitDestination(String dest) {
  var d = dest;
  // several addresses of one name: "[1.2.3.4,5.6.7.8]"
  if (d.startsWith('[') && d.endsWith(']') && d.contains(',')) {
    return (d.substring(1, d.length - 1).split(',').first, null);
  }
  int? port;
  final colon = d.lastIndexOf(':');
  if (colon > 0 && !d.substring(colon + 1).contains(']')) {
    final p = int.tryParse(d.substring(colon + 1));
    if (p != null) {
      port = p;
      d = d.substring(0, colon);
    }
  }
  if (d.startsWith('[') && d.endsWith(']')) d = d.substring(1, d.length - 1);
  return (d.isEmpty ? null : d, port);
}

/// The package in a connection's "processPath" as the core reports it ("org.telegram.messenger
/// (org.telegram.messenger)", or a user id when the app is unknown); null when there is none.
String? happPackageOfProcessPath(String? path) {
  if (path == null || path.isEmpty) return null;
  final name = path.split(' (').first.trim();
  if (name.isEmpty || int.tryParse(name) != null || name.contains('/')) return null;
  return name;
}
