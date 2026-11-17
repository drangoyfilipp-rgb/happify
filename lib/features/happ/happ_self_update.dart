import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';

/// Happify updates itself from its own releases: CI tags each one build-N and builds the APK
/// with --build-number N, so the running app's build number (versionCode) is that N.
const happReleasesLatestApiUrl = 'https://api.github.com/repos/drangoyfilipp-rgb/Happ/releases/latest';
const happReleasesPageUrl = 'https://github.com/drangoyfilipp-rgb/Happ/releases/latest';

/// The automatic check runs at most this often.
const happUpdateCheckEvery = Duration(hours: 6);

final _buildTag = RegExp(r'^build-(\d+)$');

/// N of a build-N tag; null for any other tag.
int? happBuildFromTag(String? tag) {
  final match = _buildTag.firstMatch((tag ?? '').trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// The running app's build number; null when it is not a positive number.
int? happRunningBuild(String buildNumber) {
  final n = int.tryParse(buildNumber.trim());
  return n == null || n <= 0 ? null : n;
}

/// Whether [remote] is a newer build than [current]; never when either is unknown.
bool happIsNewerBuild({required int? remote, required int? current}) =>
    remote != null && current != null && remote > current;

/// Whether the automatic check is due: never checked, [every] passed, or the clock went back.
bool happUpdateCheckDue(int lastCheckMs, int nowMs, {Duration every = happUpdateCheckEvery}) =>
    lastCheckMs <= 0 || nowMs < lastCheckMs || nowMs - lastCheckMs >= every.inMilliseconds;

/// The release of GitHub's releases/latest JSON; null for a draft, a pre-release or a tag that is
/// no build-N. Its version and build number are both N.
RemoteVersionEntity? happParseRelease(Map<String, dynamic> json) {
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final tag = (json['tag_name'] as String? ?? '').trim();
  final build = happBuildFromTag(tag);
  if (build == null) return null;
  return RemoteVersionEntity(
    version: '$build',
    buildNumber: '$build',
    releaseTag: tag,
    preRelease: false,
    url: json['html_url'] as String? ?? happReleasesPageUrl,
    publishedAt: DateTime.tryParse(json['published_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    flavor: Environment.prod,
    assets: [
      for (final asset in json['assets'] as List? ?? const [])
        if (asset case {'name': final String name, 'browser_download_url': final String url})
          ReleaseAsset(name: name, url: url, size: (asset['size'] as num?)?.toInt() ?? 0),
    ],
  );
}

const _apkByAbi = {
  'arm64-v8a': 'app-arm64-v8a-release.apk',
  'armeabi-v7a': 'app-armeabi-v7a-release.apk',
  'x86_64': 'app-x86_64-release.apk',
};
const happUniversalApk = 'app-release.apk';

/// The APK for the device's preferred ABI (the first of [abis]), else the universal one; null when
/// the release has neither.
String? happPickApkName(Iterable<String> names, List<String> abis) {
  final all = names.toSet();
  final own = abis.isEmpty ? null : _apkByAbi[abis.first];
  if (own != null && all.contains(own)) return own;
  return all.contains(happUniversalApk) ? happUniversalApk : null;
}

ReleaseAsset? happPickApk(RemoteVersionEntity release, List<String> abis) {
  final name = happPickApkName(release.assets.map((e) => e.name), abis);
  return name == null ? null : release.asset(name);
}
