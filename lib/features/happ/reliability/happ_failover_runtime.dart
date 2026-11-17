import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_home.dart';
import 'package:hiddify/features/happ/happify_last_server.dart';
import 'package:hiddify/features/happ/happify_server_sort.dart';
import 'package:hiddify/features/happ/reliability/happ_clash_api.dart';
import 'package:hiddify/features/happ/reliability/happ_core_log_tap.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_machine.dart';
import 'package:hiddify/features/happ/reliability/happ_notifications.dart';
import 'package:hiddify/features/happ/reliability/happ_notify_rules.dart';
import 'package:hiddify/features/happ/reliability/happ_platform.dart';
import 'package:hiddify/features/happ/reliability/happ_user_pick.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// «Автопереключение при сбое» (on by default, silent). The old «Менять нерабочий сервер»
/// (happify_auto_switch_dead) switched on a single failed ping and overwrote the user's server;
/// a user who had turned it off keeps it off here.
final happFailoverPref = PreferencesNotifier.create<bool, bool>("happify_failover", true);

/// What the indicator shows now, with the server the connection moved to when it moved by itself.
typedef HappLivenessState = ({HappLiveness level, String? movedTo});

final happLivenessProvider = StateProvider<HappLivenessState>((ref) => (level: HappLiveness.idle, movedTo: null));

/// Runs the liveness probe and the failover while connected (kept alive by HappifyLifecycle).
final happFailoverRuntimeProvider = Provider<void>((ref) {
  final connected = ref.watch(
    connectionNotifierProvider.select((s) => s.valueOrNull is Connected || s.valueOrNull is HotReloading),
  );
  ref.watch(coreRestartSignalProvider);
  final profileId = ref.watch(activeProfileProvider.select((p) => p.valueOrNull?.id));
  // only what the runtime uses: any other setting changed (the routing, the DNS…) must not start it
  // over, which would forget the user's server's hold against flapping
  final options = ref.watch(
    ConfigOptions.singboxConfigOptions.select(
      (o) => (
        enableClashApi: o.enableClashApi,
        clashApiPort: o.clashApiPort,
        webSecret: o.webSecret,
        connectionTestUrl: o.connectionTestUrl,
      ),
    ),
  );
  void idle() {
    // after this build: a provider may not change another while it builds
    Future.microtask(() {
      ref.read(happLivenessProvider.notifier).state = (level: HappLiveness.idle, movedTo: null);
      unawaited(HappPlatform.setLiveness(HappLiveness.idle));
    });
  }

  if (!connected || profileId == null || !options.enableClashApi || options.webSecret.isEmpty) {
    idle();
    return;
  }
  final runtime = HappFailoverRuntime(
    ref,
    profileId: profileId,
    api: HappClashApi(port: options.clashApiPort, secret: options.webSecret),
    testUrl: options.connectionTestUrl,
  );
  // after this build: the runtime changes other providers, which no provider may do while it builds
  Future.microtask(runtime.start);
  ref.onDispose(() {
    runtime.dispose();
    idle();
  });
});

/// The liveness probe and the failover of one connection: feeds [machine] the probes, the screen,
/// the core's selection and the user's picks ([happUserPickProvider]), and does what it answers.
class HappFailoverRuntime with InfraLogger {
  HappFailoverRuntime(
    this.ref, {
    required this.profileId,
    required this.api,
    required this.testUrl,
    HappFailoverTiming timing = const HappFailoverTiming(),
    @visibleForTesting Stream<bool>? screenEvents,
    @visibleForTesting Future<bool> Function()? isScreenOn,
    @visibleForTesting this.busyRetry = const Duration(seconds: 3),
    @visibleForTesting this.ownSwitchGrace = const Duration(seconds: 15),
  }) : machine = HappFailoverMachine(timing: timing, autoSwitch: ref.read(happFailoverPref)),
       _screenEvents = screenEvents,
       _isScreenOn = isScreenOn;

  final Ref ref;
  final String profileId;
  final HappClashApi api;
  final String testUrl;

  /// A probe that comes while another check runs waits this long and tries again.
  final Duration busyRetry;

  /// How long the core may keep reporting the old server after this runtime switched: it reports
  /// the old one for 2–3 s, which is neither the user nor a change.
  final Duration ownSwitchGrace;

  final Stream<bool>? _screenEvents;
  final Future<bool> Function()? _isScreenOn;

  final HappFailoverMachine machine;
  final burst = HappFailureBurst();
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;

  /// A probe, a direct check or a search for a replacement is under way.
  bool _busy = false;

  /// Bumped when the user picks a server: a check that began before is dropped.
  int _epoch = 0;

  /// For tests: whether a probe is scheduled.
  @visibleForTesting
  bool get probeScheduled => _timer?.isActive ?? false;

  /// The server this runtime selected and is waiting for the core to report, until when.
  String? _ourSwitch;
  DateTime? _ourSwitchUntil;
  OutboundGroup? _group;

  /// The server in use as of the last step applied.
  String? _inUse;
  bool _inUseIsGroup = false;
  DateTime? _lastNoInternetNotice;
  final _subs = <StreamSubscription<Object?>>[];
  final _listeners = <ProviderSubscription<Object?>>[];

  void start() {
    if (_disposed) return;
    _listeners.add(ref.listen<bool>(happFailoverPref, (_, on) => machine.autoSwitch = on));
    _listeners.add(
      ref.listen<AsyncValue<OutboundGroup?>>(
        proxiesOverviewNotifierProvider,
        (_, next) => _onGroup(next.valueOrNull),
        fireImmediately: true,
      ),
    );
    // the user's picks: the only thing that makes a server theirs
    _listeners.add(
      ref.listen<HappUserPick?>(happUserPickProvider, (_, pick) {
        if (pick != null) _onUserPick(pick);
      }),
    );
    _subs.add((_screenEvents ?? HappPlatform.screen).listen((on) => _apply(machine.onScreen(on: on, now: DateTime.now()))));
    _subs.add(HappCoreLogTap.failures.listen((e) => _onFailure(e.at, e.failure.host, e.failure.viaProxy)));
    unawaited(
      (_isScreenOn ?? HappPlatform.isScreenOn)().then((on) {
        if (!_disposed) machine.screenOn = on;
      }),
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    for (final l in _listeners) {
      l.close();
    }
  }

  static bool _isGroupTag(String tag) => tag == lowestGroupTag || tag == balanceGroupTag;

  bool _itemIsGroup(OutboundGroup group, String tag) =>
      group.items.where((e) => e.tag == tag).firstOrNull?.isGroup ?? _isGroupTag(tag);

  /// The server the user picked last in this subscription, when it is still in the list.
  String? _savedChoice(OutboundGroup group) {
    final saved = ref.read(sharedPreferencesProvider).valueOrNull?.getString(happLastServerKey(profileId));
    if (saved == null || !group.items.any((e) => e.tag == saved)) return null;
    return saved;
  }

  void _onGroup(OutboundGroup? group) {
    if (_disposed || group == null || group.items.isEmpty || group.selected.isEmpty) return;
    _group = group;
    final selected = group.selected;
    if (!_started) {
      _started = true;
      final saved = _savedChoice(group);
      _apply(
        machine.start(
          current: selected,
          currentIsGroup: _itemIsGroup(group, selected),
          preferred: saved,
          preferredIsGroup: saved == null ? null : _itemIsGroup(group, saved),
        ),
      );
      return;
    }
    final own = _ourSwitch;
    if (own != null) {
      if (selected == own) {
        // the core took this runtime's switch
        _ourSwitch = null;
        _ourSwitchUntil = null;
        return;
      }
      final until = _ourSwitchUntil;
      // still the old server: the core reports it for a few seconds after the switch
      if (until != null && DateTime.now().isBefore(until)) return;
      _ourSwitch = null;
      _ourSwitchUntil = null;
    }
    if (selected == machine.current) return;
    // restored on connecting, or switched by another part of the app: the server in use, never the
    // user's choice (that comes only as a HappUserPick)
    loggy.debug('failover: the core selected [$selected]');
    _apply(machine.coreSelected(selected, isGroup: _itemIsGroup(group, selected), now: DateTime.now()));
  }

  void _onUserPick(HappUserPick pick) {
    if (_disposed) return;
    final group = _group;
    if (pick.groupTag != (group?.tag ?? happMainSelectorTag)) return;
    loggy.debug('failover: the user picked [${pick.outboundTag}]');
    // the user's server now, even the one this runtime had moved to: kept, nothing to return to
    _ourSwitch = null;
    _ourSwitchUntil = null;
    _epoch++;
    burst.clear();
    final isGroup = group == null ? _isGroupTag(pick.outboundTag) : _itemIsGroup(group, pick.outboundTag);
    if (!_started) {
      // before the first list: it is the server to start with
      machine.preferred = pick.outboundTag;
      machine.preferredIsGroup = isGroup;
      return;
    }
    _apply(machine.userSelected(pick.outboundTag, isGroup: isGroup));
  }

  void _onFailure(DateTime at, String? host, bool viaProxy) {
    if (_disposed || !viaProxy || host == null) return;
    if (burst.add(at, host)) {
      loggy.debug('failover: a burst of failed connections');
      _apply(machine.onPassiveSignal(now: at));
    }
  }

  /// Does what [step] says: schedules the next probe, starts the checks, switches.
  void _apply(HappFailoverStep? step) {
    if (step == null || _disposed) return;
    // what was in use before this step: a switch the core refuses goes back to it
    final previous = _inUse;
    final previousIsGroup = _inUseIsGroup;
    _inUse = machine.current;
    _inUseIsGroup = machine.currentIsGroup;
    _publish();
    _timer?.cancel();
    _timer = null;
    final probeIn = step.probeIn;
    if (probeIn != null) _timer = Timer(probeIn, () => unawaited(_probe()));
    if (step.switchTo case final to?) {
      unawaited(_select(to, returning: step.returning, previous: previous, previousIsGroup: previousIsGroup));
    }
    if (step.refreshGroup && machine.current != null) {
      unawaited(ref.read(proxyRepositoryProvider).urlTest(machine.current!).run());
    }
    if (step.checkDirect) unawaited(_checkDirect());
    if (step.pickReplacement) unawaited(_pickReplacement());
  }

  void _publish() {
    if (_disposed) return;
    final current = machine.current;
    final moved = current != null && !machine.onPreferred && machine.autoSince != null ? current : null;
    final HappLivenessState next = (level: machine.level, movedTo: moved);
    final notifier = ref.read(happLivenessProvider.notifier);
    if (notifier.state == next) return;
    final enteringNoInternet = next.level == HappLiveness.noInternet && notifier.state.level != HappLiveness.noInternet;
    notifier.state = next;
    final isRu = happIsRu(ref);
    final note = switch (next.level) {
      HappLiveness.noInternet => isRu ? 'Нет интернета' : 'No internet',
      HappLiveness.switching => isRu ? 'Переключаю сервер…' : 'Switching server…',
      HappLiveness.bad => isRu ? 'Сервер не отвечает' : 'Server not answering',
      HappLiveness.warn => isRu ? 'Проверяю связь…' : 'Checking…',
      _ => null,
    };
    unawaited(HappPlatform.setLiveness(next.level, note: note));
    final last = _lastNoInternetNotice;
    if (enteringNoInternet && happNoInternetNotifyDue(last, DateTime.now())) {
      _lastNoInternetNotice = DateTime.now();
      unawaited(
        happNotify(
          ref.read(sharedPreferencesProvider).valueOrNull,
          HappNotifyType.vpnProblem,
          isRu: isRu,
          ru: ('Нет интернета', 'VPN включён, но интернет не отвечает и без VPN. Сервер не меняю'),
          en: ('No internet', 'The VPN is on, but the internet does not answer without it either. The server stays'),
        ),
      );
    }
  }

  Future<void> _probe() async {
    final group = _group;
    if (_disposed || group == null) return;
    if (_busy) {
      // another check is under way: this probe comes a moment later (its own step replaces this)
      _timer?.cancel();
      _timer = Timer(busyRetry, () => unawaited(_probe()));
      return;
    }
    _busy = true;
    final epoch = _epoch;
    HappFailoverStep? step;
    var unavailable = false;
    try {
      int? delay;
      try {
        // through the selector: exactly the path the apps' traffic takes now
        // a recheck after a miss waits longer: a tunnel busy with a big download can answer a probe
        // slowly, and three quick misses would switch away and cut that download (build-42)
        delay = await api.delay(group.tag, url: testUrl, timeout: happProbeTimeout(machine.fails));
      } on HappClashUnavailable catch (e) {
        // the core's API did not answer (restarting, or a key it was not started with)
        loggy.debug('failover: probe unavailable: $e');
        unavailable = true;
      }
      if (!unavailable && !_disposed && epoch == _epoch) {
        final probed = machine.onProbe(ok: delay != null, now: DateTime.now());
        step = probed;
        final pref = machine.preferred;
        if (probed.probePreferred && pref != null) {
          int? prefDelay;
          try {
            prefDelay = await api.delay(pref, url: testUrl);
          } on HappClashUnavailable {
            prefDelay = null;
          }
          if (!_disposed && epoch == _epoch) {
            step = machine.onPreferredProbe(ok: prefDelay != null, now: DateTime.now()) ?? probed;
          }
        }
      }
    } catch (e, st) {
      loggy.warning('failover: probe failed', e, st);
    }
    _busy = false;
    if (_disposed) return;
    if (step != null && epoch == _epoch) {
      _apply(step);
    } else if (unavailable && machine.screenOn) {
      // nothing learnt: try again later, only while someone looks
      _timer?.cancel();
      _timer = Timer(machine.timing.periodic, () => unawaited(_probe()));
    }
  }

  Future<bool> _directWorks() async {
    for (final url in [testUrl, 'https://ya.ru']) {
      try {
        // the core's own direct way out: protected from the tunnel, so it works even with
        // «Блокировать соединения без VPN» on (the app itself is cut off then)
        if (await api.delay(happCoreDirectTag, url: url) != null) return true;
      } on HappClashUnavailable {
        if (await _directFromApp(url)) return true;
      }
      if (_disposed) return false;
    }
    return false;
  }

  /// The app's own request: it is outside the tunnel (Happify excludes itself from the VPN).
  Future<bool> _directFromApp(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.headUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 6));
      await response.drain<void>();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _checkDirect() async {
    if (_disposed) return;
    _busy = true;
    final epoch = _epoch;
    var ok = false;
    try {
      ok = await _directWorks();
    } catch (e, st) {
      loggy.warning('failover: direct check failed', e, st);
    }
    _busy = false;
    if (_disposed || epoch != _epoch) return;
    _apply(machine.onDirect(ok: ok, now: DateTime.now()));
  }

  Future<void> _pickReplacement() async {
    final group = _group;
    final current = machine.current;
    if (_disposed || group == null || current == null) return;
    _busy = true;
    final epoch = _epoch;
    ({String tag, bool protocolFallback})? choice;
    var done = false;
    try {
      // the protocol of each server, from the saved config; kept alive while it is read
      final serversSub = ref.listen(happServersProvider(profileId).future, (_, _) {});
      List<HappServer> details;
      try {
        details = await serversSub.read();
      } catch (_) {
        details = const [];
      } finally {
        serversSub.close();
      }
      final byTag = {for (final d in details) d.tag: d};
      final now = DateTime.now();
      final servers = <HappFailoverServer>[
        for (final p in group.items)
          if (!p.isGroup && p.isVisible)
            (
              tag: p.tag,
              family: happProtocolFamily(
                byTag[p.tag]?.type ?? p.typeWithoutStatus,
                byTag[p.tag]?.subtitle ?? p.typeWithoutStatus.toUpperCase(),
              ),
              country:
                  happCountryFromName(p.tagDisplay.isEmpty ? p.tag : p.tagDisplay) ??
                  (p.ipinfo.countryCode.isEmpty ? null : p.ipinfo.countryCode.toUpperCase()),
            ),
      ];
      final toTest = [
        for (final s in servers)
          if (s.tag != current && !machine.isBad(s.tag, now)) s.tag,
      ];
      final delays = await _probeMany(toTest);
      choice = happChooseReplacement(current: current, servers: servers, delays: delays);
      done = true;
    } catch (e, st) {
      loggy.warning('failover: looking for a replacement failed', e, st);
    }
    _busy = false;
    // the user picked a server meanwhile: theirs stays
    if (_disposed || epoch != _epoch || machine.current != current) return;
    loggy.info('failover: [$current] is down, moving to [${choice?.tag}] (another protocol: ${choice?.protocolFallback})');
    _apply(machine.onReplacement(done ? choice?.tag : null, now: DateTime.now()));
    if (choice == null) return;
    final isRu = happIsRu(ref);
    final name = happCleanName(choice.tag);
    final was = happCleanName(current);
    unawaited(
      happNotify(
        ref.read(sharedPreferencesProvider).valueOrNull,
        choice.protocolFallback ? HappNotifyType.throttled : HappNotifyType.serverSwitched,
        isRu: isRu,
        ru: choice.protocolFallback
            ? ('Канал душат — включил резерв', 'Серверы этого протокола не отвечают. Сейчас: $name')
            : ('Сервер сменён', '$was не отвечал. Сейчас: $name'),
        en: choice.protocolFallback
            ? ('Throttled — reserve on', 'Servers of this protocol do not answer. Now: $name')
            : ('Server switched', '$was stopped answering. Now: $name'),
      ),
    );
  }

  /// A probe of each of [tags], six at a time.
  Future<Map<String, int?>> _probeMany(List<String> tags) async {
    final out = <String, int?>{};
    var next = 0;
    Future<void> worker() async {
      while (next < tags.length && !_disposed) {
        final tag = tags[next++];
        try {
          out[tag] = await api.delay(tag, url: testUrl, timeout: const Duration(seconds: 4));
        } on HappClashUnavailable {
          out[tag] = null;
        }
      }
    }

    await Future.wait([for (var i = 0; i < 6; i++) worker()]);
    return out;
  }

  /// Selects [tag], which [machine] already holds as current; [previous] was in use before.
  Future<void> _select(String tag, {required bool returning, required String? previous, required bool previousIsGroup}) async {
    final group = _group;
    if (_disposed || group == null) return;
    _ourSwitch = tag;
    _ourSwitchUntil = DateTime.now().add(ownSwitchGrace);
    final epoch = _epoch;
    loggy.info('failover: selecting [$tag]${returning ? ' (back to the user\'s server)' : ''}');
    // straight to the core: never through changeProxy, which is the user's pick; the selector
    // closes the old connections itself (interrupt_exist_connections), so the traffic moves at once
    var ok = false;
    try {
      ok = (await ref.read(proxyRepositoryProvider).selectProxy(group.tag, tag).run()).isRight();
    } catch (e, st) {
      loggy.warning('failover: selecting [$tag] failed', e, st);
    }
    if (ok || _disposed || epoch != _epoch || _ourSwitch != tag) return;
    // the core said no: the old server is still the one in use
    loggy.warning('failover: the core refused [$tag], [$previous] stays');
    _ourSwitch = null;
    _ourSwitchUntil = null;
    if (previous == null || machine.current != tag) return;
    _apply(machine.switchFailed(previous: previous, previousIsGroup: previousIsGroup, now: DateTime.now()));
  }
}

/// How long a liveness probe waits: 5 s, 10 s for a recheck after [fails] missed ones.
Duration happProbeTimeout(int fails) => fails > 0 ? const Duration(seconds: 10) : const Duration(seconds: 5);
