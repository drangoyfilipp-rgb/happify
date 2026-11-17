import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:circle_flags/circle_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/trusted_links.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_sub_update.dart';
import 'package:hiddify/features/happ/happify_traffic_saving.dart';
import 'package:hiddify/features/happ/happ_switch_guard.dart';
import 'package:hiddify/features/happ/happify_profile_editor.dart';
import 'package:hiddify/features/happ/happify_home_servers.dart';
import 'package:hiddify/features/happ/happify_server_sort.dart';
import 'package:hiddify/features/happ/happify_server_titles.dart';
import 'package:hiddify/features/happ/happ_ping_plan.dart';
import 'package:hiddify/features/happ/happify_offline_ping.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_machine.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_runtime.dart';
import 'package:hiddify/features/happ/reliability/happ_notifications.dart';
import 'package:hiddify/features/happ/reliability/happ_notify_rules.dart';
import 'package:hiddify/features/happ/reliability/happ_profile_sort_state.dart';
import 'package:hiddify/features/happ/reliability/happ_speed_plan.dart';
import 'package:hiddify/features/happ/reliability/happ_speed_test.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Happ's home screen, one to one: the big round button, then one card per subscription, each
// opening onto its servers, which can be picked before connecting as well as after.

/// Happ's palette, light and dark.
class HappColors {
  const HappColors._({
    required this.background,
    required this.shape,
    required this.card,
    required this.band,
    required this.bandLine,
    required this.row,
    required this.rowLine,
    required this.selectedRow,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.power,
    required this.powerOn,
  });

  final Color background;
  final Color shape;
  final Color card;
  final Color band;
  final Color bandLine;
  final Color row;
  final Color rowLine;
  final Color selectedRow;
  final Color title;
  final Color subtitle;
  final Color icon;
  final Color accent;
  final Color power;
  final Color powerOn;

  // Light is the dark palette turned over, step for step: the card a step lighter than the
  // background, the rows half a step back from the card with the background showing between
  // them, a blue-tinted info strip, an indigo-tinted selected row, the same accents; text dark
  // enough to read (title ~16:1, subtitle ~4.8:1 on the rows).
  static const light = HappColors._(
    background: Color(0xFFEFF0F4),
    shape: Color(0xFFFAFAFC),
    card: Colors.white,
    band: Color(0xFFEEF1FC),
    bandLine: Color(0xFFDFE4F5),
    row: Color(0xFFFAFAFC),
    rowLine: Color(0xFFEFF0F4),
    selectedRow: Color(0xFFE4EAFD),
    title: Color(0xFF1B1C22),
    subtitle: Color(0xFF686A77),
    icon: Color(0xFF5F5B95),
    accent: Color(0xFF4F72EE),
    power: Color(0xFFB3B4BD),
    powerOn: Color(0xFF6A5CF0),
  );

  static const dark = HappColors._(
    background: Color(0xFF151518),
    shape: Color(0xFF1C1C20),
    card: Color(0xFF232328),
    band: Color(0xFF262B3B),
    bandLine: Color(0xFF30374C),
    row: Color(0xFF1D1D22),
    rowLine: Color(0xFF151518),
    selectedRow: Color(0xFF2B3352),
    title: Color(0xFFE9E9F1),
    subtitle: Color(0xFF8D8D99),
    icon: Color(0xFFA7A3D8),
    accent: Color(0xFF7C9CFF),
    power: Color(0xFF55555E),
    powerOn: Color(0xFF8C82FF),
  );

  static HappColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// The light grey background with Happ's soft diagonal shapes.
class HappBackground extends StatelessWidget {
  const HappBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final c = HappColors.of(context);
    return RepaintBoundary(
      child: CustomPaint(painter: _BackgroundPainter(c.background, c.shape)),
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.base, this.shape);
  final Color base;
  final Color shape;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final w = size.width;
    final h = size.height;
    // light: the same sweeps, blurred wide (dark keeps its crisp ones)
    final soft = base.computeLuminance() > .5 ? MaskFilter.blur(BlurStyle.normal, w * .06) : null;
    final paint = Paint()
      ..color = shape.withValues(alpha: .55)
      ..maskFilter = soft;
    // two broad soft bands sweeping down from the top left, as on Happ
    final a = Path()
      ..moveTo(-w * .2, h * .05)
      ..quadraticBezierTo(w * .45, h * .02, w * 1.2, h * .42)
      ..lineTo(w * 1.2, h * .62)
      ..quadraticBezierTo(w * .35, h * .2, -w * .2, h * .3)
      ..close();
    canvas.drawPath(a, paint);
    final b = Path()
      ..moveTo(-w * .2, h * .62)
      ..quadraticBezierTo(w * .5, h * .55, w * 1.2, h * .9)
      ..lineTo(w * 1.2, h * 1.1)
      ..quadraticBezierTo(w * .4, h * .7, -w * .2, h * .82)
      ..close();
    canvas.drawPath(
      b,
      Paint()
        ..color = shape.withValues(alpha: .4)
        ..maskFilter = soft,
    );
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => old.base != base || old.shape != shape;
}

// ---------------------------------------------------------------------------------------------
// The power button

enum _Look { idle, connecting, connected, degraded, disconnecting, failed }

_Look _lookOf(AsyncValue<ConnectionStatus> status, bool degraded) => switch (status) {
  AsyncError() => _Look.failed,
  AsyncValue(valueOrNull: Disconnected(connectionFailure: _?)) => _Look.failed,
  AsyncValue(valueOrNull: Connected()) || AsyncValue(valueOrNull: HotReloading()) =>
    degraded ? _Look.degraded : _Look.connected,
  AsyncValue(valueOrNull: Connecting() || Waiting() || NoAvailableProxies()) => _Look.connecting,
  AsyncValue(valueOrNull: Disconnecting()) => _Look.disconnecting,
  _ => _Look.idle,
};

/// Connects, or sends the user to add a profile when there is none.
Future<void> happConnect(WidgetRef ref) async {
  final dialogs = ref.read(dialogNotifierProvider.notifier);
  if (ref.read(activeProfileProvider).valueOrNull == null) {
    await dialogs.showNoActiveProfile();
    ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile();
    return;
  }
  if (await dialogs.showExperimentalFeatureNotice()) {
    await ref.read(connectionNotifierProvider.notifier).toggleConnection();
  }
}

class HappPowerButton extends HookConsumerWidget {
  const HappPowerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider);
    final health = ref.watch(connectionHealthProvider);
    final look = _lookOf(status, health?.degraded ?? false);
    final c = HappColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;

    final onTap = switch (status) {
      AsyncData(value: Disconnected()) || AsyncError() => () => happConnect(ref),
      AsyncData(value: Connected() || Waiting() || NoAvailableProxies() || Connecting() || HotReloading()) =>
        () => ref.read(connectionNotifierProvider.notifier).toggleConnection(),
      _ => null,
    };

    final pulse = useAnimationController(duration: const Duration(milliseconds: 1200));
    final busy = look == _Look.connecting || look == _Look.disconnecting;
    useEffect(() {
      if (busy) {
        pulse.repeat(reverse: true);
      } else {
        pulse.stop();
        pulse.value = 0;
      }
      return null;
    }, [busy]);

    final on = look == _Look.connected || look == _Look.degraded;
    final iconColor = switch (look) {
      _Look.connected => c.powerOn,
      _Look.degraded => const Color(0xFFE3A63A),
      _Look.failed => const Color(0xFFE5484D),
      _Look.connecting || _Look.disconnecting => c.powerOn.withValues(alpha: .75),
      _Look.idle => c.power,
    };
    final label = switch (look) {
      _Look.connected => hr(context, 'ПОДКЛЮЧЕН', 'CONNECTED'),
      _Look.degraded => hr(context, 'НЕТ ОТВЕТА', 'NO RESPONSE'),
      _Look.connecting => switch (status.valueOrNull) {
        Waiting() => hr(context, 'ОЖИДАНИЕ', 'WAITING'),
        NoAvailableProxies() => hr(context, 'НЕТ СЕРВЕРОВ', 'NO SERVERS'),
        _ => hr(context, 'ПОДКЛЮЧЕНИЕ', 'CONNECTING'),
      },
      _Look.disconnecting => hr(context, 'ОТКЛЮЧЕНИЕ', 'DISCONNECTING'),
      _Look.failed => hr(context, 'ОШИБКА', 'ERROR'),
      _Look.idle => null,
    };

    final double width = MediaQuery.sizeOf(context).width.clamp(280.0, 600.0);
    // compact, as Happ is on a phone: about 170 dp across the ring
    final double ring = math.min(width * .44, 176.0);
    final double outer = ring * .82;
    final double inner = ring * .64;

    return Semantics(
      button: true,
      label: label ?? hr(context, 'Подключить', 'Connect'),
      child: SizedBox(
        width: ring + 8,
        height: ring + 8,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // the thin outer ring, teal at the top left fading to pink at the bottom right
            CustomPaint(size: Size.square(ring), painter: _RingPainter(dark)),
            // the soft grey dish
            Container(
              width: outer,
              height: outer,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: dark
                      ? const [Color(0xFF2A2A30), Color(0xFF1E1E23)]
                      : const [Color(0xFFFAFAFC), Color(0xFFE4E5EA)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: dark ? Colors.black.withValues(alpha: .45) : const Color(0xFFCDCED6),
                    blurRadius: dark ? 16 : 20,
                    offset: dark ? const Offset(4, 6) : const Offset(5, 8),
                  ),
                  BoxShadow(
                    color: dark ? Colors.white.withValues(alpha: .03) : Colors.white,
                    blurRadius: dark ? 14 : 16,
                    offset: dark ? const Offset(-4, -4) : const Offset(-5, -5),
                  ),
                ],
              ),
            ),
            // the white button
            Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Container(
                  width: inner,
                  height: inner,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dark ? const Color(0xFF26262C) : Colors.white,
                    border: Border.all(
                      color: dark ? const Color(0xFF34343B) : const Color(0xFFEEEFF3),
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: dark ? Colors.black.withValues(alpha: .35) : const Color(0xFFD9DAE0),
                        blurRadius: 10,
                        offset: const Offset(2, 4),
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (on)
                        Positioned.fill(
                          child: CustomPaint(painter: _GridPainter(iconColor.withValues(alpha: dark ? .35 : .22))),
                        ),
                      AnimatedBuilder(
                        animation: pulse,
                        builder: (context, child) => Opacity(opacity: busy ? .45 + .55 * pulse.value : 1, child: child),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.power_settings_new_rounded, size: inner * (label == null ? .4 : .3), color: iconColor),
                            if (label != null) ...[
                              SizedBox(height: inner * .04),
                              Text(
                                label,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 10.5, letterSpacing: .4, color: c.subtitle),
                              ),
                            ],
                            if (on) ...[SizedBox(height: inner * .05), const _Elapsed()],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..shader = SweepGradient(
        transform: const GradientRotation(-math.pi * .75),
        colors: [
          const Color(0xFF8FBFC6).withValues(alpha: dark ? .5 : .9),
          const Color(0xFFDDE7EA).withValues(alpha: .15),
          const Color(0xFFE3B1BA).withValues(alpha: dark ? .5 : .9),
          const Color(0xFFE3B1BA).withValues(alpha: dark ? .3 : .6),
          const Color(0xFFEEDDE0).withValues(alpha: .1),
          const Color(0xFF8FBFC6).withValues(alpha: dark ? .5 : .9),
        ],
        stops: const [0, .22, .45, .6, .8, 1],
      ).createShader(rect);
    canvas.drawCircle(rect.center, size.width / 2 - 1, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.dark != dark;
}

/// The dotted "+" grid the button wears while connected.
class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    const step = 8.0;
    const arm = 2.0;
    for (var x = step / 2; x < size.width; x += step) {
      for (var y = step / 2; y < size.height * .75; y += step) {
        final p = Offset(x, y);
        final d = (p - Offset(center.dx, size.height * .32)).distance / r;
        if (d > .85 || (p - center).distance > r - 8) continue;
        final paint = Paint()
          ..color = color.withValues(alpha: color.a * (1 - d).clamp(0, 1))
          ..strokeWidth = 1;
        canvas.drawLine(p.translate(-arm, 0), p.translate(arm, 0), paint);
        canvas.drawLine(p.translate(0, -arm), p.translate(0, arm), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

/// How long the tunnel has been up: 00:12:34. Keeps [HappifyPrefs.connectedSince].
class _Elapsed extends HookConsumerWidget {
  const _Elapsed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = useState(0);
    final since = ref.watch(HappifyPrefs.connectedSince);
    useEffect(() {
      final timer = Timer.periodic(const Duration(seconds: 1), (_) => tick.value++);
      return timer.cancel;
    }, const []);
    var elapsed = since == 0
        ? Duration.zero
        : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(since));
    if (elapsed.isNegative) elapsed = Duration.zero;
    String two(int n) => n.toString().padLeft(2, '0');
    final text = elapsed.inDays > 0
        ? '${elapsed.inDays}${hr(context, 'д', 'd')} ${two(elapsed.inHours % 24)}:${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}'
        : '${two(elapsed.inHours)}:${two(elapsed.inMinutes % 60)}:${two(elapsed.inSeconds % 60)}';
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: HappColors.of(context).title,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Keeps the time the tunnel came up, for the timer in the button and elsewhere.
class HappConnectedSinceKeeper extends HookConsumerWidget {
  const HappConnectedSinceKeeper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final since = ref.watch(HappifyPrefs.connectedSince);
    final connected = status is Connected || status is HotReloading;
    useEffect(() {
      final notifier = ref.read(HappifyPrefs.connectedSince.notifier);
      if (connected && since == 0) {
        Future.microtask(() => notifier.update(DateTime.now().millisecondsSinceEpoch));
      } else if (status is Disconnected && since != 0) {
        Future.microtask(() => notifier.update(0));
      }
      return null;
    }, [connected, status is Disconnected, since]);
    return const SizedBox.shrink();
  }
}

// ---------------------------------------------------------------------------------------------
// Servers, read from a profile's saved config

/// A server of a profile's config: what Happ's row shows under its name, and where it is for a ping.
typedef HappServer = ({String tag, String type, String subtitle, String detail, String? host, int? port});

List<HappServer> happServersOf(String config) {
  final json = jsonDecode(config);
  if (json is! Map) return const [];
  const notProxies = {'block', 'selector', 'urltest', 'custom', 'dns', 'direct'};
  const builtIn = {'direct', 'bypass', 'block', 'select', 'lowest', 'balance'};
  final servers = <HappServer>[];
  for (final key in const ['outbounds', 'endpoints']) {
    for (final out in json[key] as List? ?? const []) {
      if (out is! Map) continue;
      final tag = out['tag'] as String? ?? '';
      final type = out['type'] as String? ?? '';
      if (notProxies.contains(type) || builtIn.contains(tag) || tag.contains('§hide§')) continue;
      servers.add((
        tag: tag,
        type: type,
        subtitle: happSubtitle(out),
        detail: happTransportDetail(out),
        host: out['server'] as String?,
        port: (out['server_port'] as num?)?.toInt(),
      ));
    }
  }
  return servers;
}

String _protocolName(String type) => switch (type.toLowerCase()) {
  'hysteria2' || 'hysteria' => 'HYSTERIA',
  'shadowsocks' => 'SHADOWSOCKS',
  'wireguard' => 'WIREGUARD',
  final t => t.toUpperCase(),
};

/// "VLESS / TCP / REALITY | JSON", as Happ writes it.
String happSubtitle(Map<dynamic, dynamic> out) {
  final type = (out['type'] as String? ?? '').toLowerCase();
  final proto = _protocolName(type);
  final transport = out['transport'];
  final transportType = transport is Map ? transport['type'] : null;
  final String net = transportType is String && transportType.isNotEmpty
      ? transportType.toUpperCase()
      : switch (type) {
          'hysteria' || 'hysteria2' => 'HYSTERIA',
          'tuic' => 'QUIC',
          'wireguard' || 'awg' => 'UDP',
          _ => 'TCP',
        };
  final tls = out['tls'];
  final reality = tls is Map ? tls['reality'] : null;
  final String? security = tls is! Map
      ? null
      : (reality is Map && reality['enabled'] == true)
      ? 'REALITY'
      : tls['enabled'] == true
      ? 'TLS'
      : null;
  return '${[proto, net, ?security].join(' / ')} | JSON';
}

final happServersProvider = FutureProvider.autoDispose.family<List<HappServer>, String>((ref, profileId) async {
  // read again when the profile is updated
  ref.watch(profilesNotifierProvider.select((p) => p.valueOrNull?.where((e) => e.id == profileId).firstOrNull?.lastUpdate));
  final file = ref.watch(profilePathResolverProvider).file(profileId);
  if (!file.existsSync()) return const [];
  final config = await file.readAsString();
  return Isolate.run(() {
    try {
      return happServersOf(config);
    } on FormatException {
      return const <HappServer>[];
    }
  });
});

/// The last real delays the core measured, per profile: "happify_ping_<profile id>" holds a JSON
/// map of server tag → ms (-1 for a server that did not answer). Shown, greyed by nothing but
/// their age, while disconnected. Only the core's URL test writes here: a TCP handshake from the
/// app is answered at once by whatever VPN tunnel the phone has up (ours or another app's), which
/// is how every server, even the UDP-only Hysteria ones, used to read ~4 ms.
String happPingCacheKey(String profileId) => 'happify_ping_$profileId';

/// Bumped whenever a cache above is written, so the rows read it again.
final happPingCacheRevision = StateProvider<int>((ref) => 0);

Map<String, int> happReadPingCache(SharedPreferences? prefs, String profileId) {
  final raw = prefs?.getString(happPingCacheKey(profileId));
  if (raw == null || raw.isEmpty) return const {};
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return const {};
    return {
      for (final e in json.entries)
        if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt(),
    };
  } on FormatException {
    return const {};
  }
}

/// The delay the core reports for [proxy]: the fresh URL test, else the one it sorted by;
/// null when it has none yet, -1 when the server did not answer.
int? happCoreDelay(OutboundInfo proxy) {
  final d = proxy.urlTestDelay;
  if (ConnectionConst.isValidDelay(d)) return d;
  if (d >= ConnectionConst.maxDelay) return -1;
  // not tested since the core started: the delay it last sorted by, when it is a real one
  if (ConnectionConst.isValidDelay(proxy.sortDelay)) return proxy.sortDelay;
  return null;
}

// ---------------------------------------------------------------------------------------------
// The flag and the name

final _flagPair = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

/// The country code of the first flag in [name], such as "DE"; null when it has none.
String? happFlagCode(String name) => happCountryFromName(name);

/// [name] without its flag, and without the core's hidden suffix.
String happCleanName(String name) =>
    name.replaceFirst(RegExp(r'\§[^]*'), '').replaceAll(_flagPair, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

class HappFlag extends StatelessWidget {
  const HappFlag(this.code, {super.key, this.size = 36});
  final String? code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final code = this.code;
    if (code == null || code.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: const Color(0xFF5E5E66), borderRadius: BorderRadius.circular(size * .22)),
        child: Icon(Icons.language_rounded, color: Colors.white.withValues(alpha: .9), size: size * .78),
      );
    }
    final lower = code.toLowerCase();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .22),
      child: SizedBox.square(
        dimension: size,
        child: FittedBox(
          fit: BoxFit.cover,
          child: CircleFlag(lower == 'ir' ? 'ir-shir' : lower, size: size, shape: null),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// The home list: the button, the row under it, a card per subscription

const _expandedKey = 'happify_home_expanded';

/// The order the cards keep on the home screen: the ids in the order they first came, one per line.
/// Selecting, updating or pinging never moves a card; pinning brings it to the top.
const _orderKey = 'happify_home_order';

/// [profiles] pinned first, then in the order they first came to the home screen.
List<ProfileEntity> happHomeOrder(List<ProfileEntity> profiles, List<String> seen) {
  final at = {for (final (i, id) in seen.indexed) id: i};
  int index(ProfileEntity p) => at[p.id] ?? seen.length + profiles.indexOf(p);
  return [...profiles]..sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return index(a).compareTo(index(b));
  });
}

/// The height of the «Быстрые настройки» tab home_page.dart lays over the bottom of the cards.
const double _quickSettingsTab = 32;

class HappHomeContent extends HookConsumerWidget {
  const HappHomeContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = HappColors.of(context);
    final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    final listed = ref.watch(profilesNotifierProvider).valueOrNull ?? const <ProfileEntity>[];
    final seen = (prefs?.getString(_orderKey) ?? '').split('\n').where((e) => e.isNotEmpty).toList();
    final profiles = happHomeOrder(listed, seen);
    final unseen = [
      for (final p in listed)
        if (!seen.contains(p.id)) p.id,
    ];
    useEffect(() {
      if (prefs != null && unseen.isNotEmpty) {
        // the ones that are gone drop out; new ones go last
        final keep = seen.where((id) => listed.any((p) => p.id == id));
        Future.microtask(() => prefs.setString(_orderKey, [...keep, ...unseen].join('\n')));
      }
      return null;
    }, [unseen.join(',')]);
    final activeId = ref.watch(activeProfileProvider.select((p) => p.valueOrNull?.id));
    final expanded = useState<Set<String>?>(null);
    final scroll = useScrollController();
    // until the user opens or closes one, the saved ones are open; on the first run, the active one
    final current =
        expanded.value ??
        switch (prefs?.getString(_expandedKey)) {
          final String saved => saved.split('\n').where((e) => e.isNotEmpty).toSet(),
          _ => {?activeId},
        };
    void setExpanded(Set<String> next) {
      expanded.value = next;
      prefs?.setString(_expandedKey, next.join('\n'));
    }

    final open = current.where((id) => profiles.any((p) => p.id == id)).toSet();
    final status = ref.watch(connectionNotifierProvider);
    final connected = status.valueOrNull is Connected || status.valueOrNull is HotReloading;
    final failure = switch (status) {
      AsyncError(:final ConnectionFailure error) => error,
      AsyncValue(valueOrNull: Disconnected(connectionFailure: final failure?)) => failure,
      _ => null,
    };
    final adding = ref.watch(addProfileNotifierProvider).isLoading;
    final liveness = ref.watch(happLivenessProvider);
    final linkStyle = TextStyle(fontSize: 13, color: c.subtitle, height: 1.2);

    Widget link(String text, VoidCallback onTap) => InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: linkStyle),
      ),
    );

    // The button and the row under it stay where they are; only the cards below scroll, under
    // the row, and keep their place when anything in them changes.
    return Column(
      children: [
        const HappConnectedSinceKeeper(),
        const Center(child: HappPowerButton()),
        SizedBox(
          height: 34,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // the left link takes all the room «Скрыть все» leaves (a Flexible beside a Spacer
                // got only half of it, «Проверить подклю…»), and shrinks a little rather than cut off
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: connected
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // the liveness of the tunnel: green ok, yellow being checked, red
                                // switching or no internet (nothing until the first probe)
                                if (liveness.level.light > 0) ...[
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(shape: BoxShape.circle, color: happLightColor(liveness.level)),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                link(
                                  happLivenessLine(context, liveness) ?? hr(context, 'Проверить подключение', 'Check the connection'),
                                  () => ref.read(bottomSheetsNotifierProvider.notifier).showConnectionHealth(),
                                ),
                              ],
                            )
                          : failure != null
                          ? link(hr(context, 'Подробнее об ошибке', 'Error details'), () {
                              final t = ref.read(translationsProvider).requireValue;
                              ref.read(dialogNotifierProvider.notifier).showCustomAlertFromErr(failure.present(t));
                            })
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                if (open.isNotEmpty) link(hr(context, 'Скрыть все', 'Hide all'), () => setExpanded({})),
              ],
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: CustomScrollView(
              key: const PageStorageKey('happ_home_cards'),
              controller: scroll,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 2)),
                if (adding)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: _AddingCard(colors: c),
                    ),
                  ),
                for (final p in profiles)
                  SliverToBoxAdapter(
                    key: ValueKey('happ_card_${p.id}'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: HappProfileCard(
                        profile: p,
                        expanded: open.contains(p.id),
                        onToggle: () => setExpanded(open.contains(p.id) ? ({...open}..remove(p.id)) : {...open, p.id}),
                        onExpand: () => setExpanded({...open, p.id}),
                      ),
                    ),
                  ),
                // room under the last card for the «Быстрые настройки» tab (32) laid over the bottom
                // edge, so the last card's header and buttons scroll fully clear of it
                const SliverToBoxAdapter(child: SizedBox(height: _quickSettingsTab + 32)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A subscription being added: the sheet closes at once and this card shows it is on its way;
/// ✕ stops it.
class _AddingCard extends ConsumerWidget {
  const _AddingCard({required this.colors});
  final HappColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: c.card,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 2, 8),
              child: Row(
                children: [
                  HappSpinningIcon(Icons.sync_rounded, spinning: true, color: c.icon),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      hr(context, 'Добавляется подписка…', 'Adding the subscription…'),
                      style: TextStyle(fontSize: 15, color: c.title),
                    ),
                  ),
                  _HeaderIcon(
                    tooltip: hr(context, 'Отменить', 'Cancel'),
                    onTap: () => ref.invalidate(addProfileNotifierProvider),
                    child: Icon(Icons.close_rounded, color: c.icon, size: 20),
                  ),
                ],
              ),
            ),
            LinearProgressIndicator(minHeight: 2, color: c.accent, backgroundColor: Colors.transparent),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// The subscription card

String _size(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(1).replaceAll('.', ',')}${units[u]}';
}

class HappProfileCard extends HookConsumerWidget {
  const HappProfileCard({
    super.key,
    required this.profile,
    required this.expanded,
    required this.onToggle,
    required this.onExpand,
  });

  final ProfileEntity profile;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = HappColors.of(context);
    final remote = switch (profile) {
      final RemoteProfileEntity r => r,
      _ => null,
    };
    final updating = ref.watch(updateProfileNotifierProvider(profile.id)).isLoading;
    // a brief «Обновлено» when an update of this card ends well
    ref.listen(updateProfileNotifierProvider(profile.id), (previous, next) {
      if (next case AsyncData(value: final _?) when previous?.isLoading ?? false) {
        // as a notification too, for whoever turned «Подписка обновлена» on (off by default)
        unawaited(
          happNotify(
            ref.read(sharedPreferencesProvider).valueOrNull,
            HappNotifyType.subUpdated,
            isRu: Localizations.maybeLocaleOf(context)?.languageCode == 'ru',
            profileId: profile.id,
            ru: ('Подписка обновлена', profile.name),
            en: ('Subscription updated', profile.name),
          ),
        );
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 2),
              content: Text(hr(context, 'Обновлено: ${profile.name}', 'Updated: ${profile.name}')),
            ),
          );
      }
    });
    final pinging = ref.watch(happPingPending.select((p) => p.containsKey(profile.id)));
    // «Найти самый быстрый» running on this subscription: «2/5» in the card's subtitle
    final speedProgress = ref.watch(happSpeedProgress.select((p) => p[profile.id]));
    final subInfo = remote?.subInfo;
    ref.watch(happAnnounceRevision);
    final announce = happAnnounceOf(ref.watch(sharedPreferencesProvider).valueOrNull, profile);
    final support = remote?.supportUrl;
    final hasSupport = support != null && support.isNotEmpty;

    // what the app updates by: the interval chosen in «Изменить», else the subscription's own
    // Build-42: while «Экономия трафика» is in effect the app updates far less often: the card says so
    final saving = ref.watch(happTrafficSavingProvider);
    final every = switch (profile) {
      RemoteProfileEntity(:final options) => happEffectiveUpdateEvery(
        options?.updateInterval,
        saving: saving,
        stretch: happSavingUpdateInterval,
      ),
      _ => null,
    };
    final hours = switch (profile) {
      RemoteProfileEntity() => every?.inHours ?? 0,
      _ => null,
    };
    final savingNote = saving && every != null ? hr(context, ' (экономия)', ' (saving)') : '';
    final updated = DateFormat('dd.MM.yyyy HH:mm').format(profile.lastUpdate.toLocal());
    final subtitle = switch (hours) {
      _ when updating => hr(context, 'Обновляется…', 'Updating…'),
      _ when speedProgress != null => hr(
        context,
        'Ищу самый быстрый: ${happSpeedProgressLabel(speedProgress.at, speedProgress.total)}',
        'Finding the fastest: ${happSpeedProgressLabel(speedProgress.at, speedProgress.total)}',
      ),
      null => updated,
      0 => '$updated | ${hr(context, 'Автообновление - выкл.', 'Auto update - off')}',
      final h => '$updated | ${hr(context, 'Автообновление - $h ч.', 'Auto update - $h h')}$savingNote',
    };

    final band = remote != null;
    final lineColor = band ? c.bandLine : c.rowLine;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: c.card,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // the header, with a thin bar along its bottom while the subscription updates. Only the
            // chevron on the left opens and closes the servers, as in Happ: a tap on the name, the
            // text or the strip under it does nothing, and the buttons beside them never reach the card
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
                  child: Row(
                    children: [
                      _HeaderIcon(
                        tooltip: expanded ? hr(context, 'Свернуть', 'Collapse') : hr(context, 'Развернуть', 'Expand'),
                        onTap: onToggle,
                        child: AnimatedRotation(
                          turns: expanded ? .5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(Icons.expand_more_rounded, color: c.icon, size: 26),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (profile.pinned ? '📌 ' : '') + profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 18, color: c.title, height: 1.2),
                            ),
                            const SizedBox(height: 1),
                            // shrinks a little rather than cut "Автообновление - 1 ч." short
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                style: TextStyle(fontSize: 12, color: c.subtitle),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (remote != null)
                        _HeaderIcon(
                          tooltip: hr(context, 'Обновить', 'Update'),
                          // while it updates, a new tap starts it again (a tap right after the
                          // first is the same tap); it never opens or closes the card
                          onTap: () => ref
                              .read(updateProfileNotifierProvider(profile.id).notifier)
                              .updateProfile(remote, restart: true),
                          child: HappSpinningIcon(Icons.sync_rounded, spinning: updating, color: c.icon),
                        ),
                      _HeaderIcon(
                        tooltip: hr(context, 'Пинг серверов', 'Ping servers'),
                        onTap: pinging ? null : () => _pingAll(context, ref),
                        child: HappPingIcon(active: pinging, color: c.icon),
                      ),
                      ProfileActionsMenu(
                        profile,
                        (context, toggle, _) => _HeaderIcon(
                          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                          onTap: toggle,
                          child: Icon(Icons.more_horiz_rounded, color: c.icon, size: 22),
                        ),
                      ),
                    ],
                  ),
                ),
                if (updating)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: c.accent,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
              ],
            ),
            if (band) ...[
              Container(height: 1, color: c.bandLine),
              ColoredBox(
                color: c.band,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  // the expiry date is always shown whole; the traffic bar takes what is left
                  child: LayoutBuilder(builder: (context, box) => Row(
                    children: [
                      _HeaderIcon(
                        tooltip: hr(context, 'О подписке', 'About the subscription'),
                        onTap: () => _showInfo(context, ref, remote),
                        child: Icon(Icons.info_outline_rounded, color: c.accent, size: 20),
                      ),
                      const SizedBox(width: 2),
                      if (subInfo != null) ...[
                        Expanded(child: _TrafficBar(subInfo, c)),
                        if (subInfo.expire.year < 2900 && subInfo.expire.year > 1971) ...[
                          const SizedBox(width: 8),
                          // its natural width, up to 55% of the strip; scaled down a little on a
                          // narrow screen rather than cut short
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: box.maxWidth * .55),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                '${hr(context, 'Истекает', 'Expires')}: ${DateFormat('dd.MM.yyyy').format(subInfo.expire.toLocal())}',
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: subInfo.isExpired ? const Color(0xFFE5484D) : c.title,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ] else
                        const Spacer(),
                      if (hasSupport)
                        _HeaderIcon(
                          tooltip: hr(context, 'Поддержка', 'Support'),
                          onTap: () => _openLink(ref, support),
                          child: Transform.rotate(
                            angle: -.35,
                            child: Icon(Icons.send_rounded, color: c.accent, size: 20),
                          ),
                        )
                      else
                        const SizedBox(width: 10),
                    ],
                  )),
                ),
              ),
            ],
            if (announce != null) ...[
              Container(height: 1, color: lineColor),
              Material(
                color: c.band,
                child: InkWell(
                  onTap: announce.link == null ? null : () => _openLink(ref, announce.link!),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(
                        announce.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: announce.color ?? c.title, height: 1.25),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(height: 1, color: lineColor),
                        HappServerList(profile: profile),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  /// Happ's speedometer: every server of this subscription tested through the core — the running
  /// one when connected to it, a proxy-only test core when nothing is connected.
  Future<void> _pingAll(BuildContext context, WidgetRef ref) async {
    onExpand();
    await happPingProfile(context, profile);
  }

  static Future<void> _openLink(WidgetRef ref, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final notifier = ref.read(dialogNotifierProvider.notifier);
    final t = ref.read(translationsProvider).requireValue;
    final bool ok;
    if (TrustedLinks.isTrusted(url)) {
      ok = await notifier.showConfirmation(
        title: t.components.subscriptionInfo.openLinkTitle,
        message: url,
        positiveBtnTxt: t.components.subscriptionInfo.openLinkAction,
      );
    } else {
      ok = await notifier.showUnknownDomainsWarning(url: url);
    }
    if (ok) await UriUtils.tryLaunch(uri);
  }

  void _showInfo(BuildContext context, WidgetRef ref, RemoteProfileEntity p) {
    final c = HappColors.of(context);
    final sub = p.subInfo;
    final rows = <(String, String)>[
      (hr(context, 'Название', 'Name'), p.name),
      (hr(context, 'Обновлено', 'Updated'), DateFormat('dd.MM.yyyy HH:mm').format(p.lastUpdate.toLocal())),
      if (sub != null) ...[
        (hr(context, 'Трафик', 'Traffic'), sub.total <= 0 ? '${_size(sub.consumption)} / ∞' : '${_size(sub.consumption)} / ${_size(sub.total)}'),
        if (sub.expire.year < 2900 && sub.expire.year > 1971)
          (hr(context, 'Истекает', 'Expires'), DateFormat('dd.MM.yyyy').format(sub.expire.toLocal())),
      ],
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (k, v) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 110, child: Text(k, style: TextStyle(color: c.subtitle))),
                      Expanded(child: Text(v)),
                    ],
                  ),
                ),
              if (p.webPageUrl case final url? when url.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.public_rounded, color: c.accent),
                  title: Text(hr(context, 'Сайт подписки', 'Subscription website')),
                  subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _openLink(ref, url);
                  },
                ),
              if (p.supportUrl case final url? when url.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.support_agent_rounded, color: c.accent),
                  title: Text(hr(context, 'Поддержка', 'Support')),
                  subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _openLink(ref, url);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.child, required this.onTap, required this.tooltip});
  final Widget child;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkResponse(
      onTap: onTap,
      radius: 20,
      child: SizedBox(width: 38, height: 38, child: Center(child: child)),
    ),
  );
}

class _TrafficBar extends StatelessWidget {
  const _TrafficBar(this.sub, this.c);
  final SubscriptionInfo sub;
  final HappColors c;

  @override
  Widget build(BuildContext context) {
    final unlimited = sub.total <= 0 || sub.total > 10 * 1099511627776;
    final text = unlimited ? '${_size(sub.consumption)}/∞' : '${_size(sub.consumption)}/${_size(sub.total)}';
    final ratio = unlimited ? 0.0 : sub.ratio;
    return Container(
      height: 21,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.subtitle.withValues(alpha: .45), width: 1),
        color: c.card.withValues(alpha: .5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          FractionallySizedBox(
            widthFactor: ratio == 0 ? 0 : math.max(ratio, .03),
            heightFactor: 1,
            child: ColoredBox(
              color: ratio >= 1 ? const Color(0xFFE5484D).withValues(alpha: .35) : c.subtitle.withValues(alpha: .35),
            ),
          ),
          Center(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(fontSize: 13, color: c.title),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// The servers of an open card

class HappServerList extends HookConsumerWidget {
  const HappServerList({super.key, required this.profile});
  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = HappColors.of(context);
    final activeId = ref.watch(activeProfileProvider.select((p) => p.valueOrNull?.id));
    final isActive = activeId == profile.id;
    final running = ref.watch(serviceRunningProvider);
    final live = running && isActive ? ref.watch(proxiesOverviewNotifierProvider).valueOrNull : null;
    final offline = ref.watch(happServersProvider(profile.id)).valueOrNull ?? const <HappServer>[];
    final details = {for (final s in offline) s.tag: s};
    final order = {for (final (i, s) in offline.indexed) s.tag: i};
    final pins = pinnedSet(ref.watch(HappifyPrefs.pinnedServers));
    final showGroups = ref.watch(HappifyPrefs.showBalancers);
    final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    ref.watch(happPingCacheRevision);
    final cached = happReadPingCache(prefs, profile.id);
    final pending = ref.watch(happPingPending.select((p) => p[profile.id]));
    // this subscription's own «Сортировка серверов» (its «Изменить» sheet)
    final sortRule = ref.watch(happProfileSortProvider(profile.id));
    // «↓ N Мбит/с» from a speed test of the last hour, and the servers being tested now
    ref.watch(happSpeedRevision);
    final speeds = happSpeedCacheOf(prefs, profile.id);
    final speedTesting = ref.watch(happSpeedPending.select((p) => p[profile.id])) ?? const <String>{};
    final now = DateTime.now();
    // the order the rows had last, kept while this card's ping test runs (by ping, the rows move
    // once, when it is done, rather than with every result)
    final lastOrder = useRef<({String key, List<String> tags})?>(null);
    final picked = useState<String?>(null);
    // the row the user just tapped: a small spinner on it until the core has switched
    final switching = useState<String?>(null);
    // last tap wins: only the newest tap's switch clears the spinner and shows its message
    final taps = useRef(HappLatestWins());
    final isMounted = useIsMounted();
    final lastKey = 'happify_last_server_${profile.id}';

    final liveItems = live == null
        ? const <OutboundInfo>[]
        : live.items
              .where((e) => e.isVisible && (!e.isGroup || (showGroups && (e.tag == lowestGroupTag || e.tag == balanceGroupTag))))
              .toList();
    // what the core measured since it started, kept for the rows while disconnected; the delay it
    // only sorted by (from an earlier run) is shown, but never saved as a new measurement
    final measured = {
      for (final p in liveItems)
        if (!p.isGroup)
          if (ConnectionConst.isValidDelay(p.urlTestDelay))
            p.tag: p.urlTestDelay
          else if (p.urlTestDelay >= ConnectionConst.maxDelay)
            p.tag: -1,
    };
    useEffect(() {
      if (prefs == null || measured.isEmpty) return null;
      final merged = {...happReadPingCache(prefs, profile.id), ...measured};
      final raw = jsonEncode(merged);
      if (prefs.getString(happPingCacheKey(profile.id)) != raw) {
        Future.microtask(() async {
          await prefs.setString(happPingCacheKey(profile.id), raw);
        });
      }
      return null;
    }, [jsonEncode(measured)]);

    void snack(String ru, String en) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(hr(context, ru, en))));
    }

    String cleanOf(String name) {
      final clean = happCleanName(name);
      return clean.isEmpty ? name : clean;
    }

    // names that repeat in this subscription get their protocol: «Стокгольм #1 | VLESS» (display only)
    final titles = live != null && liveItems.isNotEmpty
        ? happServerTitles([
            for (final p in liveItems)
              if (!p.isGroup)
                (
                  tag: p.tag,
                  name: cleanOf(p.tagDisplay.isEmpty ? p.tag : p.tagDisplay),
                  type: details[p.tag]?.type ?? p.typeWithoutStatus,
                  detail: details[p.tag]?.detail ?? '',
                ),
          ])
        : happServerTitles([for (final s in offline) (tag: s.tag, name: cleanOf(s.tag), type: s.type, detail: s.detail)]);

    String display(String tag) => titles[tag] ?? cleanOf(tag);

    // the switch goes on even when the card is closed meanwhile: the app's container, not the row's ref
    final app = ProviderScope.containerOf(context, listen: false);

    /// Connected to this subscription: switch at once, a spinner on the row until the core has
    /// taken it, then «Подключено к …». Last tap wins: a tap while a switch runs is not ignored, it
    /// replaces it; the spinner always clears (≤8 s), whatever the core does.
    Future<void> switchLive(String group, String tag) async {
      final ticket = taps.value.begin();
      switching.value = tag;
      var confirmed = false;
      try {
        confirmed = await happWithDeadline<bool>(
          () async {
            final ok = await app.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group, tag);
            if (!ok) return false;
            // the core said yes; its list says so too within a moment
            final until = DateTime.now().add(const Duration(seconds: 2));
            while (DateTime.now().isBefore(until) && taps.value.isLatest(ticket) && isMounted()) {
              if (app.read(proxiesOverviewNotifierProvider).valueOrNull?.selected == tag) break;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            return true;
          },
          deadline: happSwitchDeadline,
          fallback: false,
        );
      } finally {
        if (isMounted() && taps.value.isLatest(ticket)) switching.value = null;
      }
      if (!isMounted() || !taps.value.isLatest(ticket)) return;
      final name = display(tag);
      if (confirmed) {
        snack('Подключено к $name', 'Connected to $name');
      } else {
        snack('Не удалось переключиться на $name', 'Could not switch to $name');
      }
    }

    /// Not connected to this subscription: pick the server and connect to it. Last tap wins here
    /// too; the spinner clears once the connect is under way (≤10 s), never waits forever.
    Future<void> pickOffline(String tag) async {
      final ticket = taps.value.begin();
      switching.value = tag;
      picked.value = tag;
      try {
        await prefs?.setString(lastKey, tag);
        // picked as soon as the core is up with this profile, even with "Last server" off
        await prefs?.setString(happifyPickNextKey, '${profile.id}\n$tag');
        if (!taps.value.isLatest(ticket)) return;
        await happWithDeadline<void>(
          () => app.read(Preferences.startedByUser.notifier).update(true),
          deadline: happSelectDeadline,
          fallback: null,
        );
        if (app.read(activeProfileProvider).valueOrNull?.id != profile.id) {
          // the profile becomes the active one; a running tunnel reconnects to it by itself
          await happWithDeadline<void>(
            () => app.read(profilesNotifierProvider.notifier).selectActiveProfile(profile.id),
            deadline: happSelectDeadline,
            fallback: null,
          );
          for (var i = 0; i < 20 && app.read(activeProfileProvider).valueOrNull?.id != profile.id; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        if (!taps.value.isLatest(ticket)) return;
        if (!app.read(serviceRunningProvider)) {
          // the notice is a dialog: it waits for the user, not on a clock
          if (await app.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            if (!taps.value.isLatest(ticket)) return;
            await happWithDeadline<void>(
              () => app.read(connectionNotifierProvider.notifier).mayConnect(),
              deadline: const Duration(seconds: 10),
              fallback: null,
            );
          }
        }
      } catch (_) {
        // a failed step never keeps the spinner; the connect button shows the state
      } finally {
        if (isMounted() && taps.value.isLatest(ticket)) switching.value = null;
      }
    }

    /// The rows in the order the rule gives, pinned ones first; a switch never moves a row.
    List<String> ordered(List<HappSortItem> items) {
      final fresh = happSortServers(items, sortRule, pins);
      final key = '${sortRule.name}|${(pins.toList()..sort()).join(',')}';
      final last = lastOrder.value;
      if (sortRule == ProxiesSort.delay && pending != null && last != null && last.key == key) {
        final present = fresh.toSet();
        final kept = [
          for (final t in last.tags)
            if (present.contains(t)) t,
        ];
        final keptSet = kept.toSet();
        return [
          ...kept,
          for (final t in fresh)
            if (!keptSet.contains(t)) t,
        ];
      }
      lastOrder.value = (key: key, tags: fresh);
      return fresh;
    }

    if (live != null && liveItems.isNotEmpty) {
      // lowest first, then balance; the servers in the order of the rule
      final groups = liveItems.where((e) => e.isGroup).toList()
        ..sort((a, b) => (a.tag == lowestGroupTag ? 0 : 1).compareTo(b.tag == lowestGroupTag ? 0 : 1));
      final byTag = {
        for (final p in liveItems)
          if (!p.isGroup) p.tag: p,
      };
      final servers = [
        for (final tag in ordered([
          for (final (i, p) in liveItems.indexed)
            if (!p.isGroup)
              (
                tag: p.tag,
                name: display(p.tag),
                index: order[p.tag] ?? (1 << 19) + i,
                ping: happCoreDelay(p) ?? cached[p.tag],
                country:
                    happCountryFromName(p.tagDisplay.isEmpty ? p.tag : p.tagDisplay) ??
                    (p.ipinfo.countryCode.isEmpty ? null : p.ipinfo.countryCode),
              ),
        ]))
          byTag[tag]!,
      ];
      final selected = switching.value ?? live.selected;
      Widget row(OutboundInfo proxy) => HappServerRow(
        key: ValueKey(proxy.tag),
        name: proxy.tagDisplay.isEmpty ? proxy.tag : proxy.tagDisplay,
        title: titles[proxy.tag],
        countryCode: proxy.isGroup ? null : proxy.ipinfo.countryCode,
        groupIcon: _groupIcon(proxy.tag),
        // lowest and balance: the server they use now (build-41)
        subtitle: proxy.isGroup
            ? happGroupNowLabel(
                selectedTag: proxy.hasGroupSelectedTag() ? proxy.groupSelectedTag : null,
                groupTag: proxy.tag,
                display: display,
                members: servers.length,
                ru: Localizations.maybeLocaleOf(context)?.languageCode == 'ru',
              )
            : details[proxy.tag]?.subtitle ?? '${proxy.typeWithoutStatus.toUpperCase()} | JSON',
        ping: happCoreDelay(proxy),
        speed: proxy.isGroup ? null : happFreshSpeed(speeds, proxy.tag, now),
        measuring: (pending?.containsKey(proxy.tag) ?? false) || speedTesting.contains(proxy.tag),
        switching: switching.value == proxy.tag,
        pinned: pins.contains(proxy.tag),
        selected: selected == proxy.tag,
        onTap: () => switchLive(live.tag, proxy.tag),
        onLongPress: () => _longPress(context, ref, proxy.tag, proxy: proxy),
        colors: c,
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final proxy in groups) row(proxy),
          for (final proxy in servers) row(proxy),
        ],
      );
    }

    if (offline.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          hr(context, 'Нет серверов', 'No servers'),
          style: TextStyle(color: c.subtitle),
        ),
      );
    }
    final saved = switching.value ?? picked.value ?? prefs?.getString(lastKey);
    final sorted = [
      for (final tag in ordered([
        for (final (i, s) in offline.indexed)
          (tag: s.tag, name: display(s.tag), index: i, ping: cached[s.tag], country: happCountryFromName(s.tag)),
      ]))
        details[tag]!,
    ];
    // the core makes lowest and balance itself; listed here too when the user asked for them
    Widget offlineRow(({String tag, String subtitle, IconData? icon}) s) => HappServerRow(
      key: ValueKey(s.tag),
      name: s.tag,
      title: titles[s.tag],
      countryCode: null,
      groupIcon: s.icon,
      subtitle: s.subtitle,
      // the last delay the core measured; nothing when it never did
      ping: cached[s.tag],
      speed: happFreshSpeed(speeds, s.tag, now),
      measuring: pending?.containsKey(s.tag) ?? false,
      switching: switching.value == s.tag,
      pinned: pins.contains(s.tag),
      selected: (isActive || switching.value != null) && s.tag == saved,
      onTap: () => pickOffline(s.tag),
      onLongPress: () => _longPress(context, ref, s.tag),
      colors: c,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showGroups) ...[
          offlineRow((tag: lowestGroupTag, subtitle: _groupSubtitle(context, lowestGroupTag), icon: _groupIcon(lowestGroupTag))),
          offlineRow((tag: balanceGroupTag, subtitle: _groupSubtitle(context, balanceGroupTag), icon: _groupIcon(balanceGroupTag))),
        ],
        for (final s in sorted) offlineRow((tag: s.tag, subtitle: s.subtitle, icon: null)),
      ],
    );
  }

  static IconData? _groupIcon(String tag) => switch (tag) {
    lowestGroupTag => Icons.bolt_rounded,
    balanceGroupTag => Icons.call_split_rounded,
    _ => null,
  };

  static String _groupSubtitle(BuildContext context, String tag) => switch (tag) {
    lowestGroupTag => hr(context, 'Самый быстрый сервер', 'The fastest server'),
    balanceGroupTag => hr(context, 'Нагрузка на все серверы', 'Spread over all servers'),
    _ => tag.toUpperCase(),
  };

  /// Pin to the top, or the details of a live server, as the proxies page offers.
  Future<void> _longPress(BuildContext context, WidgetRef ref, String tag, {OutboundInfo? proxy}) async {
    final pins = pinnedSet(ref.read(HappifyPrefs.pinnedServers));
    final isPinned = pins.contains(tag);
    final isGroup = (proxy?.isGroup ?? false) || tag == lowestGroupTag || tag == balanceGroupTag;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isGroup)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: Text(hr(context, 'Тест скорости', 'Speed test')),
                subtitle: Text(hr(context, 'Скачает 2–5 МБ через этот сервер', 'Downloads 2–5 MB through this server')),
                onTap: () => Navigator.of(context).pop('speed'),
              ),
            if (!isGroup)
              ListTile(
                leading: Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
                title: Text(isPinned ? hr(context, 'Открепить', 'Unpin') : hr(context, 'Закрепить вверху', 'Pin to top')),
                onTap: () => Navigator.of(context).pop('pin'),
              ),
            if (proxy != null)
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(hr(context, 'Подробнее', 'Details')),
                onTap: () => Navigator.of(context).pop('info'),
              ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'speed' when context.mounted:
        await happSpeedTest(context, profile, [tag]);
      case 'pin':
        isPinned ? pins.remove(tag) : pins.add(tag);
        await ref.read(HappifyPrefs.pinnedServers.notifier).update(pins.join('\n'));
      case 'info' when proxy != null:
        await ref.read(dialogNotifierProvider.notifier).showProxyInfo(outboundInfo: proxy);
    }
  }
}

class HappServerRow extends StatelessWidget {
  const HappServerRow({
    super.key,
    required this.name,
    required this.countryCode,
    required this.subtitle,
    required this.ping,
    required this.pinned,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.colors,
    this.measuring = false,
    this.switching = false,
    this.groupIcon,
    this.title,
    this.speed,
  });

  final String name;

  /// What the row shows in place of [name] (without its flag), such as «Стокгольм #1 | VLESS»
  /// for a name that repeats; [name] still gives the flag.
  final String? title;

  /// The IP's country when the name has no flag.
  final String? countryCode;

  /// lowest and balance: an icon in place of the flag.
  final IconData? groupIcon;
  final String subtitle;

  /// Milliseconds; -1 when it did not answer; null when not measured.
  final int? ping;

  /// Bytes/s from a speed test of the last hour; null when none.
  final int? speed;
  final bool measuring;

  /// Tapped, and the switch to it is under way.
  final bool switching;

  final bool pinned;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final HappColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final flag = happFlagCode(name) ?? ((countryCode?.isNotEmpty ?? false) ? countryCode : null);
    final clean = happCleanName(name);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: selected ? c.selectedRow : c.row,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Row(
                children: [
                  if (groupIcon case final icon?)
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(color: c.accent.withValues(alpha: .18), borderRadius: BorderRadius.circular(6)),
                      child: Icon(icon, color: c.accent, size: 20),
                    )
                  else
                    HappFlag(flag, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (pinned ? '📌 ' : '') + (title ?? (clean.isEmpty ? name : clean)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: c.title,
                            fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.subtitle, height: 1.2),
                        ),
                      ],
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOut,
                    child: measuring || switching
                        ? Padding(
                            key: ValueKey(switching ? 'switching' : 'measuring'),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 1.6, color: switching ? c.accent : c.subtitle),
                            ),
                          )
                        : switch (ping) {
                            final p? => Text(
                              p < 0 ? '—' : '$p ${hr(context, 'мс', 'ms')}',
                              key: ValueKey('ping$p'),
                              style: TextStyle(
                                fontSize: 13,
                                // red for a server that did not answer the URL test
                                color: p < 0 ? const Color(0xFFE5484D).withValues(alpha: .8) : c.subtitle,
                              ),
                            ),
                            null => const SizedBox.shrink(key: ValueKey('none')),
                          },
                  ),
                  if (speed case final bps? when !measuring && !switching)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 6),
                      child: Text(
                        happSpeedLabel(bps, ru: Localizations.maybeLocaleOf(context)?.languageCode == 'ru'),
                        style: TextStyle(fontSize: 12, color: c.accent),
                      ),
                    ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, color: c.subtitle.withValues(alpha: .7), size: 22),
                ],
              ),
            ),
          ),
        ),
        Container(height: 1, color: c.rowLine),
      ],
    );
  }
}

/// An icon that turns round and round while [spinning] (a subscription updating).
class HappSpinningIcon extends HookWidget {
  const HappSpinningIcon(this.icon, {super.key, required this.spinning, required this.color, this.size = 22});
  final IconData icon;
  final bool spinning;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final controller = useAnimationController(duration: const Duration(milliseconds: 900));
    useEffect(() {
      if (spinning) {
        controller.repeat();
      } else if (controller.isAnimating || controller.value != 0) {
        // finish the turn it is in rather than jump back, and always end at rest: a new spin that
        // starts meanwhile takes over, and a stop never leaves it turning
        controller.stop();
        controller
            .animateTo(1, duration: controller.duration! * (1 - controller.value))
            .whenCompleteOrCancel(() {
              // not after the icon is gone: its controller is disposed by then
              if (context.mounted && !controller.isAnimating) controller.value = 0;
            });
      }
      return null;
    }, [spinning]);
    return RotationTransition(
      // sync_rounded's arrows go clockwise
      turns: controller,
      child: Icon(icon, color: color, size: size),
    );
  }
}

/// Happ's speedometer: while a test runs, it pulses and its needle swings.
class HappPingIcon extends HookWidget {
  const HappPingIcon({super.key, required this.active, required this.color, this.size = 22});
  final bool active;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final controller = useAnimationController(duration: const Duration(milliseconds: 700));
    useEffect(() {
      if (active) {
        controller.repeat(reverse: true);
      } else {
        controller.animateTo(0, duration: const Duration(milliseconds: 150));
      }
      return null;
    }, [active]);
    final icon = Icon(Icons.speed_rounded, color: color, size: size);
    return AnimatedBuilder(
      animation: controller,
      child: icon,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(controller.value);
        return Transform.scale(
          scale: 1 + .12 * t,
          child: Transform.rotate(angle: (t - .5) * .5 * (active ? 1 : 0), child: child),
        );
      },
    );
  }
}

/// The colour of the liveness dot: green, yellow, red.
Color happLightColor(HappLiveness level) => switch (level.light) {
  1 => const Color(0xFF30A46C),
  2 => const Color(0xFFE3A63A),
  _ => const Color(0xFFE5484D),
};

/// What the row under the button says instead of «Проверить подключение» while something is
/// wrong, or while a reserve server is in use; null when all is well.
String? happLivenessLine(BuildContext context, HappLivenessState state) => switch (state.level) {
  HappLiveness.noInternet => hr(context, 'Нет интернета', 'No internet'),
  HappLiveness.switching => hr(context, 'Переключаю сервер…', 'Switching server…'),
  HappLiveness.bad => hr(context, 'Сервер не отвечает', 'Server not answering'),
  HappLiveness.warn => hr(context, 'Проверяю связь…', 'Checking the connection…'),
  HappLiveness.ok when state.movedTo != null => hr(
    context,
    'Резерв: ${happCleanName(state.movedTo!)}',
    'Reserve: ${happCleanName(state.movedTo!)}',
  ),
  _ => null,
};
