import 'dart:async';

import 'package:hiddify/features/happ/reliability/happ_core_log.dart';

/// The core's log lines that report a failed connection, as they arrive. Fed by the log listener
/// the app already runs (HiddifyCoreService.startListeningLogs); costs nothing when nobody listens.
abstract final class HappCoreLogTap {
  static final _failures = StreamController<({DateTime at, HappCoreFailure failure})>.broadcast(sync: true);

  static Stream<({DateTime at, HappCoreFailure failure})> get failures => _failures.stream;

  static void add(String line) {
    if (!_failures.hasListener) return;
    // cheap filter first: only error lines about connections or lookups are parsed
    if (!(line.contains('connection') || line.contains('lookup') || line.contains('exchange'))) return;
    final failure = happParseCoreFailure(line);
    if (failure != null) _failures.add((at: DateTime.now(), failure: failure));
  }
}
