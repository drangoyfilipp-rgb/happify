import 'package:flutter/material.dart';
import 'package:hiddify/features/happ/happ_sub.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/uri_utils.dart';

/// Announcements a subscription sends the Happ way: `sub-expire`, `sub-info-*`, `announce`.
class HappAnnounceCard extends StatelessWidget {
  const HappAnnounceCard({super.key, required this.profile});

  final RemoteProfileEntity profile;

  static bool hasContent(RemoteProfileEntity p) => _content(p) != null;

  /// What the subscription announces, for Happ's card on the home screen; null when nothing.
  static ({String text, Color? color, String? buttonText, String? link})? contentOf(RemoteProfileEntity p) =>
      _content(p);

  static ({String text, Color? color, String? buttonText, String? link})? _content(RemoteProfileEntity p) {
    final h = p.populatedHeaders ?? const {};
    final expire = p.subInfo?.expire;
    if (HappSub.isOn(h['sub-expire']) && expire != null && expire.year < 2900) {
      final left = expire.difference(DateTime.now());
      final link = h['sub-expire-button-link']?.toString();
      if (left.isNegative) {
        return (text: 'Подписка закончилась!', color: Colors.red, buttonText: link != null ? 'Продлить' : null, link: link);
      }
      if (left.inDays < 3) {
        final d = left.inDays < 1 ? 1 : left.inDays;
        return (
          text: 'Ваша подписка заканчивается через $d д.',
          color: Colors.orange,
          buttonText: link != null ? 'Продлить' : null,
          link: link,
        );
      }
    }
    final info = HappSub.text(h['sub-info-text']);
    if (info != null) {
      final c = switch (h['sub-info-color']?.toString().toLowerCase()) {
        'red' => Colors.red,
        'green' => Colors.green,
        _ => Colors.blue,
      };
      final bt = HappSub.text(h['sub-info-button-text']);
      final bl = h['sub-info-button-link']?.toString();
      return (text: _cut(info, 200), color: c, buttonText: bl != null ? (bt ?? 'Открыть') : null, link: bl);
    }
    final announce = HappSub.text(h['announce']);
    if (announce != null) return (text: _cut(announce, 200), color: null, buttonText: null, link: null);
    return null;
  }

  static String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

  @override
  Widget build(BuildContext context) {
    final c = _content(profile);
    if (c == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final base = c.color ?? theme.colorScheme.secondary;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: base.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: base.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.campaign_rounded, color: base, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(c.text, style: theme.textTheme.bodyMedium)),
            if (c.buttonText != null && c.link != null)
              TextButton(
                onPressed: () {
                  final uri = Uri.tryParse(c.link!);
                  if (uri != null) UriUtils.tryLaunch(uri);
                },
                child: Text(c.buttonText!),
              ),
          ],
        ),
      ),
    );
  }
}
