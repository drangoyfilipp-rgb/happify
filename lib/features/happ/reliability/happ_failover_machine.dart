// «Автопереключение при сбое»: the decisions, without timers, I/O or Flutter, so every rule is
// covered by unit tests (test/features/happ/happ_failover_machine_test.dart). The runtime
// (happ_failover_runtime.dart) feeds it probe results and does what each step says.
//
// The scheme, as agreed with the user:
// - a probe = an HTTP 204 request through the server in use (the core's URL test);
// - every 60 s while the screen is on; with the screen off never on a timer, only when the apps'
//   own connections start failing (a passive signal from the core's log) or something happens
//   (a connection, a switch): such a check runs to its end (the rechecks of a failure), then stops;
// - a failed probe is checked again after 10 s; three in a row (~30 s) and the internet is
//   checked without the tunnel: it works → the best live server of the same subscription (another
//   protocol, Reality first, when every server of this one fails); it does not → «нет интернета»,
//   nothing is switched;
// - the server the user picked is remembered; once it answers two probes in a row (and enough time
//   has passed since it failed) it is picked again; a server that fails again soon after such a
//   return waits twice as long before the next one (no flapping);
// - lowest and balance are never switched away from: the core picks inside them; it is only asked
//   to test again.

/// What the indicator shows: green, yellow, red, red, red; nothing while idle.
enum HappLiveness {
  /// Not connected, or nothing measured yet.
  idle,

  /// The last probe got through.
  ok,

  /// One or two probes in a row failed: being checked again.
  warn,

  /// Three in a row failed and nothing could be done (no other server answers, or switching is off).
  bad,

  /// Looking for another server, or just switched to it and checking it.
  switching,

  /// The internet does not work without the tunnel either: not the server's fault.
  noInternet;

  /// The traffic light: 0 none, 1 green, 2 yellow, 3 red.
  int get light => switch (this) {
    idle => 0,
    ok => 1,
    warn => 2,
    bad || switching || noInternet => 3,
  };
}

class HappFailoverTiming {
  const HappFailoverTiming({
    this.periodic = const Duration(seconds: 60),
    this.recheck = const Duration(seconds: 10),
    this.afterConnect = const Duration(seconds: 5),
    this.verifySwitch = const Duration(seconds: 5),
    this.failuresToAct = 3,
    this.okToReturn = 2,
    this.returnHoldBase = const Duration(minutes: 2),
    this.returnHoldMax = const Duration(minutes: 30),
    this.flapWindow = const Duration(minutes: 10),
    this.stableAfterReturn = const Duration(minutes: 30),
    this.noInternetRecheck = const Duration(seconds: 30),
    this.allDeadRecheck = const Duration(seconds: 30),
    this.badServerFor = const Duration(minutes: 5),
    this.passiveMinGap = const Duration(seconds: 15),
    this.groupRefreshGap = const Duration(seconds: 60),
    this.screenOnStale = const Duration(seconds: 30),
  });

  final Duration periodic;
  final Duration recheck;
  final Duration afterConnect;
  final Duration verifySwitch;
  final int failuresToAct;
  final int okToReturn;
  final Duration returnHoldBase;
  final Duration returnHoldMax;
  final Duration flapWindow;
  final Duration stableAfterReturn;
  final Duration noInternetRecheck;
  final Duration allDeadRecheck;
  final Duration badServerFor;
  final Duration passiveMinGap;
  final Duration groupRefreshGap;
  final Duration screenOnStale;
}

/// What the runtime does after an event. [probeIn] replaces whatever probe was scheduled: null
/// cancels it (nothing runs until the next event).
class HappFailoverStep {
  const HappFailoverStep({
    required this.level,
    this.probeIn,
    this.checkDirect = false,
    this.pickReplacement = false,
    this.switchTo,
    this.returning = false,
    this.probePreferred = false,
    this.refreshGroup = false,
  });

  final HappLiveness level;
  final Duration? probeIn;

  /// Check the internet without the tunnel, then call [HappFailoverMachine.onDirect].
  final bool checkDirect;

  /// Test the subscription's servers, choose with [happChooseReplacement], then call
  /// [HappFailoverMachine.onReplacement].
  final bool pickReplacement;

  /// Select this server in the core (never written as the user's choice).
  final String? switchTo;

  /// [switchTo] is the user's own server coming back.
  final bool returning;

  /// Probe the user's server too, then call [HappFailoverMachine.onPreferredProbe].
  final bool probePreferred;

  /// Ask the core to test lowest/balance again, so it moves off what failed.
  final bool refreshGroup;

  @override
  String toString() =>
      'Step($level, in: $probeIn${checkDirect ? ', direct' : ''}${pickReplacement ? ', pick' : ''}'
      '${switchTo != null ? ', to: $switchTo${returning ? ' (back)' : ''}' : ''}'
      '${probePreferred ? ', probe preferred' : ''}${refreshGroup ? ', refresh group' : ''})';
}

class HappFailoverMachine {
  HappFailoverMachine({this.timing = const HappFailoverTiming(), this.autoSwitch = true})
    : returnHold = timing.returnHoldBase;

  final HappFailoverTiming timing;

  /// «Автопереключение при сбое»: off, the indicator still works, nothing is switched.
  bool autoSwitch;
  bool screenOn = true;

  /// The server (or group) the user picked; null until known.
  String? preferred;
  bool preferredIsGroup = false;

  /// The server (or group) selected in the core now.
  String? current;
  bool currentIsGroup = false;

  int fails = 0;
  int preferredOk = 0;

  /// When the connection moved off [preferred] by itself; null while on it.
  DateTime? autoSince;

  /// How long [preferred] has to wait before it may come back.
  Duration returnHold;
  DateTime? returnedAt;
  DateTime? lastProbeAt;
  DateTime? lastGroupRefresh;

  /// Servers that failed recently, not chosen as a replacement until then.
  final Map<String, DateTime> badUntil = {};

  HappLiveness level = HappLiveness.idle;

  bool get onPreferred => current != null && current == preferred;

  /// Connected: [current] is what the core has selected, [preferred] what the user picked last.
  HappFailoverStep start({required String current, required bool currentIsGroup, String? preferred, bool? preferredIsGroup}) {
    this.current = current;
    this.currentIsGroup = currentIsGroup;
    this.preferred = preferred ?? current;
    this.preferredIsGroup = preferredIsGroup ?? (this.preferred == current ? currentIsGroup : false);
    fails = 0;
    preferredOk = 0;
    autoSince = this.preferred == current ? null : DateTime.fromMillisecondsSinceEpoch(0);
    returnHold = timing.returnHoldBase;
    returnedAt = null;
    level = HappLiveness.idle;
    return HappFailoverStep(level: level, probeIn: timing.afterConnect);
  }

  /// The user picked [tag] (a tap, here or on the servers page): it is the one to keep and return to.
  HappFailoverStep userSelected(String tag, {required bool isGroup}) {
    preferred = tag;
    preferredIsGroup = isGroup;
    current = tag;
    currentIsGroup = isGroup;
    fails = 0;
    preferredOk = 0;
    autoSince = null;
    returnHold = timing.returnHoldBase;
    returnedAt = null;
    badUntil.remove(tag);
    if (level != HappLiveness.noInternet) level = HappLiveness.idle;
    return HappFailoverStep(level: level, probeIn: timing.verifySwitch);
  }

  /// The core reports [tag] selected, and it was neither the user (a [userSelected]) nor this
  /// machine's own switch: a restore on connecting, another app part. The server in use, never the
  /// user's choice: off the user's server, it is returned to once it answers again.
  HappFailoverStep? coreSelected(String tag, {required bool isGroup, required DateTime now}) {
    if (tag == current) return null;
    current = tag;
    currentIsGroup = isGroup;
    fails = 0;
    preferredOk = 0;
    if (onPreferred) {
      autoSince = null;
    } else {
      autoSince ??= now;
    }
    return HappFailoverStep(level: level, probeIn: timing.verifySwitch);
  }

  /// The core refused the switch to [current] asked for by the last step: [previous] stays in use.
  HappFailoverStep switchFailed({required String previous, required bool previousIsGroup, required DateTime now}) {
    final returning = onPreferred;
    current = previous;
    currentIsGroup = previousIsGroup;
    preferredOk = 0;
    fails = 0;
    if (onPreferred) {
      autoSince = null;
    } else {
      // a return that did not happen: the user's server is still away (since now, for the hold)
      if (returning || autoSince == null) autoSince = now;
      if (returning) returnedAt = null;
    }
    level = HappLiveness.warn;
    return HappFailoverStep(level: level, probeIn: timing.recheck);
  }

  /// A probe through the server in use answered ([ok]) or not.
  HappFailoverStep onProbe({required bool ok, required DateTime now}) {
    lastProbeAt = now;
    _forgetExpired(now);
    if (ok) {
      fails = 0;
      level = HappLiveness.ok;
      if (onPreferred && returnedAt != null && now.difference(returnedAt!) >= timing.stableAfterReturn) {
        // back on it and it held: the next return needs only the usual wait
        returnHold = timing.returnHoldBase;
        returnedAt = null;
      }
      return HappFailoverStep(
        level: level,
        probeIn: screenOn ? timing.periodic : null,
        probePreferred: canReturn(now),
      );
    }
    fails++;
    preferredOk = 0;
    if (fails < timing.failuresToAct) {
      level = HappLiveness.warn;
      return HappFailoverStep(level: level, probeIn: timing.recheck);
    }
    // three in a row: is it the server, or the internet?
    level = HappLiveness.bad;
    return HappFailoverStep(level: level, checkDirect: true);
  }

  /// The internet without the tunnel works ([ok]) or not, after three failed probes.
  HappFailoverStep onDirect({required bool ok, required DateTime now}) {
    if (!ok) {
      // nothing a server could fix: wait for the network
      level = HappLiveness.noInternet;
      fails = 0;
      return HappFailoverStep(level: level, probeIn: screenOn ? timing.noInternetRecheck : null);
    }
    if (!autoSwitch) {
      level = HappLiveness.bad;
      fails = 0;
      return HappFailoverStep(level: level, probeIn: screenOn ? timing.allDeadRecheck : null);
    }
    if (currentIsGroup) {
      // lowest and balance pick inside themselves: the core is asked to test again, never overridden
      fails = 0;
      level = HappLiveness.warn;
      final refresh = lastGroupRefresh == null || now.difference(lastGroupRefresh!) >= timing.groupRefreshGap;
      if (refresh) lastGroupRefresh = now;
      return HappFailoverStep(level: level, probeIn: screenOn ? timing.recheck : null, refreshGroup: refresh);
    }
    final failed = current;
    if (failed != null) badUntil[failed] = now.add(timing.badServerFor);
    level = HappLiveness.switching;
    return HappFailoverStep(level: level, pickReplacement: true);
  }

  /// The replacement chosen after [onDirect] asked for one; null when no server answered.
  HappFailoverStep onReplacement(String? chosen, {required DateTime now}) {
    fails = 0;
    preferredOk = 0;
    if (chosen == null || chosen == current) {
      level = HappLiveness.bad;
      return HappFailoverStep(level: level, probeIn: screenOn ? timing.allDeadRecheck : null);
    }
    if (onPreferred) {
      autoSince = now;
      final back = returnedAt;
      if (back != null && now.difference(back) < timing.flapWindow) {
        // it came back and failed again soon: it waits longer next time
        final doubled = returnHold * 2;
        returnHold = doubled > timing.returnHoldMax ? timing.returnHoldMax : doubled;
      }
      returnedAt = null;
    }
    current = chosen;
    currentIsGroup = false;
    // the user's own server came up as the best one: back on it
    if (onPreferred) autoSince = null;
    level = HappLiveness.switching;
    return HappFailoverStep(level: level, switchTo: chosen, probeIn: timing.verifySwitch);
  }

  /// Whether the user's server may be tried again now.
  bool canReturn(DateTime now) {
    final since = autoSince;
    if (!autoSwitch || preferred == null || onPreferred || since == null) return false;
    return now.difference(since) >= returnHold;
  }

  /// A probe through the user's server, asked for by [HappFailoverStep.probePreferred]. Null: no
  /// change to what is scheduled.
  HappFailoverStep? onPreferredProbe({required bool ok, required DateTime now}) {
    if (!canReturn(now)) return null;
    if (!ok) {
      preferredOk = 0;
      return null;
    }
    preferredOk++;
    if (preferredOk < timing.okToReturn) return null;
    final back = preferred!;
    current = back;
    currentIsGroup = preferredIsGroup;
    preferredOk = 0;
    fails = 0;
    autoSince = null;
    returnedAt = now;
    badUntil.remove(back);
    level = HappLiveness.switching;
    return HappFailoverStep(level: level, switchTo: back, returning: true, probeIn: timing.verifySwitch);
  }

  /// The apps' own connections are failing: probe at once, unless a check is already running or
  /// one ran a moment ago. Null: ignored.
  HappFailoverStep? onPassiveSignal({required DateTime now}) {
    if (fails > 0 || level == HappLiveness.switching) return null;
    final last = lastProbeAt;
    if (last != null && now.difference(last) < timing.passiveMinGap) return null;
    return HappFailoverStep(level: level, probeIn: Duration.zero);
  }

  /// The screen went on or off. Off: no periodic probes (a check under way still finishes). On: a
  /// probe soon, if the last one is old. Null: no change to what is scheduled.
  HappFailoverStep? onScreen({required bool on, required DateTime now}) {
    screenOn = on;
    if (fails > 0 || level == HappLiveness.switching) return null;
    if (!on) return HappFailoverStep(level: level);
    final last = lastProbeAt;
    if (last == null || now.difference(last) >= timing.screenOnStale) {
      return HappFailoverStep(level: level, probeIn: const Duration(seconds: 1));
    }
    final left = timing.periodic - now.difference(last);
    return HappFailoverStep(level: level, probeIn: left.isNegative ? Duration.zero : left);
  }

  /// Whether [tag] failed recently.
  bool isBad(String tag, DateTime now) {
    final until = badUntil[tag];
    return until != null && now.isBefore(until);
  }

  void _forgetExpired(DateTime now) => badUntil.removeWhere((_, until) => !now.isBefore(until));
}

/// A server as the replacement choice sees it: [family] from [happProtocolFamily], [country] a
/// code such as "CZ" (null when unknown).
typedef HappFailoverServer = ({String tag, String family, String? country});

/// The server to move to when [current] stopped working.
///
/// [delays]: a fresh probe of each server, ms (null or ≤ 0: no answer). Among the servers that
/// answer, the fastest; one in the same country as [current] when it is nearly as fast. When no other
/// server of [current]'s protocol answers (the protocol is likely blocked), only other protocols are
/// left, and Reality goes first. [protocolFallback] says that happened. Null: none answers.
({String tag, bool protocolFallback})? happChooseReplacement({
  required String current,
  required List<HappFailoverServer> servers,
  required Map<String, int?> delays,
  Set<String> exclude = const {},
}) {
  final cur = servers.where((s) => s.tag == current).firstOrNull;
  int? delayOf(HappFailoverServer s) {
    final d = delays[s.tag];
    return d != null && d > 0 ? d : null;
  }

  final live = [
    for (final s in servers)
      if (s.tag != current && !exclude.contains(s.tag) && delayOf(s) != null) s,
  ];
  if (live.isEmpty) return null;
  final family = cur?.family;
  final sameFamilyLive = family == null ? live : live.where((s) => s.family == family).toList();
  var pool = live;
  var fallback = false;
  if (family != null && sameFamilyLive.isEmpty) {
    // every other server of this protocol is down too: a blocked protocol; another one, Reality first
    fallback = true;
    final reality = live.where((s) => s.family == 'reality').toList();
    if (family != 'reality' && reality.isNotEmpty) pool = reality;
  }
  HappFailoverServer fastest(Iterable<HappFailoverServer> list) =>
      list.reduce((a, b) => delayOf(b)! < delayOf(a)! ? b : a);
  final best = fastest(pool);
  final country = cur?.country;
  if (country != null) {
    final same = pool.where((s) => s.country == country).toList();
    if (same.isNotEmpty) {
      final near = fastest(same);
      // the same country is kept when it is nearly as fast: the user picked a place, not a number
      if (delayOf(near)! <= delayOf(best)! * 1.5 + 30) return (tag: near.tag, protocolFallback: fallback);
    }
  }
  return (tag: best.tag, protocolFallback: fallback);
}

/// The protocol family of a server, for the fallback: what a censor blocks together.
/// [type] the outbound type, [subtitle] as [happSubtitle] writes it ("VLESS / TCP / REALITY | JSON").
String happProtocolFamily(String type, String subtitle) {
  final t = type.toLowerCase();
  final s = subtitle.toUpperCase();
  if (s.contains('REALITY')) return 'reality';
  return switch (t) {
    'hysteria' || 'hysteria2' => 'hysteria',
    'tuic' => 'tuic',
    'wireguard' || 'awg' => 'wireguard',
    'shadowsocks' || 'ss' => 'shadowsocks',
    _ => s.contains('/ TLS') || s.endsWith('TLS') ? '$t-tls' : t,
  };
}

/// Spots a burst of failing connections: [threshold] failures through a proxy within [window],
/// to at least [minHosts] different hosts (one broken site is not the tunnel). Fires once, then
/// counts again from zero.
class HappFailureBurst {
  HappFailureBurst({this.window = const Duration(seconds: 10), this.threshold = 4, this.minHosts = 2});

  final Duration window;
  final int threshold;
  final int minHosts;
  final List<({DateTime at, String host})> _recent = [];

  /// Adds a failure; true when it completes a burst.
  bool add(DateTime at, String host) {
    _recent
      ..add((at: at, host: host))
      ..removeWhere((e) => at.difference(e.at) > window);
    final hosts = _recent.map((e) => e.host).toSet();
    if (_recent.length >= threshold && hosts.length >= minHosts) {
      _recent.clear();
      return true;
    }
    return false;
  }

  void clear() => _recent.clear();
}
