import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/features/chain/model/chain_enum.dart';
import 'package:hiddify/features/chain/overview/chain_mode_icon.dart';
import 'package:hiddify/features/happ/happify_prefs.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/model/connection_health.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

String _timedOut(BuildContext context) => hr(
  context,
  'Не удалось проверить за ${healthCheckTimeout.inSeconds} с',
  'Could not check in ${healthCheckTimeout.inSeconds} s',
);

/// The color of a step's state, shared by the sheet and the button's chain badge.
Color healthColor(BuildContext context, HealthState state) {
  final theme = Theme.of(context);
  return switch (state) {
    HealthState.ok => theme.extension<ConnectionButtonTheme>()!.connectedColor!,
    HealthState.pending => theme.colorScheme.primary,
    HealthState.failed => theme.colorScheme.error,
    HealthState.blocked => theme.colorScheme.outline,
  };
}

IconData chainIcon(ChainType type) => switch (type) {
  ChainType.extraSecurity => Icons.shield_rounded,
  ChainType.unblocker => Icons.meeting_room_rounded,
};

/// What a working step shows: the server's name and its ping.
String _serverDetail(OutboundInfo server) => '${server.name}  ·  ${server.urlTestDelay} ms';

/// The path the traffic takes, step by step, each with its state and what fixes it.
class ConnectionHealthSheet extends HookConsumerWidget {
  const ConnectionHealthSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // the check starts when the sheet opens and again with «Проверить снова»; whatever is still
    // pending after [healthCheckTimeout] shows as failed, so the sheet never hangs on a spinner
    final started = useState(DateTime.now());
    final tick = useState(0);
    useEffect(() {
      final left = healthCheckTimeout - DateTime.now().difference(started.value);
      final timer = Timer(left.isNegative ? Duration.zero : left + const Duration(milliseconds: 50), () => tick.value++);
      return timer.cancel;
    }, [started.value]);
    final elapsed = DateTime.now().difference(started.value);
    final timedOut = elapsed >= healthCheckTimeout;
    HealthState due(HealthState s) => healthWithDeadline(s, elapsed);
    final t = ref.watch(translationsProvider).requireValue;
    final h = t.connection.health;
    final theme = Theme.of(context);
    final health = ref.watch(connectionHealthProvider);
    if (health == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(t.connection.tapToConnect, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        ),
      );
    }
    final chain = health.chain;
    final chainName = chain?.present(t) ?? '';
    final active = ref.read(activeProxyNotifierProvider.notifier);

    // The hop's state as the proxy card shows it: slow after 15 s, failed after 60 s.
    final card = ref.watch(activeProxyCardProvider);
    final hop = card?.hopStatus;
    final hopState = due(healthSheetHopState(hop, health));
    final coreState = due(health.core);
    final pickState = due(health.pick);
    final fastestState = due(health.fastestState);
    String noAnswer() => hr(context, 'нет ответа за ${healthCheckTimeout.inSeconds} с', 'no answer in ${healthCheckTimeout.inSeconds} s');
    final unblocker = chain == ChainType.unblocker;
    // the group the user picked, such as balance; null for a single proxy
    final group = card?.group;
    // the same offer as the ping row: a dead proxy picked by hand while lowest answers
    final offer = card?.offerLowest ?? false;

    // the first thing that stops the traffic, in the order the steps connect
    final (summaryState, summary) = switch (health) {
      _ when coreState != HealthState.ok => (
        coreState,
        health.core == HealthState.failed ? h.coreNone : (timedOut ? _timedOut(context) : h.coreTesting),
      ),
      _ when unblocker && hopState == HealthState.failed => (HealthState.failed, h.hopFailed(chain: chainName)),
      _ when unblocker && hopState == HealthState.pending => (HealthState.pending, h.hopPending(chain: chainName)),
      _ when pickState == HealthState.failed => (HealthState.failed, health.pick == HealthState.failed ? h.pickDead : _timedOut(context)),
      _ when pickState == HealthState.pending => (HealthState.pending, h.testing),
      _ when hopState == HealthState.failed => (HealthState.failed, h.hopFailed(chain: chainName)),
      _ when hopState == HealthState.pending => (HealthState.pending, h.hopPending(chain: chainName)),
      _ when fastestState == HealthState.pending && !health.pickedByHand => (HealthState.pending, h.testing),
      _ => (HealthState.ok, h.allGood),
    };

    final hopStep = chain == null
        ? null
        : _Step(
            state: hopState,
            icon: chainIcon(chain),
            glyph: SizedBox.square(
              dimension: 22,
              child: FittedBox(
                child: ChainTypeIcon(
                  type: chain,
                  mode: card?.hopMode ?? ChainMode.psiphon,
                  animate: hopState != HealthState.blocked && hopState != HealthState.failed,
                ),
              ),
            ),
            title: chainName,
            detail: switch (hopState) {
              HealthState.ok => h.hopReady,
              HealthState.pending => hop == StepStatus.slow ? t.connection.slow : h.hopConnecting,
              HealthState.blocked => h.hopBlocked,
              HealthState.failed when healthSheetHopState(hop, health) == HealthState.pending => noAnswer(),
              HealthState.failed => health.hopNoReply ? h.hopNoReply : h.hopBroken,
            },
            actions: [
              if (hopState == HealthState.failed) ...[
                OutlinedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    context.goNamed('chainOptions');
                  },
                  child: Text(h.change),
                ),
                TextButton(
                  onPressed: () => ref.read(ConfigOptions.chainStatus.notifier).update(ChainStatus.off),
                  child: Text(h.turnOff),
                ),
              ],
            ],
          );

    // the steps in the order they connect: the unblocker before the servers, extra security after
    final steps = <_Step>[
      if (unblocker && hopStep != null) hopStep,
      // the fastest server is the pick itself with lowest, and the way out when the picked proxy is dead
      if (health.fastest != null && (!health.pickedByHand || offer))
        _Step(
          state: fastestState,
          icon: Icons.bolt_rounded,
          title: h.fastest,
          detail: switch (fastestState) {
            HealthState.ok => _serverDetail(health.fastest!),
            HealthState.failed when health.fastestState == HealthState.pending => noAnswer(),
            HealthState.failed => h.notResponding,
            _ => h.testing,
          },
        ),
      if (health.pickedByHand)
        _Step(
          state: pickState,
          icon: switch (group) {
            null => Icons.touch_app_rounded,
            balanceGroupTag => Icons.call_split_rounded,
            _ => Icons.layers_outlined,
          },
          title: group ?? h.yourServer,
          detail: switch (pickState) {
            HealthState.ok when group == balanceGroupTag => ref.watch(ConfigOptions.balancerStrategy).present(t),
            HealthState.ok => _serverDetail(health.server!),
            HealthState.failed when health.pick == HealthState.pending => '${health.server?.name ?? group ?? ''}  ·  ${noAnswer()}',
            HealthState.failed when group != null => h.notResponding,
            HealthState.failed => '${health.server?.name ?? ''}  ·  ${h.notResponding}',
            _ => h.testing,
          },
          actions: [
            if (offer)
              FilledButton.tonalIcon(
                onPressed: () => active.switchToLowest(health.mainGroup!),
                icon: const Icon(Icons.bolt_rounded, size: 18),
                label: Text(h.useFastest),
              ),
          ],
        ),
      if (!unblocker && hopStep != null) hopStep,
    ];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Gap(20),
            _Summary(state: summaryState, title: h.title, summary: summary),
            const Gap(20),
            for (final (i, step) in steps.indexed)
              _Rail(last: i == steps.length - 1, child: step)
                  .animate(delay: (60 * i).ms)
                  .fadeIn(duration: 220.ms)
                  .slideY(begin: .15, end: 0, duration: 220.ms, curve: Curves.easeOutCubic),
            const Gap(8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () {
                  started.value = DateTime.now();
                  unawaited(active.urlTest("").catchError((_) {}));
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(h.retry),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sheet's head: the overall state in a tinted circle, and one sentence.
class _Summary extends StatelessWidget {
  const _Summary({required this.state, required this.title, required this.summary});
  final HealthState state;
  final String title;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = healthColor(context, state);
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: color.withValues(alpha: .16), shape: BoxShape.circle),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _StateGlyph(state, key: ValueKey(state), size: 26),
          ),
        ),
        const Gap(16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const Gap(2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [...previous, if (current != null) current],
                ),
                child: Text(summary, key: ValueKey(summary), style: theme.textTheme.titleMedium),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A state as a glyph: a check, a spinner, a cross, or a pause for a step waiting on the one before.
class _StateGlyph extends StatelessWidget {
  const _StateGlyph(this.state, {super.key, required this.size});
  final HealthState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = healthColor(context, state);
    return Center(
      child: switch (state) {
        HealthState.ok => Icon(Icons.check_rounded, size: size, color: color),
        HealthState.failed => Icon(Icons.priority_high_rounded, size: size, color: color),
        HealthState.blocked => Icon(Icons.pause_rounded, size: size, color: color),
        HealthState.pending => SizedBox.square(
          dimension: size * .7,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: color),
        ),
      },
    );
  }
}

/// One step of the path, drawn as a station on a rail; [_Rail] draws the line to the next.
class _Step extends StatelessWidget {
  const _Step({
    required this.state,
    required this.icon,
    this.glyph,
    required this.title,
    required this.detail,
    this.actions,
  });
  final HealthState state;
  final IconData icon;

  /// Drawn in place of [icon], such as the chain's own animated icon.
  final Widget? glyph;
  final String title;
  final String detail;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = healthColor(context, state);
    final actions = this.actions ?? const [];
    return Semantics(
      container: true,
      label: '$title, $detail',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _Rail.station,
            height: _Rail.station,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: .6), width: 1.5),
                  ),
                  child: Center(child: glyph ?? Icon(icon, size: 18, color: color)),
                ),
                PositionedDirectional(
                  end: -4,
                  bottom: -4,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow, shape: BoxShape.circle),
                    child: _StateGlyph(state, size: 14),
                  ),
                ),
              ],
            ),
          ),
          const Gap(14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const Gap(2),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: state == HealthState.failed ? color : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (actions.isNotEmpty) ...[const Gap(10), Wrap(spacing: 8, runSpacing: 8, children: actions)],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Joins a step to the next with a line in the step's color.
class _Rail extends StatelessWidget {
  const _Rail({required this.last, required this.child});
  final bool last;
  final _Step child;

  static const station = 36.0;

  @override
  Widget build(BuildContext context) {
    final color = healthColor(context, child.state);
    return Stack(
      children: [
        if (!last)
          PositionedDirectional(
            start: station / 2 - 1,
            top: station + 4,
            bottom: 4,
            child: Container(
              width: 2,
              decoration: BoxDecoration(
                color: child.state == HealthState.ok ? color.withValues(alpha: .5) : null,
                borderRadius: BorderRadius.circular(1),
                gradient: child.state == HealthState.ok
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [color.withValues(alpha: .5), Theme.of(context).colorScheme.outlineVariant],
                      ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}
