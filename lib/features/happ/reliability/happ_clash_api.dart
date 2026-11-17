import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The core's own direct way out, as hiddify-core names it (OutboundDirectTag in
/// v2/config/builder.go); plain "direct" is no outbound there and the API answers 404.
const happCoreDirectTag = 'direct §hide§';

/// The core's local control API (127.0.0.1, the key in "web-secret"), for a probe through one
/// server and for the list of open connections. Local only: nothing here leaves the phone except
/// the probe's own tiny request (an empty 204 page) through the server tested.
class HappClashApi {
  HappClashApi({required this.port, required this.secret});

  final int port;
  final String secret;

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (_) => 'DIRECT';

  /// One HTTP probe of [url] through [tag] (a server, a group, or [happCoreDirectTag]). The delay in ms when
  /// it answered; null when it did not (timeout, refused, error). Throws [HappClashUnavailable]
  /// when the API itself cannot be asked (the core is not running, or the key is wrong): that says
  /// nothing about the server.
  Future<int?> delay(String tag, {required String url, Duration timeout = const Duration(seconds: 5)}) async {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      pathSegments: ['proxies', tag, 'delay'],
      queryParameters: {'url': url, 'timeout': '${timeout.inMilliseconds}'},
    );
    final client = _client();
    try {
      final request = await client.getUrl(uri);
      if (secret.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      final response = await request.close().timeout(timeout + const Duration(seconds: 3));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
      switch (response.statusCode) {
        case 200:
          final json = jsonDecode(body);
          final d = json is Map ? json['delay'] : null;
          return d is num && d > 0 ? d.toInt() : null;
        // the core's answers for a probe that failed: timed out, or an error on the way
        case 504 || 503 || 408 || 502:
          return null;
        default:
          // 401 (wrong key), 404 (no such outbound), anything else: the API, not the server
          throw HappClashUnavailable('HTTP ${response.statusCode}');
      }
    } on HappClashUnavailable {
      rethrow;
    } on SocketException catch (e) {
      throw HappClashUnavailable(e.message);
    } on HttpException catch (e) {
      throw HappClashUnavailable(e.message);
    } on TimeoutException {
      // the API took the request and never answered in time: the probe hangs on the server
      return null;
    } on FormatException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The open connections, as the core lists them (each a map with "metadata", "chains"…).
  Future<List<Map<String, dynamic>>> connections() async {
    final client = _client();
    try {
      final request = await client.getUrl(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/connections'));
      if (secret.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HappClashUnavailable('HTTP ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
      final json = jsonDecode(body);
      final list = json is Map ? json['connections'] : null;
      return [
        for (final c in list is List ? list : const [])
          if (c is Map<String, dynamic>) c,
      ];
    } on SocketException catch (e) {
      throw HappClashUnavailable(e.message);
    } on TimeoutException {
      throw const HappClashUnavailable('timeout');
    } on FormatException {
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}

class HappClashUnavailable implements Exception {
  const HappClashUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'clash API unavailable: $reason';
}
