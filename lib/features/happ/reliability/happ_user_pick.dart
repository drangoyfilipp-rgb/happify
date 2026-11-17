import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The main selector of hiddify-core's config (OutboundSelectTag in v2/config/builder.go): the
/// group whose choice is the user's server.
const happMainSelectorTag = 'select';

/// The user picked [outboundTag] in [groupTag]: a tap on a server (home, servers page), «Сменить
/// сервер», «Переключить на lowest». The only source of the user's choice: HappifyLifecycle saves
/// it as the profile's last server and «Автопереключение при сбое» keeps and returns to it. A switch
/// the app makes by itself never emits one.
///
/// No equality: each pick is a new event, even the same server tapped twice.
class HappUserPick {
  HappUserPick(this.groupTag, this.outboundTag);

  final String groupTag;
  final String outboundTag;

  @override
  String toString() => 'HappUserPick($groupTag, $outboundTag)';
}

/// The latest [HappUserPick]; listen to it (its value alone is not the state of anything).
final happUserPickProvider = StateProvider<HappUserPick?>((ref) => null);

/// Emits a pick from a provider or a notifier.
void happEmitUserPick(Ref ref, String groupTag, String outboundTag) =>
    ref.read(happUserPickProvider.notifier).state = HappUserPick(groupTag, outboundTag);
