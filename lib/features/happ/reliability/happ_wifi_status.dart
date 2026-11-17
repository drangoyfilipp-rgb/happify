// «Доверенные Wi-Fi»: what the dialog can say about the Wi-Fi under the VPN. Pure, for the tests.

/// Why the dialog shows what it shows.
enum HappWifiStatus {
  /// The phone is on Wi-Fi and Android told its name.
  named,

  /// No Wi-Fi under the VPN (mobile data, or nothing).
  notOnWifi,

  /// On Wi-Fi, but Android hides the name: the app has no location access.
  needPermission,

  /// On Wi-Fi, the app may read the name, but location is turned off on the phone.
  locationOff,

  /// On Wi-Fi, permission and location on, and the name is still hidden (some phones do this).
  hidden,
}

/// The answer of `current_ssid` (HappifyWifiWatcher.state on Android): wifi, ssid, permission,
/// location. An older or missing answer (no "wifi" key) counts the name as the only sign of Wi-Fi.
({HappWifiStatus status, String? ssid}) happWifiStatusOf(Map<Object?, Object?>? info) {
  final ssid = info?['ssid'] is String && (info!['ssid'] as String).isNotEmpty ? info['ssid'] as String : null;
  final permission = info?['permission'] == true;
  final location = info?['location'] != false;
  final onWifi = info?['wifi'] is bool ? info!['wifi'] == true : ssid != null;
  if (ssid != null) return (status: HappWifiStatus.named, ssid: ssid);
  if (!onWifi) return (status: HappWifiStatus.notOnWifi, ssid: null);
  if (!permission) return (status: HappWifiStatus.needPermission, ssid: null);
  if (!location) return (status: HappWifiStatus.locationOff, ssid: null);
  return (status: HappWifiStatus.hidden, ssid: null);
}
