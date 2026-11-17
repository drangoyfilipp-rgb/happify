import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// «Диагностика» → «Определять приложение»: the core only finds out which app a connection is
/// from when a rule asks about apps. On by default on Android: the lookup is a local call per new
/// connection and costs no traffic.
final happDiagAppsPref = PreferencesNotifier.create<bool, bool>("happify_diag_apps", true);

/// Whether the app-matching rule goes into the config: Android only.
final happDiagAppsRuleProvider = Provider<bool>((ref) => PlatformUtils.isAndroid && ref.watch(happDiagAppsPref));

/// A rule for an app that does not exist, sent the usual way (through the proxy, as everything
/// unmatched is): it changes no route, it only makes the core look up the app of each connection,
/// so failures can be shown per app.
Rule happDiagAppsRule() => Rule(
  enabled: true,
  name: 'happify-app-detect',
  packageNames: const ['happify.diagnostics.no.such.app'],
  outbound: Outbound.proxy,
);
