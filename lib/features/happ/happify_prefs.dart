import 'package:flutter/material.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Happify's own settings: the simple/expert split and the convenience features.
abstract class HappifyPrefs {
  /// Off: the settings show only what everyday use needs. On: every Hiddify option is back.
  static final expertMode = PreferencesNotifier.create<bool, bool>("happify_expert_mode", false);

  /// Connect by itself when the app opens, if a profile is active.
  static final autoConnectOnStart = PreferencesNotifier.create<bool, bool>("happify_autoconnect_on_start", true);

  /// Off by default: reading the clipboard is the user's choice.
  /// Offer to add a subscription link found in the clipboard when the app opens or comes back.
  static final clipboardDetect = PreferencesNotifier.create<bool, bool>("happify_clipboard_detect", false);

  /// A fingerprint of the last clipboard text offered (never the link itself, which can hold an
  /// access token), so the same link is never offered twice.
  static final lastClipboardOffer = PreferencesNotifier.create<String, String>("happify_last_clipboard_offer", "");

  /// When the current connection came up (ms since epoch), 0 while disconnected. Saved, so the
  /// timer is right even after the app was closed while the VPN kept running.
  static final connectedSince = PreferencesNotifier.create<int, int>("happify_connected_since", 0);

  /// Pick the server used last in each profile again on the next connection.
  static final rememberLastServer = PreferencesNotifier.create<bool, bool>("happify_remember_last_server", true);

  /// Swap a server whose ping failed for the fastest one that answers.
  static final autoSwitchDead = PreferencesNotifier.create<bool, bool>("happify_auto_switch_dead", true);

  /// Servers pinned to the top of the list, by name, one per line.
  static final pinnedServers = PreferencesNotifier.create<String, String>("happify_pinned_servers", "");

  /// Update the active subscription when the app opens (at most every 10 minutes).
  static final updateOnOpen = PreferencesNotifier.create<bool, bool>("happify_update_on_open", true);

  /// «Проверять обновления»: look for a newer Happify build on start (at most every 6 hours).
  static final checkUpdates = PreferencesNotifier.create<bool, bool>("happify_check_updates", true);

  /// Keep VPN on: connect again by itself after the tunnel fails. A stop the user asked for stays.
  static final keepConnected = PreferencesNotifier.create<bool, bool>("happify_keep_connected", true);

  /// Show the "lowest" (fastest server) and "balance" (spread over all) groups in the server lists.
  static final showBalancers = PreferencesNotifier.create<bool, bool>("happify_show_balancers", true);

  /// Test every server's ping when the app opens, after the update is done.
  static final pingOnOpen = PreferencesNotifier.create<bool, bool>("happify_ping_on_open", true);

  /// «Экономия трафика»: "auto" (on while the phone is on mobile data), "on" or "off".
  static final trafficSaving = PreferencesNotifier.create<String, String>("happify_traffic_saving", "auto");

  /// «Уведомление VPN»: off makes the service's notification as quiet as Android allows, and it is
  /// not shown again after it is removed. Read by the Android side (flutter.happify_vpn_notification).
  static final vpnNotification = PreferencesNotifier.create<bool, bool>("happify_vpn_notification", true);

  /// «Вид интерфейса»: "bottom" (the bottom menu, as before) or "happ" (no bottom menu; a gear
  /// top left on the home screen opens the settings, as in Happ).
  static final uiLayout = PreferencesNotifier.create<String, String>("happify_ui_layout", "bottom");
}

/// What removed features left in the preferences: the per-subscription results of the old AI
/// service check ("happify_gemini_<profile id>"). Dropped at start; nothing reads them any more.
Future<void> happRemoveObsoletePrefs(SharedPreferences prefs) async {
  for (final key in prefs.getKeys().toList()) {
    if (key.startsWith('happify_gemini_')) await prefs.remove(key);
  }
}

Set<String> pinnedSet(String raw) => raw.split('\n').where((e) => e.isNotEmpty).toSet();

/// Russian for Russian, English otherwise: Happify's own strings live here instead of the
/// generated translations.
String hr(BuildContext context, String ru, String en) =>
    Localizations.maybeLocaleOf(context)?.languageCode == 'ru' ? ru : en;

/// Happify: a plain explanation under a setting that is hard to understand from its name alone.
class HappifyHint extends StatelessWidget {
  const HappifyHint(this.ru, this.en, {super.key});

  final String ru;
  final String en;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(72, 0, 16, 12),
      child: Text(
        hr(context, ru, en),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Happify extras: switches for the less common features.
abstract class HappifyExtraPrefs {
  /// Turn the VPN on by itself when the phone joins a Wi-Fi network that isn't trusted.
  /// Read by the Android side too (as flutter.happify_wifi_auto), so it works with the app closed.
  static final wifiAuto = PreferencesNotifier.create<bool, bool>("happify_wifi_auto", false);

  /// Trusted Wi-Fi names, one per line (flutter.happify_trusted_wifi on the Android side).
  static final trustedWifi = PreferencesNotifier.create<String, String>("happify_trusted_wifi", "");
}

/// A short fingerprint of a text (32-bit FNV-1a), stable across launches.
String clipHash(String text) {
  var h = 0x811c9dc5;
  for (final c in text.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return 'h${h.toRadixString(16)}';
}

/// True for a value [clipHash] made; anything else is an old saved link.
bool isClipHash(String value) => RegExp(r'^h[0-9a-f]{1,8}$').hasMatch(value);
