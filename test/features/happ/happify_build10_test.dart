import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/happify_routing.dart';

void main() {
  group('clipboard fingerprint', () {
    test('is stable and does not contain the link', () {
      const link = 'https://sub.example.com/abc?token=SECRET';
      expect(clipHash(link), clipHash(link));
      expect(clipHash(link).contains('SECRET'), isFalse);
      expect(clipHash(link) == clipHash('$link#2'), isFalse);
    });

    test('tells a fingerprint from an old saved link', () {
      expect(isClipHash(clipHash('anything')), isTrue);
      expect(isClipHash('https://sub.example.com/abc'), isFalse);
      expect(isClipHash(''), isFalse);
    });
  });

  group('routing download', () {
    test('only https is allowed', () {
      expect(happRoutingUrlAllowed('https://example.com/r.json'), isTrue);
      expect(happRoutingUrlAllowed('http://example.com/r.json'), isFalse);
      expect(happRoutingUrlAllowed('file:///etc/passwd'), isFalse);
      expect(happRoutingUrlAllowed('not a url'), isFalse);
    });

    test('http links are refused without a request', () async {
      expect(await fetchRoutingText('http://example.com/r.json'), '');
    });
  });

  group('routing profiles', () {
    test('torrents switch removes only the torrent block', () {
      final profile = {
        'BlockSites': ['geosite:torrent', 'geosite:ads'],
      };
      expect(happWithTorrents(profile, false)['BlockSites'], ['geosite:torrent', 'geosite:ads']);
      expect(happWithTorrents(profile, true)['BlockSites'], ['geosite:ads']);
    });

    test('empty or broken input gives no profile', () {
      expect(parseHappRouting(''), isNull);
      expect(parseHappRouting('{not json'), isNull);
    });

    test('plain JSON profile is read', () {
      final p = parseHappRouting(jsonEncode({'DirectSites': ['geosite:ru']}));
      expect(p, isNotNull);
      expect(happRoutingRules(p!), isNotEmpty);
    });
  });
}
