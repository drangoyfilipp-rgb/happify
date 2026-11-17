import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_update/model/install_kind.dart';
import 'package:hiddify/features/happ/happ_self_update.dart';

Map<String, dynamic> _release(String tag, {List<String> assets = const [], bool draft = false, bool pre = false}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': pre,
  'html_url': 'https://github.com/drangoyfilipp-rgb/Happ/releases/tag/$tag',
  'published_at': '2026-11-17T08:00:00Z',
  'assets': [
    for (final a in assets) {'name': a, 'browser_download_url': 'https://x/$tag/$a', 'size': 10},
  ],
};

void main() {
  group('build-N tag', () {
    test('parses N, rejects other tags', () {
      expect(happBuildFromTag('build-43'), 43);
      expect(happBuildFromTag(' build-7 '), 7);
      expect(happBuildFromTag('v5.5.5'), isNull);
      expect(happBuildFromTag('build-'), isNull);
      expect(happBuildFromTag('build-4x'), isNull);
      expect(happBuildFromTag(null), isNull);
    });

    test('release JSON: version and build number are N; drafts, pre-releases, other tags skipped', () {
      final r = happParseRelease(_release('build-44', assets: ['app-release.apk']))!;
      expect(r.version, '44');
      expect(r.buildNumber, '44');
      expect(r.releaseTag, 'build-44');
      expect(r.url, contains('build-44'));
      expect(r.assets.single.url, 'https://x/build-44/app-release.apk');
      expect(happParseRelease(_release('build-44', draft: true)), isNull);
      expect(happParseRelease(_release('build-44', pre: true)), isNull);
      expect(happParseRelease(_release('v5.5.5')), isNull);
    });
  });

  group('comparison', () {
    test('only a strictly newer known build', () {
      expect(happIsNewerBuild(remote: 44, current: 43), isTrue);
      expect(happIsNewerBuild(remote: 43, current: 43), isFalse);
      expect(happIsNewerBuild(remote: 42, current: 43), isFalse);
      expect(happIsNewerBuild(remote: null, current: 43), isFalse);
      expect(happIsNewerBuild(remote: 44, current: null), isFalse);
    });

    test('running build number', () {
      expect(happRunningBuild('43'), 43);
      expect(happRunningBuild(''), isNull);
      expect(happRunningBuild('0'), isNull);
      expect(happRunningBuild('abc'), isNull);
    });
  });

  group('APK asset by ABI', () {
    const both = ['app-arm64-v8a-release.apk', 'app-release.apk'];
    test('device ABI first, else universal', () {
      expect(happPickApkName(both, ['arm64-v8a', 'armeabi-v7a']), 'app-arm64-v8a-release.apk');
      expect(happPickApkName(both, ['armeabi-v7a', 'armeabi']), 'app-release.apk');
      expect(happPickApkName(both, ['x86_64']), 'app-release.apk');
      expect(happPickApkName(both, []), 'app-release.apk');
      expect(happPickApkName(['app-arm64-v8a-release.apk'], ['armeabi-v7a']), isNull);
      expect(happPickApkName(['app-arm64-v8a-release.apk'], ['arm64-v8a']), 'app-arm64-v8a-release.apk');
    });

    test('the Android install picks Happify APKs from a build-N release', () {
      final r = happParseRelease(_release('build-44', assets: both))!;
      expect(InstallKind.androidApk.assetIn(r, abis: ['arm64-v8a'])?.name, 'app-arm64-v8a-release.apk');
      expect(InstallKind.androidApk.assetIn(r, abis: ['armeabi-v7a'])?.name, 'app-release.apk');
    });
  });

  group('6 h throttle', () {
    const h = 3600 * 1000;
    const now = 100 * h;
    test('due when never checked, after 6 h, or the clock went back', () {
      expect(happUpdateCheckDue(0, now), isTrue);
      expect(happUpdateCheckDue(now - 6 * h, now), isTrue);
      expect(happUpdateCheckDue(now - 6 * h + 1, now), isFalse);
      expect(happUpdateCheckDue(now - h, now), isFalse);
      expect(happUpdateCheckDue(now + h, now), isTrue);
    });
  });
}
