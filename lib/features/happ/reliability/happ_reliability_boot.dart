import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// At start, before the first connection:
/// - the key of the core's local control API is made once, so the app can ask the core for a
///   probe through one server (the core is told it in "web-secret");
/// - a user who had turned the old «Менять нерабочий сервер» off keeps «Автопереключение при
///   сбое» off.
Future<void> happReliabilityBoot(SharedPreferences prefs) async {
  if ((prefs.getString('happify_clash_secret') ?? '').isEmpty) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    final secret = String.fromCharCodes([for (var i = 0; i < 24; i++) alphabet.codeUnitAt(random.nextInt(alphabet.length))]);
    await prefs.setString('happify_clash_secret', secret);
  }
  if (!prefs.containsKey('happify_failover') && prefs.getBool('happify_auto_switch_dead') == false) {
    await prefs.setBool('happify_failover', false);
  }
}
