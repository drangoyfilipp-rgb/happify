import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// «Экономия трафика»: on mobile data (by itself) or when the user turns it on, Happify spends as
// little as it can on its own background work: no ping on open (pings on demand only), the
// subscription updated less often, no IP lookup. Nothing here touches the running VPN: the core's
// settings stay as they are, so the switch never reconnects.

const _platform = MethodChannel('com.hiddify.app/platform');

/// Whether the phone is on mobile data now (no Wi-Fi or Ethernet). Android only; checked every
/// 30 seconds, which is a cheap local call (it lives as long as the app).
final happOnMobileDataProvider = StreamProvider<bool>((ref) async* {
  if (kIsWeb || !PlatformUtils.isAndroid) {
    yield false;
    return;
  }
  Future<bool> read() async {
    try {
      return await _platform.invokeMethod<bool>('on_mobile_data') ?? false;
    } catch (_) {
      return false;
    }
  }

  var last = await read();
  yield last;
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 30));
    final now = await read();
    if (now != last) {
      last = now;
      yield now;
    }
  }
});

/// The «Экономия трафика» modes as saved: "auto", "on", "off".
enum HappTrafficSaving { auto, on, off }

HappTrafficSaving happTrafficSavingMode(String raw) =>
    HappTrafficSaving.values.firstWhere((e) => e.name == raw, orElse: () => HappTrafficSaving.auto);

/// Whether traffic saving is in effect right now.
final happTrafficSavingProvider = Provider<bool>((ref) {
  return switch (happTrafficSavingMode(ref.watch(HappifyPrefs.trafficSaving))) {
    HappTrafficSaving.on => true,
    HappTrafficSaving.off => false,
    HappTrafficSaving.auto => ref.watch(happOnMobileDataProvider).valueOrNull ?? false,
  };
});

/// How long a ping test waits for its results: longer while saving, when the internet is often slow.
Duration happPingBudget(bool saving) => saving ? const Duration(seconds: 30) : const Duration(seconds: 15);

/// A subscription's update interval while saving: three times as long, at least 6 hours.
Duration happSavingUpdateInterval(Duration interval) {
  final longer = interval * 3;
  return longer < const Duration(hours: 6) ? const Duration(hours: 6) : longer;
}
