import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_machine.dart';
import 'package:hiddify/utils/utils.dart';

/// The Android side of Happify's reliability features (HappifyChannel.kt): the screen, the VPN
/// notification's colour, notifications, recent apps. Every call is safe off Android or when the
/// native side is missing: it does nothing and answers a neutral value.
abstract final class HappPlatform {
  static const _channel = MethodChannel('com.hiddify.app/happify');

  static final _screen = StreamController<bool>.broadcast();
  static final _actions = StreamController<String>.broadcast();
  static bool _listening = false;

  /// Screen on (true) and off (false), as Android reports them.
  static Stream<bool> get screen {
    _listen();
    return _screen.stream;
  }

  /// What the user asked for from the VPN notification: "bypass" («Мимо VPN»).
  static Stream<String> get actions {
    _listen();
    return _actions.stream;
  }

  static void _listen() {
    if (_listening || !PlatformUtils.isAndroid) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'screen':
          _screen.add(call.arguments == true);
        case 'action':
          if (call.arguments case final String action) _actions.add(action);
      }
      return null;
    });
  }

  static Future<T?> _call<T>(String method, [Object? args]) async {
    if (!PlatformUtils.isAndroid) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Whether the screen is on now (true off Android).
  static Future<bool> isScreenOn() async => await _call<bool>('screen_on') ?? true;

  /// An action the notification asked for before the app was ready to hear it (cleared on read).
  static Future<String?> takePendingAction() => _call<String>('take_action');

  /// The colour of the VPN notification: the traffic light of [level], and a short [note] under
  /// the server's name (null: none).
  static Future<void> setLiveness(HappLiveness level, {String? note}) =>
      _call<void>('liveness', {'light': level.light, 'note': note});

  /// Posts a notification. [important] ones make a sound; the rest are quiet.
  static Future<void> notify({required int id, required String title, required String text, required bool important}) =>
      _call<void>('notify', {'id': id, 'title': title, 'text': text, 'important': important});

  /// Whether the app may read which apps were used recently («Доступ к истории использования»).
  static Future<bool> hasUsageAccess() async => await _call<bool>('has_usage_access') ?? false;

  /// The system page where the user allows that.
  static Future<void> openUsageAccessSettings() => _call<void>('open_usage_settings');

  /// The apps used most recently, newest first: package and name; empty without the permission.
  static Future<List<({String package, String name})>> recentApps({int count = 5}) async {
    final raw = await _call<List<Object?>>('recent_apps', {'count': count});
    return [
      for (final e in raw ?? const <Object?>[])
        if (e is Map && e['package'] is String) (package: e['package'] as String, name: (e['name'] as String?) ?? e['package'] as String),
    ];
  }

  /// The launchable apps (with internet access), by name: package and name.
  static Future<List<({String package, String name})>> launchableApps() async {
    final raw = await _call<List<Object?>>('launchable_apps');
    return [
      for (final e in raw ?? const <Object?>[])
        if (e is Map && e['package'] is String) (package: e['package'] as String, name: (e['name'] as String?) ?? e['package'] as String),
    ];
  }

  /// The names of [packages], as the phone shows them.
  static Future<Map<String, String>> appLabels(Iterable<String> packages) async {
    final raw = await _call<Map<Object?, Object?>>('app_labels', {'packages': packages.toList()});
    return {
      for (final e in (raw ?? const {}).entries)
        if (e.key is String && e.value is String) e.key as String: e.value as String,
    };
  }

  /// Whether the phone is on mobile data now.
  static Future<bool> onMobileData() async {
    if (!PlatformUtils.isAndroid) return false;
    try {
      return await const MethodChannel('com.hiddify.app/platform').invokeMethod<bool>('on_mobile_data') ?? false;
    } catch (_) {
      return false;
    }
  }
}
