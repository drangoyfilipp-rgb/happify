import 'dart:async';

/// Where the speedometer of a subscription gets its delays from.
enum HappPingRoute {
  /// Connected to this subscription: the running core tests it (nothing is restarted).
  live,

  /// Nothing is connected: a proxy-only core (no TUN, no VPN, no system proxy) is started with
  /// the subscription's config just for the test, then stopped.
  offline,

  /// Connected to another subscription. The core is one instance per app, so a test of this one
  /// would need the running connection to stop: it is skipped instead, with a short note.
  busyOther,

  /// This platform can't run a test core beside the app (desktop, macOS): connect to test.
  unsupported,
}

/// [connected] is true for any state but fully disconnected (connecting, connected, waiting,
/// reloading, disconnecting): only a fully stopped tunnel may lend its core to a test.
HappPingRoute happPingRoute({
  required bool connected,
  required bool thisIsActive,
  required bool offlineCapable,
}) {
  if (connected) return thisIsActive ? HappPingRoute.live : HappPingRoute.busyOther;
  return offlineCapable ? HappPingRoute.offline : HappPingRoute.unsupported;
}

/// One offline test at a time, and a way for connecting to call it off and wait until the test
/// core is stopped and the settings are put back, so the tunnel never starts on the test's core
/// or with its proxy-only settings.
class OfflineCoreTestGate {
  Future<void>? _running;
  Completer<void>? _cancel;
  int _holds = 0;

  /// A connection is being made: no test may start until it is [release]d.
  bool get held => _holds > 0;

  /// Keeps tests from starting (and calls off the one under way) while a connection is made;
  /// pair with [release].
  void hold() {
    _holds++;
    cancel();
  }

  void release() {
    if (_holds > 0) _holds--;
  }

  /// Runs [connect] with tests held off: the test under way is stopped and cleaned up first, and
  /// none starts until [connect] is done, so the tunnel never starts on a test's core or settings.
  Future<T> exclusive<T>(Future<T> Function() connect, {Duration timeout = const Duration(seconds: 30)}) async {
    hold();
    try {
      await cancelAndWait(timeout: timeout);
      return await connect();
    } finally {
      release();
    }
  }

  /// A test is under way.
  bool get busy => _running != null;

  /// The test under way was asked to stop.
  bool get cancelled => _cancel?.isCompleted ?? false;

  /// Completes when the test under way is asked to stop.
  Future<void> get onCancel => _cancel?.future ?? Completer<void>().future;

  /// Runs [body] unless a test is under way already (then null, nothing runs) or the gate is
  /// being called off. The body checks [cancelled] / [onCancel] between its steps and always
  /// cleans up before it returns.
  Future<T?> run<T>(Future<T> Function() body) async {
    if (_running != null || held) return null;
    final done = Completer<void>();
    _running = done.future;
    _cancel = Completer<void>();
    try {
      return await body();
    } finally {
      _running = null;
      _cancel = null;
      done.complete();
    }
  }

  /// Asks the test under way to stop and waits until it has cleaned up ([timeout] at most).
  /// Returns at once when nothing runs.
  Future<void> cancelAndWait({Duration timeout = const Duration(seconds: 30)}) async {
    final running = _running;
    if (running == null) return;
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    await running.timeout(timeout, onTimeout: () {});
  }

  /// Asks the test under way to stop without waiting.
  void cancel() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }
}
