// Build-41: how the card's ping runs while connected, and how «Найти самый быстрый» picks its
// servers. Pure, for the tests.
//
// The ping used to ask the core to test the whole selector group ('select'). hiddify-core runs a
// group's members as regular cycle tasks: behind the cycle's queue (10 workers, busy for seconds
// with servers that time out), dropped when the running cycle already queued them, one attempt
// with a 5 s timeout and no retry. Asked one server at a time, the core runs each test at once, in
// stages: tried again at 1 s and 3 s when an attempt fails, final at 10 s. So the card tests each
// server by its own tag, a few at a time.

/// Servers asked for at once; the next few go after [happPingWavePause].
const int happPingWaveSize = 6;
const Duration happPingWavePause = Duration(milliseconds: 1200);

/// How long a row waits for its result: the core's last stage is 10 s; a failure seen before that
/// may still be answered by the next attempt, so it is not taken as final until then.
const Duration happPingRowDeadline = Duration(seconds: 12);

/// The core's clock and the app's are the same device's; a little slack for rounding.
const Duration happPingClockSlack = Duration(milliseconds: 300);

/// [tags] in groups of [size], in order.
List<List<String>> happPingWaves(List<String> tags, {int size = happPingWaveSize}) {
  final out = <List<String>>[];
  for (var i = 0; i < tags.length; i += size) {
    out.add(tags.sublist(i, i + size > tags.length ? tags.length : i + size));
  }
  return out;
}

bool happValidDelay(int delay) => delay > 0 && delay < 65000;

/// Whether a row's ping is done: a working result measured since its test started, or its time is
/// up ([happPingRowDeadline]). A failure is not final before the deadline: the core shows a miss
/// after 1 s and tries again. [delay]: the core's url_test_delay (0: none, ≥65000: failed);
/// [testedAt]: its url_test_time; [startedAt]: when the app asked; null: not asked yet.
bool happPingRowDone({
  required int delay,
  required DateTime? testedAt,
  required DateTime? startedAt,
  required DateTime now,
  Duration deadline = happPingRowDeadline,
}) {
  if (startedAt == null) return false;
  final fresh = testedAt != null && !testedAt.isBefore(startedAt.subtract(happPingClockSlack));
  if (fresh && happValidDelay(delay)) return true;
  return now.difference(startedAt) >= deadline;
}

/// One server as «Найти самый быстрый» sees it.
typedef HappPingSample = ({String tag, bool isGroup, bool visible, int delay, DateTime? testedAt});

/// The [count] servers with the lowest ping measured since [since]: groups (lowest, balance),
/// hidden ones, and servers without a working ping (0, failed, ≥65000) left out; a ping from an
/// earlier run (the core sends it as 0) or from before [since] does not count. When no server has
/// a fresh one (the ping could not run), the working pings of this run are used instead.
List<String> happTopFreshByPing(List<HappPingSample> samples, DateTime since, {int count = 5}) {
  final usable = samples.where((s) => !s.isGroup && s.visible && happValidDelay(s.delay)).toList();
  final from = since.subtract(happPingClockSlack);
  var pool = usable.where((s) => s.testedAt != null && !s.testedAt!.isBefore(from)).toList();
  if (pool.isEmpty) pool = usable;
  pool.sort((a, b) {
    final c = a.delay.compareTo(b.delay);
    return c != 0 ? c : a.tag.compareTo(b.tag);
  });
  return [for (final s in pool.take(count)) s.tag];
}

/// The subtitle of the lowest/balance row while connected: «Сейчас: X» for the member the
/// group sends traffic through now ([selectedTag], the core's group_selected_tag; for balance the
/// member its latest connection went to), or the number of servers when it has none yet.
String happGroupNowLabel({
  required String? selectedTag,
  required String groupTag,
  required String Function(String tag) display,
  required int members,
  required bool ru,
}) {
  final tag = selectedTag?.trim() ?? '';
  if (tag.isNotEmpty && tag != groupTag) return ru ? 'Сейчас: ${display(tag)}' : 'Now: ${display(tag)}';
  if (members > 0) return ru ? 'Серверов: $members' : '$members servers';
  return ru ? 'Выбирает сервер…' : 'Picking a server…';
}

/// After a speed test that worked: the server answers, so a failed ping («—») is tested again.
bool happRepingAfterSpeed({required int bps, required int delay}) => bps > 0 && !happValidDelay(delay);
