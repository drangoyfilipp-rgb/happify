import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_home.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/reliability/happ_clash_api.dart';
import 'package:hiddify/features/happ/reliability/happ_core_log.dart';
import 'package:hiddify/features/happ/reliability/happ_core_log_tap.dart';
import 'package:hiddify/features/happ/reliability/happ_diag_rule.dart';
import 'package:hiddify/features/happ/reliability/happ_platform.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

// «Диагностика»: the connections that failed lately, by app. Passive: built from what the core
// already logs and the list of open connections it already keeps; no request of its own.

class HappDiagRecord {
  HappDiagRecord({required this.at, required this.failure, this.package});

  final DateTime at;
  final HappCoreFailure failure;

  /// The app it came from; null while unknown.
  String? package;
}

class HappDiagnostics extends Notifier<List<HappDiagRecord>> {
  static const _keep = 300;

  /// Host (or IP) → the app that opened a connection to it lately, and when it was seen.
  final _owners = <String, ({String package, DateTime seen})>{};
  Timer? _poll;
  bool _screenOn = true;
  StreamSubscription<Object?>? _failures;
  StreamSubscription<bool>? _screen;

  @override
  List<HappDiagRecord> build() {
    _failures = HappCoreLogTap.failures.listen((e) => _add(e.at, e.failure));
    _screen = HappPlatform.screen.listen((on) {
      _screenOn = on;
      _updatePolling();
    });
    ref.listen(serviceRunningProvider, (_, _) => _updatePolling());
    ref.listen(happDiagAppsRuleProvider, (_, _) => _updatePolling());
    ref.onDispose(() {
      _poll?.cancel();
      unawaited(_failures?.cancel());
      unawaited(_screen?.cancel());
    });
    Future.microtask(_updatePolling);
    return const [];
  }

  void clear() {
    state = const [];
    _owners.clear();
  }

  void _add(DateTime at, HappCoreFailure failure) {
    // the app's own probes go through "select"/"direct" from the core itself and never reach the
    // log as an app's connection; nothing to filter
    final host = failure.host;
    final record = HappDiagRecord(at: at, failure: failure, package: host == null ? null : _owners[host]?.package);
    final next = [record, ...state];
    state = next.length > _keep ? next.sublist(0, _keep) : next;
  }

  /// The open connections are read every 3 s while connected, the screen is on and app detection
  /// is on: they say which app talks to which host.
  void _updatePolling() {
    final want = ref.read(serviceRunningProvider) && ref.read(happDiagAppsRuleProvider) && _screenOn;
    if (!want) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_readConnections()));
  }

  bool _reading = false;

  Future<void> _readConnections() async {
    if (_reading) return;
    final options = ref.read(ConfigOptions.singboxConfigOptions);
    if (!options.enableClashApi || options.webSecret.isEmpty) return;
    _reading = true;
    try {
      final list = await HappClashApi(port: options.clashApiPort, secret: options.webSecret).connections();
      final now = DateTime.now();
      for (final c in list) {
        final meta = c['metadata'];
        if (meta is! Map) continue;
        final package = happPackageOfProcessPath(meta['processPath'] as String?);
        if (package == null) continue;
        for (final key in [meta['host'], meta['destinationIP']]) {
          if (key is String && key.isNotEmpty) _owners[key] = (package: package, seen: now);
        }
      }
      _owners.removeWhere((_, v) => now.difference(v.seen) > const Duration(minutes: 10));
      // a failure logged a moment before its app was seen gets its app now
      var changed = false;
      for (final r in state) {
        if (now.difference(r.at) > const Duration(seconds: 20)) break;
        final host = r.failure.host;
        if (r.package == null && host != null && _owners[host] != null) {
          r.package = _owners[host]!.package;
          changed = true;
        }
      }
      if (changed) state = [...state];
    } on HappClashUnavailable {
      // not connected yet, or a core started before the key: nothing to read
    } catch (_) {
      // a list that could not be read this time
    } finally {
      _reading = false;
    }
  }
}

final happDiagnosticsProvider = NotifierProvider<HappDiagnostics, List<HappDiagRecord>>(HappDiagnostics.new);

String happFailureKindLabel(BuildContext context, HappFailureKind kind) => switch (kind) {
  HappFailureKind.timeout => hr(context, 'таймаут', 'timeout'),
  HappFailureKind.reset => hr(context, 'обрыв', 'reset'),
  HappFailureKind.refused => hr(context, 'отказ', 'refused'),
  HappFailureKind.dns => 'DNS',
  HappFailureKind.tls => 'TLS',
  HappFailureKind.other => hr(context, 'ошибка', 'error'),
};

/// The «Диагностика» screen.
class HappDiagnosticsPage extends ConsumerStatefulWidget {
  const HappDiagnosticsPage({super.key});

  @override
  ConsumerState<HappDiagnosticsPage> createState() => _HappDiagnosticsPageState();
}

class _HappDiagnosticsPageState extends ConsumerState<HappDiagnosticsPage> {
  final _labels = <String, String>{};
  final _icons = <String, MemoryImage?>{};

  Future<void> _loadApps(Iterable<String> packages) async {
    final missing = packages.where((p) => !_labels.containsKey(p)).toList();
    if (missing.isEmpty) return;
    for (final p in missing) {
      _labels[p] = p;
    }
    final labels = await HappPlatform.appLabels(missing);
    for (final p in missing) {
      try {
        final b64 = await const MethodChannel('com.hiddify.app/platform').invokeMethod<String>('get_package_icon', {'packageName': p});
        _icons[p] = b64 == null ? null : MemoryImage(base64Decode(b64));
      } catch (_) {
        _icons[p] = null;
      }
    }
    if (!mounted) return;
    setState(() => _labels.addAll(labels));
  }

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(happDiagnosticsProvider);
    final detect = ref.watch(happDiagAppsPref);
    final theme = Theme.of(context);
    final groups = <String?, List<HappDiagRecord>>{};
    for (final r in records) {
      groups.putIfAbsent(r.package, () => []).add(r);
    }
    final order = groups.keys.toList()
      ..sort((a, b) {
        if ((a == null) != (b == null)) return a == null ? 1 : -1;
        return groups[b]!.length.compareTo(groups[a]!.length);
      });
    unawaited(_loadApps(groups.keys.whereType<String>()));
    final time = DateFormat('HH:mm:ss');

    return Scaffold(
      appBar: AppBar(
        title: Text(hr(context, 'Диагностика', 'Diagnostics')),
        actions: [
          if (records.isNotEmpty)
            IconButton(
              tooltip: hr(context, 'Очистить', 'Clear'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => ref.read(happDiagnosticsProvider.notifier).clear(),
            ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              hr(
                context,
                'Здесь соединения, которые не удались за время работы приложения: куда, что за ошибка и каким путём (напрямую или через какой сервер). Дополнительного трафика нет: это то, что ядро и так видит.\n\nНе видно блокировок внутри HTTPS: если сайт открылся, но написал «недоступно в вашей стране», для VPN это успешное соединение.',
                'Connections that failed while the app runs: where to, what error, and which way (direct or through which server). No extra traffic: this is what the core sees anyway.\n\nBlocks inside HTTPS aren\'t visible: a site that opens and says "not available in your country" is a successful connection to the VPN.',
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (PlatformUtils.isAndroid)
            SwitchListTile.adaptive(
              title: Text(hr(context, 'Определять приложение', 'Detect the app')),
              subtitle: Text(
                hr(
                  context,
                  'Ядро узнаёт у Android, какое приложение открыло соединение. Без трафика. Меняется при следующем подключении',
                  'The core asks Android which app opened each connection. No traffic. Applies on the next connection',
                ),
              ),
              value: detect,
              onChanged: ref.read(happDiagAppsPref.notifier).update,
            ),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                hr(context, 'Пока сбоев не было 👍', 'No failures so far 👍'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          for (final package in order)
            ExpansionTile(
              leading: package == null
                  ? const CircleAvatar(child: Icon(Icons.help_outline_rounded))
                  : (_icons[package] != null
                        ? CircleAvatar(backgroundImage: _icons[package], backgroundColor: Colors.transparent)
                        : const CircleAvatar(child: Icon(Icons.android_rounded))),
              title: Text(
                package == null ? hr(context, 'Приложение не определено', 'App unknown') : (_labels[package] ?? package),
              ),
              subtitle: Text(
                [
                  hr(context, 'сбоев: ${groups[package]!.length}', 'failures: ${groups[package]!.length}'),
                  if (package != null && _labels[package] != package) package,
                ].join(' · '),
              ),
              children: [
                for (final r in groups[package]!.take(60))
                  ListTile(
                    dense: true,
                    title: Text(
                      '${r.failure.host ?? hr(context, 'неизвестно куда', 'unknown destination')}${r.failure.port != null ? ':${r.failure.port}' : ''}',
                    ),
                    subtitle: Text(
                      [
                        time.format(r.at),
                        happFailureKindLabel(context, r.failure.kind),
                        if (r.failure.outboundType == null)
                          hr(context, 'путь неизвестен', 'route unknown')
                        else if (r.failure.direct)
                          hr(context, 'напрямую', 'direct')
                        else
                          '${hr(context, 'через', 'via')} ${happCleanName(r.failure.outboundTag ?? r.failure.outboundType!)}',
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

