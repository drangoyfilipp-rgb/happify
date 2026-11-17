import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_last_server.dart';
import 'package:hiddify/features/happ/reliability/happ_clash_api.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_machine.dart';
import 'package:hiddify/features/happ/reliability/happ_failover_runtime.dart';
import 'package:hiddify/features/happ/reliability/happ_user_pick.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The core's side: the proxy list it streams and the selections it is asked for.
class _Repository implements ProxyRepository {
  final updates = StreamController<Either<ProxyFailure, OutboundGroup?>>.broadcast();
  final selects = <String>[];
  bool selectFails = false;

  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => updates.stream;

  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) {
    selects.add(outboundTag);
    return selectFails ? TaskEither.left(const ProxyFailure.unexpected()) : TaskEither.right(unit);
  }

  @override
  TaskEither<ProxyFailure, Unit> urlTest(String groupTag) => TaskEither.right(unit);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// The core's control API: every probe answers in 100 ms unless [hold] keeps a tag's answer back.
class _Api extends HappClashApi {
  _Api() : super(port: 0, secret: 'test');

  final calls = <String>[];
  final hold = <String, Completer<int?>>{};

  @override
  Future<int?> delay(String tag, {required String url, Duration timeout = const Duration(seconds: 5)}) {
    calls.add(tag);
    return hold[tag]?.future ?? Future.value(100);
  }

  int count(String tag) => calls.where((t) => t == tag).length;
}

class _Notifications extends InAppNotificationController {
  @override
  void showErrorToast(String message) {}
}

const _prague = 'Прага';
const _helsinki = 'Хельсинки';
const _stockholm = 'Стокгольм';

OutboundGroup _group(String selected) => OutboundGroup(
  tag: happMainSelectorTag,
  selected: selected,
  items: [
    for (final tag in [_prague, _helsinki, _stockholm]) OutboundInfo(tag: tag, isVisible: true, urlTestDelay: 100),
  ],
);

void main() {
  late _Repository repository;
  late _Api api;
  late ProviderContainer container;
  late HappFailoverRuntime runtime;
  late StreamController<bool> screen;

  /// Connected with [selected] in the core and [saved] the user's last pick in this profile.
  Future<void> connect(WidgetTester tester, {required String selected, String? saved, bool screenOn = true}) async {
    SharedPreferences.setMockInitialValues({
      'haptic_feedback': false,
      if (saved != null) happLastServerKey('p'): saved,
    });
    repository = _Repository();
    api = _Api();
    screen = StreamController<bool>.broadcast();
    container = ProviderContainer(
      overrides: [
        serviceRunningProvider.overrideWithValue(true),
        proxyRepositoryProvider.overrideWithValue(repository),
        inAppNotificationControllerProvider.overrideWithValue(_Notifications()),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    addTearDown(screen.close);
    await tester.runAsync(() => container.read(sharedPreferencesProvider.future));
    await tester.runAsync(() => container.read(translationsProvider.future));
    final provider = Provider<HappFailoverRuntime>((ref) {
      final r = HappFailoverRuntime(
        ref,
        profileId: 'p',
        api: api,
        testUrl: 'https://test/204',
        screenEvents: screen.stream,
        isScreenOn: () async => screenOn,
      );
      ref.onDispose(r.dispose);
      return r;
    });
    runtime = container.read(provider);
    runtime.start();
    await tester.pump();
    repository.updates.add(right(_group(selected)));
    await tester.pump();
    await tester.pump();
  }

  /// Disconnected: the runtime and its timers are gone.
  Future<void> disconnect(WidgetTester tester) async {
    container.dispose();
    await tester.pump(const Duration(minutes: 1));
  }

  /// The core reports [selected] now.
  Future<void> core(WidgetTester tester, String selected) async {
    repository.updates.add(right(_group(selected)));
    await tester.pump();
    await tester.pump();
  }

  /// Moved off the user's Прага to Хельсинки by the failover earlier, Прага answering again: the
  /// failover returns to Прага at the second probe (5 s after connecting, then 60 s later).
  Future<void> returnToPrague(WidgetTester tester) async {
    await connect(tester, selected: _helsinki, saved: _prague);
    expect(runtime.machine.preferred, _prague);
    expect(runtime.machine.current, _helsinki);
    await tester.pump(const Duration(seconds: 5));
    expect(repository.selects, isEmpty, reason: 'one good probe of Прага is not enough');
    await tester.pump(const Duration(seconds: 60));
    expect(repository.selects, [_prague]);
    expect(runtime.machine.current, _prague);
  }

  testWidgets('the core echoing the old server during its own switch is not a choice', (tester) async {
    await returnToPrague(tester);
    // the core keeps reporting Хельсинки for a few seconds
    await core(tester, _helsinki);
    await tester.pump(const Duration(seconds: 2));
    await core(tester, _helsinki);
    expect(runtime.machine.current, _prague);
    expect(runtime.machine.preferred, _prague);
    expect(runtime.machine.onPreferred, isTrue);
    expect(repository.selects, [_prague], reason: 'nothing selected again');
    await core(tester, _prague);
    expect(runtime.machine.current, _prague);
    // later, once the switch was taken, another part of the app moves it: in use, not the user's
    await tester.pump(const Duration(seconds: 20));
    await core(tester, _stockholm);
    expect(runtime.machine.current, _stockholm);
    expect(runtime.machine.preferred, _prague);
    await disconnect(tester);
  });

  testWidgets('a switch the core refuses leaves the old server in use', (tester) async {
    await connect(tester, selected: _helsinki, saved: _prague);
    repository.selectFails = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 60));
    expect(repository.selects, [_prague]);
    expect(runtime.machine.current, _helsinki, reason: 'rolled back');
    expect(runtime.machine.preferred, _prague);
    expect(runtime.machine.level, HappLiveness.warn);
    expect(runtime.probeScheduled, isTrue);
    await disconnect(tester);
  });

  testWidgets('a tap on the server the failover chose makes it the user\'s: no return', (tester) async {
    await connect(tester, selected: _helsinki, saved: _prague);
    container.listen(proxiesOverviewNotifierProvider, (_, _) {});
    await tester.pump();
    final picks = <HappUserPick?>[];
    container.listen(happUserPickProvider, (_, pick) => picks.add(pick));
    // the core's selection does not change: only the signal says it was the user
    expect(await container.read(proxiesOverviewNotifierProvider.notifier).changeProxy(happMainSelectorTag, _helsinki), isTrue);
    await tester.pump();
    expect(picks.single?.outboundTag, _helsinki);
    expect(runtime.machine.preferred, _helsinki);
    expect(runtime.machine.autoSince, isNull);
    // Прага answers every probe, and stays alone
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 60));
    }
    expect(repository.selects, [_helsinki], reason: 'only the tap');
    expect(api.count(_prague), 0, reason: 'nothing to return to');
    expect(runtime.machine.current, _helsinki);
    await disconnect(tester);
  });

  testWidgets('a probe that comes while another check runs is tried again in 3 s', (tester) async {
    await connect(tester, selected: _prague);
    final direct = api.hold[happCoreDirectTag] = Completer<int?>();
    api.hold[happMainSelectorTag] = Completer<int?>()..complete(null);
    // three failed probes, then the internet is checked without the tunnel: that check hangs
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(api.count(happCoreDirectTag), 1, reason: "the core's direct outbound, by its real tag");
    expect(api.calls, isNot(contains('direct')));
    // the user picks a server meanwhile: its check is due in 5 s, while the direct check still runs
    api.hold.remove(happMainSelectorTag);
    container.read(happUserPickProvider.notifier).state = HappUserPick(happMainSelectorTag, _stockholm);
    await tester.pump();
    final probes = api.count(happMainSelectorTag);
    await tester.pump(const Duration(seconds: 5));
    expect(api.count(happMainSelectorTag), probes, reason: 'busy: not run now');
    expect(runtime.probeScheduled, isTrue, reason: 'but not lost either');
    direct.complete(null);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(api.count(happMainSelectorTag), probes + 1);
    expect(runtime.machine.level, HappLiveness.ok);
    expect(runtime.machine.preferred, _stockholm);
    await disconnect(tester);
  });

  testWidgets('screen off: no probe on a timer, only events', (tester) async {
    await connect(tester, selected: _prague, screenOn: false);
    // the probe after connecting is an event of its own
    await tester.pump(const Duration(seconds: 5));
    expect(api.count(happMainSelectorTag), 1);
    expect(runtime.machine.level, HappLiveness.ok);
    expect(runtime.probeScheduled, isFalse);
    await tester.pump(const Duration(minutes: 10));
    expect(api.count(happMainSelectorTag), 1);
    // the screen on: a probe within the minute (the test's clock does not move DateTime.now, so
    // the last probe looks fresh), then every minute
    screen.add(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 60));
    expect(api.count(happMainSelectorTag), 2);
    expect(runtime.probeScheduled, isTrue);
    screen.add(false);
    await tester.pump();
    expect(runtime.probeScheduled, isFalse);
    await disconnect(tester);
  });

  test('a pick is saved as the profile\'s last server', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await happSaveUserPick(prefs, 'p', HappUserPick(happMainSelectorTag, _prague));
    expect(prefs.getString(happLastServerKey('p')), _prague);
    await happSaveUserPick(prefs, null, HappUserPick(happMainSelectorTag, _helsinki));
    expect(prefs.getString(happLastServerKey('p')), _prague);
  });
}
