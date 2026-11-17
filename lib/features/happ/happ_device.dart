import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Happ-style device identification for subscription requests.
///
/// Panels such as Remnawave limit devices by the `x-hwid` header that Happ sends.
/// The id is generated once per install and kept in preferences.
abstract class HappDevice {
  static const _key = 'happ_hwid';
  static String hwid = '';
  static String _osVersion = '';

  static Future<void> init(SharedPreferences prefs) async {
    var id = prefs.getString(_key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_key, id);
    }
    hwid = id;
    _osVersion = _ascii(Platform.operatingSystemVersion);
  }

  static String _ascii(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  static String get _os {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }

  static Map<String, String> get headers => hwid.isEmpty
      ? const {}
      : {'x-hwid': hwid, 'x-device-os': _os, 'x-ver-os': _osVersion, 'x-device-model': 'Hiddify-Happ'};
}
