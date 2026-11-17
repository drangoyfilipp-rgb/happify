import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/core/router/go_router/go_router_notifier.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/happ/reliability/happ_platform.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// «Мимо VPN»: apps whose traffic never enters the tunnel, one tap away from the VPN notification.
// The list is Happify's own ("happify_bypass_apps", one package per line); Android leaves those
// apps out of the VPN (VPNService.kt reads it when the tunnel opens), on top of the per-app
// settings, which stay as they are.

final happBypassApps = PreferencesNotifier.create<String, String>("happify_bypass_apps", "");

List<String> happBypassList(String raw) => raw.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

/// Opens the tunnel again so Android applies a new list (a running VPN keeps the apps it started
/// with). Quick: the connection is stopped and started at once.
Future<void> happRestartTunnel(ProviderContainer container) async {
  final notifier = container.read(connectionNotifierProvider.notifier);
  final status = container.read(connectionNotifierProvider).valueOrNull;
  if (status is! Connected) return;
  await notifier.toggleConnection();
  for (var i = 0; i < 60; i++) {
    if (container.read(connectionNotifierProvider).valueOrNull is Disconnected) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (container.read(connectionNotifierProvider).valueOrNull is Disconnected) {
    await notifier.toggleConnection();
  }
}

Future<void> _setList(ProviderContainer container, List<String> list) async {
  await container.read(happBypassApps.notifier).update(list.join('\n'));
  await happRestartTunnel(container);
}

/// Adds [package] to «Мимо VPN» and reconnects.
Future<void> happAddBypass(ProviderContainer container, String package) async {
  final list = happBypassList(container.read(happBypassApps));
  if (list.contains(package)) return;
  await _setList(container, [...list, package]);
}

Future<void> happRemoveBypass(ProviderContainer container, String package) async {
  final list = happBypassList(container.read(happBypassApps))..remove(package);
  await _setList(container, list);
}

/// The picker the VPN notification's «Мимо VPN» opens: the apps used last, or every app.
Future<void> happShowBypassPicker([BuildContext? from]) async {
  final context = from ?? rootNavKey.currentContext;
  if (context == null || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final package = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const _BypassPicker(),
  );
  if (package == null) return;
  await happAddBypass(container, package);
  if (!context.mounted) return;
  final labels = await HappPlatform.appLabels([package]);
  if (!context.mounted) return;
  final name = labels[package] ?? package;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(hr(context, '$name теперь работает мимо VPN', '$name now bypasses the VPN'))),
  );
}

class _BypassPicker extends StatefulWidget {
  const _BypassPicker();

  @override
  State<_BypassPicker> createState() => _BypassPickerState();
}

class _BypassPickerState extends State<_BypassPicker> with WidgetsBindingObserver {
  bool? _access;
  List<({String package, String name})> _recent = const [];
  List<({String package, String name})>? _all;
  bool _allLoading = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // back from the system page where the access is given
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final access = await HappPlatform.hasUsageAccess();
    final recent = access ? await HappPlatform.recentApps() : const <({String package, String name})>[];
    if (!mounted) return;
    setState(() {
      _access = access;
      _recent = recent;
    });
  }

  /// The full list. Never left spinning: a failure or a timeout reads as an empty list, which
  /// shows a message and «Повторить».
  Future<void> _loadAll() async {
    if (_allLoading) return;
    setState(() => _allLoading = true);
    var all = const <({String package, String name})>[];
    try {
      all = await HappPlatform.launchableApps().timeout(const Duration(seconds: 20));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _allLoading = false;
      _all = all;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _all;
    Widget app(({String package, String name}) a) => ListTile(
      leading: const Icon(Icons.apps_rounded),
      title: Text(a.name),
      subtitle: Text(a.package, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.of(context).pop(a.package),
    );
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: all == null ? .55 : .9,
      maxChildSize: .95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(hr(context, 'Мимо VPN', 'Bypass the VPN'), style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              hr(
                context,
                'Выбранное приложение будет ходить в интернет напрямую, без VPN (например, банк или игра, которые не любят VPN). VPN переподключится на пару секунд. Убрать можно в Настройки → «Мимо VPN».',
                'The app goes online directly, without the VPN (a bank or a game that dislikes VPNs). The VPN reconnects for a couple of seconds. Remove it in Settings → "Bypass the VPN".',
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (_access == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (all == null) ...[
            if (_access!) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(hr(context, 'Недавние приложения', 'Recent apps'), style: theme.textTheme.titleSmall),
              ),
              if (_recent.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(hr(context, 'Нет недавних приложений', 'No recent apps')),
                ),
              for (final a in _recent) app(a),
            ] else
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: Text(hr(context, 'Показывать недавние приложения', 'Show recent apps')),
                subtitle: Text(
                  hr(
                    context,
                    'Нужен «Доступ к истории использования»: так Happify покажет 3–5 приложений, которыми вы пользовались последними. Больше ничего не читается и никуда не отправляется. Можно и без него: выберите из полного списка ниже.',
                    'Needs "Usage access": Happify then shows the 3–5 apps you used last. Nothing else is read or sent anywhere. You can also do without it: pick from the full list below.',
                  ),
                ),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: HappPlatform.openUsageAccessSettings,
              ),
            if (_allLoading)
              ListTile(
                leading: const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                title: Text(hr(context, 'Загружаю список приложений…', 'Loading the apps…')),
              )
            else
              ListTile(
                leading: const Icon(Icons.list_rounded),
                title: Text(hr(context, 'Все приложения…', 'All apps…')),
                onTap: _loadAll,
              ),
          ] else if (all.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    hr(context, 'Не удалось получить список приложений', 'Could not get the list of apps'),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  if (_allLoading)
                    const CircularProgressIndicator()
                  else
                    FilledButton.tonalIcon(
                      onPressed: _loadAll,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(hr(context, 'Повторить', 'Retry')),
                    ),
                ],
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: hr(context, 'Поиск', 'Search'),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
              ),
            ),
            for (final a in all.where(
              (a) => _filter.isEmpty || a.name.toLowerCase().contains(_filter) || a.package.toLowerCase().contains(_filter),
            ))
              app(a),
          ],
        ],
      ),
    );
  }
}

/// Settings → «Мимо VPN»: the list, to add and remove apps.
class HappBypassPage extends HookConsumerWidget {
  const HappBypassPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = happBypassList(ref.watch(happBypassApps));
    final theme = Theme.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    return Scaffold(
      appBar: AppBar(title: Text(hr(context, 'Мимо VPN', 'Bypass the VPN'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => happShowBypassPicker(context),
        icon: const Icon(Icons.add_rounded),
        label: Text(hr(context, 'Добавить', 'Add')),
      ),
      body: FutureBuilder<Map<String, String>>(
        future: HappPlatform.appLabels(list),
        builder: (context, snap) {
          final labels = snap.data ?? const {};
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  hr(
                    context,
                    'Эти приложения ходят в интернет напрямую, без VPN. Добавлять удобно прямо из уведомления VPN: кнопка «Мимо VPN». После изменения VPN переподключается на пару секунд.',
                    'These apps go online directly, without the VPN. The quickest way to add one is the VPN notification\'s "Bypass" button. After a change the VPN reconnects for a couple of seconds.',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(hr(context, 'Список пуст', 'The list is empty'), textAlign: TextAlign.center),
                ),
              for (final p in list)
                ListTile(
                  leading: const Icon(Icons.apps_rounded),
                  title: Text(labels[p] ?? p),
                  subtitle: Text(p),
                  trailing: IconButton(
                    tooltip: hr(context, 'Вернуть в VPN', 'Back into the VPN'),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: () => happRemoveBypass(container, p),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
