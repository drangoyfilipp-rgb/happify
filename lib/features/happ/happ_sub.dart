import 'dart:convert';

/// Happ subscription extensions (announce, sub-info, sub-expire, links).
abstract class HappSub {
  static const headerKeys = [
    'announce',
    'sub-info-color',
    'sub-info-text',
    'sub-info-button-text',
    'sub-info-button-link',
    'sub-expire',
    'sub-expire-button-link',
    'fallback-url',
    'new-url',
    'new-domain',
    'change-user-agent',
    'routing',
    'subscription-autoconnect',
    'subscription-autoconnect-type',
    'subscription-ping-onopen-enabled',
    'notification-subs-expire',
    'hide-settings',
    'per-app-proxy-mode',
    'per-app-proxy-list',
  ];

  static bool isOn(dynamic v) {
    final s = v?.toString().trim().toLowerCase();
    return s == 'true' || s == '1';
  }

  /// Plain text or `base64:...`.
  static String? text(dynamic v) {
    if (v == null) return null;
    var s = v.toString().trim();
    if (s.isEmpty || s == '0') return null;
    if (s.startsWith('base64:')) {
      try {
        s = utf8.decode(base64.decode(_pad(s.substring(7).trim())));
      } catch (_) {
        return null;
      }
    }
    return s.trim().isEmpty ? null : s.trim();
  }

  static String _pad(String b) {
    final r = b.length % 4;
    return r == 0 ? b : b + '=' * (4 - r);
  }

  static String? _tryB64(String s) {
    try {
      return utf8.decode(base64.decode(_pad(Uri.decodeComponent(s))));
    } catch (_) {
      try {
        return Uri.decodeComponent(s);
      } catch (_) {
        return s;
      }
    }
  }

  /// Rewrites the body of a subscription for the core:
  /// drops `happ://` service lines and turns `#title?serverDescription=B64`
  /// into `#title | description`.
  static String cleanBody(String text) {
    final out = <String>[];
    for (final line in text.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('happ://')) continue;
      final hash = line.indexOf('#');
      if (hash != -1) {
        final frag = line.substring(hash + 1);
        final m = RegExp(r'\?serverDescription=([^&\s]*)').firstMatch(frag);
        if (m != null) {
          final title = frag.substring(0, m.start);
          final desc = _tryB64(m.group(1) ?? '') ?? '';
          String decodedTitle;
          try {
            decodedTitle = Uri.decodeComponent(title);
          } catch (_) {
            decodedTitle = title;
          }
          final name = desc.trim().isEmpty ? decodedTitle : '$decodedTitle | ${desc.trim()}';
          out.add('${line.substring(0, hash)}#${Uri.encodeComponent(name)}');
          continue;
        }
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// A new subscription url from `new-url` or `new-domain`, or null.
  static String? movedUrl(String current, Map<String, dynamic>? headers) {
    if (headers == null) return null;
    final newUrl = headers['new-url']?.toString().trim();
    if (newUrl != null && newUrl.startsWith('https://') && newUrl != current) return newUrl;
    final newDomain = headers['new-domain']?.toString().trim();
    if (newDomain != null && newDomain.isNotEmpty) {
      final uri = Uri.tryParse(current);
      if (uri != null && uri.host != newDomain && RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(newDomain)) {
        return uri.replace(host: newDomain).toString();
      }
    }
    return null;
  }

  static String? fallbackUrl(Map<String, dynamic>? headers) {
    final f = headers?['fallback-url']?.toString().trim();
    return (f != null && (f.startsWith('https://') || f.startsWith('http://'))) ? f : null;
  }

  static String? userAgent(Map<String, dynamic>? headers) {
    final ua = headers?['change-user-agent']?.toString().trim();
    return (ua == null || ua.isEmpty) ? null : ua;
  }
}
