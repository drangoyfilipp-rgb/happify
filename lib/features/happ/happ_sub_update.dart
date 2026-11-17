// Build-42: the subscription auto-update, the rules without I/O (test/features/happ/happify_build42_test.dart).

/// How early a check may come and still count: the periodic check and the update itself take a few
/// seconds, so an "hourly" update checked every 15 minutes must not miss its slot by those seconds
/// and wait a whole extra round.
const happUpdateSlack = Duration(minutes: 1);

/// Whether the periodic update check that ran last at [previousRun] (its start) runs again at [now].
bool happUpdateCheckDue(DateTime? previousRun, DateTime now, Duration interval) =>
    previousRun == null || now.difference(previousRun) >= interval - happUpdateSlack;

/// Whether a subscription last updated at [lastUpdate] is updated on its own at [now], every
/// [interval] (null or ≤ 0: auto-update off).
bool happProfileUpdateDue({required Duration? interval, required DateTime lastUpdate, required DateTime now}) =>
    interval != null && interval > Duration.zero && now.difference(lastUpdate) >= interval - happUpdateSlack;

/// The interval the app really updates by: [own] (the card's «Автообновление»), longer while
/// «Экономия трафика» is in effect ([saving]) as [stretch] says. Null: off.
Duration? happEffectiveUpdateEvery(Duration? own, {required bool saving, required Duration Function(Duration) stretch}) {
  if (own == null || own <= Duration.zero) return null;
  return saving ? stretch(own) : own;
}

/// Whether an update changed what the running tunnel uses: the saved config ([before]/[after], the
/// file's bytes; null when there was none) or the subscription's overrides. Only then is the VPN
/// reloaded: a reload drops every open connection, which an unchanged hourly update must not do.
bool happSubUpdateNeedsReload({
  required List<int>? before,
  required List<int>? after,
  required String overrideBefore,
  required String overrideAfter,
}) {
  if (overrideBefore != overrideAfter) return true;
  if (before == null || after == null) return true;
  if (before.length != after.length) return true;
  for (var i = 0; i < before.length; i++) {
    if (before[i] != after[i]) return true;
  }
  return false;
}
