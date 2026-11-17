import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long the core gets to take a server pick before the tap counts as failed.
const happSelectDeadline = Duration(seconds: 5);

/// The whole switch from a row (pick + waiting for the list to show it); the spinner never outlives it.
const happSwitchDeadline = Duration(seconds: 8);

/// Runs [run], but gives [fallback] once [deadline] passes or when [run] throws: a tap never waits
/// forever and never leaves a spinner behind. [onTimeout] is told when the deadline was the reason.
Future<T> happWithDeadline<T>(
  Future<T> Function() run, {
  required Duration deadline,
  required T fallback,
  void Function()? onTimeout,
  void Function(Object error)? onError,
}) async {
  // a Future<T> of its own: what [run] returns may be a Future<Never> (a closure that only throws),
  // which a T fallback can't complete
  Future<T> own() async => await run();
  try {
    return await own().timeout(
      deadline,
      onTimeout: () {
        onTimeout?.call();
        return fallback;
      },
    );
  } catch (e) {
    onError?.call(e);
    return fallback;
  }
}

/// Last tap wins: each tap takes a ticket; only the newest ticket may change the UI.
class HappLatestWins {
  int _gen = 0;

  /// A new tap: earlier ones are now stale.
  int begin() => ++_gen;

  bool isLatest(int ticket) => ticket == _gen;

  /// Makes every running ticket stale (the row went away, the subscription changed).
  void cancelAll() => _gen++;
}

/// Server picks in flight across the app. While one runs, new URL tests wait for it (≤ the select
/// deadline), so a pick is never queued behind a fresh batch of tests.
class HappSwitchActivity {
  HappSwitchActivity._();

  static final ValueNotifier<int> inFlight = ValueNotifier<int>(0);

  static bool get busy => inFlight.value > 0;

  /// Counts [run] as a pick in flight, whatever way it ends.
  static Future<T> track<T>(Future<T> Function() run) async {
    inFlight.value++;
    try {
      return await run();
    } finally {
      inFlight.value = inFlight.value > 0 ? inFlight.value - 1 : 0;
    }
  }

  /// Waits until no pick is in flight, at most [max]. True when it is clear.
  static Future<bool> waitIdle({Duration max = happSelectDeadline}) async {
    if (!busy) return true;
    final done = Completer<void>();
    void check() {
      if (!busy && !done.isCompleted) done.complete();
    }

    inFlight.addListener(check);
    try {
      await done.future.timeout(max, onTimeout: () {});
    } finally {
      inFlight.removeListener(check);
    }
    return !busy;
  }
}

/// The newest pick per group and whether its core call is done; lets an older pick that the core
/// answered late be overridden again by the newest one (last tap wins in the core too).
class HappPickLedger {
  int _gen = 0;
  final Map<String, ({int gen, String tag, bool done, bool ok})> _latest = {};

  int begin(String group, String tag) {
    _gen++;
    _latest[group] = (gen: _gen, tag: tag, done: false, ok: false);
    return _gen;
  }

  bool isLatest(String group, int gen) => _latest[group]?.gen == gen;

  /// Records that pick [gen] in [group] ended. Returns the tag to send again: the newest pick, when
  /// this one was older, the core took it and the newest one had already been taken (so this late
  /// answer may have moved the core back off the newest pick).
  String? finish(String group, int gen, {required bool ok}) {
    final latest = _latest[group];
    if (latest == null) return null;
    if (latest.gen == gen) {
      _latest[group] = (gen: gen, tag: latest.tag, done: true, ok: ok);
      return null;
    }
    if (ok && latest.done && latest.ok) return latest.tag;
    return null;
  }
}
