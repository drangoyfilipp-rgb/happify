import 'dart:convert';

// «Тест скорости»: a download through one server that spends as little traffic as it can.
// Two steps through the core's download test: a first megabyte tells the speed; a slow link is
// done there (it took ~3 s or more, the speed is known); otherwise a second step sized for ~3 s at
// that speed, at most 4 MB, so the whole test moves 2–5 MB and never more. Pure, for the tests.

const int happSpeedFirstBytes = 1 << 20;
const int happSpeedMaxTotal = 5 << 20;
const int happSpeedMinTotal = 2 << 20;
const Duration happSpeedTarget = Duration(seconds: 3);

/// How much the second step moves after the first ([firstBytes] in [firstTook] at
/// [firstSpeed] bytes/s as the core measured it); null when the first one is enough: it took
/// [happSpeedTarget] or more, or it failed.
int? happSpeedSecondStep({required int firstBytes, required Duration firstTook, required int firstSpeed}) {
  if (firstSpeed <= 0) return null;
  if (firstTook >= happSpeedTarget) return null;
  final want = firstSpeed * happSpeedTarget.inMilliseconds ~/ 1000;
  final room = happSpeedMaxTotal - firstBytes;
  final atLeast = happSpeedMinTotal - firstBytes;
  return want.clamp(atLeast, room);
}

/// The speed the badge shows: the second step's when it ran (a warmed-up connection, more data),
/// else the first's. Bytes/s; 0 when neither worked.
int happSpeedResult({required int first, int? second}) {
  if (second != null && second > 0) return second;
  return first > 0 ? first : 0;
}

/// The core's download test answers at once and downloads in the background, marking the server
/// `downloadTesting` while it runs: a step waits for that mark to go away, at most this long.
const Duration happSpeedStepTimeout = Duration(seconds: 35);

/// How long a step may take to show the mark at all; past it, a step that never showed it and
/// brought no new speed did not run.
const Duration happSpeedStartGrace = Duration(seconds: 3);

const Duration happSpeedPollEvery = Duration(milliseconds: 150);

/// One look at the server while a step runs. [sawTesting]: the mark was seen during this step;
/// [testing]: it is there now; [speed]/[before]: the server's speed now and before the step
/// (null: the server is not in the list); [elapsed]: since the step started.
/// Returns null to keep waiting; otherwise the step is over: [bps] its speed (0: failed or timed
/// out), [running] true when the core is still downloading (timed out), so nothing else may start.
({int bps, bool running})? happSpeedPoll({
  required bool sawTesting,
  required bool testing,
  required int? speed,
  required int? before,
  required Duration elapsed,
}) {
  final got = speed != null && speed > 0 ? speed : 0;
  if (testing) {
    return elapsed >= happSpeedStepTimeout ? (bps: 0, running: true) : null;
  }
  if (sawTesting) return (bps: got, running: false);
  // the mark not seen yet: done so fast it was missed (a new speed), or not started yet
  if (got > 0 && speed != before) return (bps: got, running: false);
  return elapsed >= happSpeedStartGrace ? (bps: 0, running: false) : null;
}

/// How long a result is shown.
const Duration happSpeedFresh = Duration(hours: 1);

/// The saved results of a subscription ("happify_speed_<profile id>"): tag → (bytes/s, when).
Map<String, ({int bps, DateTime at})> happReadSpeedCache(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return const {};
    final out = <String, ({int bps, DateTime at})>{};
    for (final e in json.entries) {
      final v = e.value;
      if (e.key is! String || v is! List || v.length != 2 || v[0] is! num || v[1] is! num) continue;
      out[e.key as String] = (bps: (v[0] as num).toInt(), at: DateTime.fromMillisecondsSinceEpoch((v[1] as num).toInt()));
    }
    return out;
  } on FormatException {
    return const {};
  }
}

/// [cache] with the results older than [happSpeedFresh] dropped and [fresh] added, encoded.
String happWriteSpeedCache(Map<String, ({int bps, DateTime at})> cache, Map<String, int> fresh, DateTime now) {
  final out = <String, List<int>>{
    for (final e in cache.entries)
      if (now.difference(e.value.at) < happSpeedFresh) e.key: [e.value.bps, e.value.at.millisecondsSinceEpoch],
  };
  for (final e in fresh.entries) {
    out[e.key] = [e.value, now.millisecondsSinceEpoch];
  }
  return jsonEncode(out);
}

/// The badge of [tag]: bytes/s when a result younger than [happSpeedFresh] exists.
int? happFreshSpeed(Map<String, ({int bps, DateTime at})> cache, String tag, DateTime now) {
  final r = cache[tag];
  if (r == null || r.bps <= 0 || now.difference(r.at) >= happSpeedFresh) return null;
  return r.bps;
}

/// «↓ 12 Мбит/с»: whole megabits from 10, one decimal below.
String happSpeedLabel(int bps, {required bool ru}) {
  final mbit = bps * 8 / 1e6;
  final n = mbit >= 10 ? mbit.round().toString() : mbit.toStringAsFixed(1).replaceAll('.', ru ? ',' : '.');
  return ru ? '↓ $n Мбит/с' : '↓ $n Mbit/s';
}

/// The [count] servers with the lowest ping that answered, fastest first.
List<String> happTopByPing(Map<String, int?> pings, {int count = 5}) {
  final ok = [
    for (final e in pings.entries)
      if (e.value != null && e.value! > 0 && e.value! < 65000) e,
  ]..sort((a, b) => a.value!.compareTo(b.value!));
  return [for (final e in ok.take(count)) e.key];
}

// «Найти самый быстрый»: the top servers by ping, one after another; one that fails or times out
// is marked ✕ and the rest go on. Never two tests at once: the next waits for the core's
// `downloadTesting` mark to clear, at most [happSpeedDrainTimeout].

/// The longest one server may take, both steps included; past it the server is ✕.
const Duration happSpeedServerTimeout = Duration(seconds: 80);

/// How long the next server waits for the core to finish the last download.
const Duration happSpeedDrainTimeout = Duration(seconds: 30);

/// Whether the next server may start: the core is no longer downloading, or it has been waited
/// for [happSpeedDrainTimeout].
bool happSpeedMayStartNext({required bool testing, required Duration waited}) =>
    !testing || waited >= happSpeedDrainTimeout;

/// «2/5»: the server being tested ([index] from 1) of [total].
String happSpeedProgressLabel(int index, int total) => '$index/$total';

/// The servers ranked for the result sheet: the measured ones fastest first, then the ones that
/// failed or were not tested (bps 0) in the order they were tested.
List<({String tag, int bps})> happRankSpeeds(List<String> tags, Map<String, int> results) {
  final ok = [
    for (final t in tags)
      if ((results[t] ?? 0) > 0) (tag: t, bps: results[t]!),
  ]..sort((a, b) => b.bps.compareTo(a.bps));
  return [
    ...ok,
    for (final t in tags)
      if ((results[t] ?? 0) <= 0) (tag: t, bps: 0),
  ];
}

/// The fastest measured server; null when none worked.
String? happSpeedWinner(List<({String tag, int bps})> ranked) =>
    ranked.isNotEmpty && ranked.first.bps > 0 ? ranked.first.tag : null;
