// «Уведомления»: which kinds exist, which are on by default, and when the subscription ones fire.
// Pure, for the tests (test/features/happ/happ_notify_rules_test.dart).

enum HappNotifyType {
  /// The subscription ends in 3 days, then in 1 day.
  subExpiring(true),

  /// Less than a tenth of the subscription's traffic is left.
  trafficLow(true),

  /// The VPN could not connect, or the internet is gone while connected.
  vpnProblem(true),

  /// «Автопереключение при сбое» moved to another server.
  serverSwitched(false),

  /// Every server of one protocol failed and another protocol is used as a reserve.
  throttled(false),

  /// A subscription was updated.
  subUpdated(false),

  /// A ping or speed test finished.
  testResults(false);

  const HappNotifyType(this.defaultOn);

  /// Only what needs the user is on by default; the rest is opt-in.
  final bool defaultOn;

  String get prefKey => 'happify_notify_$name';

  /// Important ones go to the channel that makes a sound; the rest are quiet.
  bool get important => this == subExpiring || this == trafficLow || this == vpnProblem;

  /// The notification id: one per kind (and per subscription for the subscription ones). Each kind
  /// owns its own block of a thousand ids, so two kinds never share one.
  int idFor([String? profileId]) => happNotifyBaseId + index * 1000 + (happStableHash(profileId ?? '').abs() % 1000);
}

const int happNotifyBaseId = 7000;

/// A hash of [s] that is the same in every run and Dart version (FNV-1a, 31 bits), unlike
/// [String.hashCode], so a subscription keeps its notification id.
int happStableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// The «Нет интернета» / «VPN не смог подключиться» notification comes at most this often.
const Duration happNoInternetNotifyEvery = Duration(minutes: 30);

/// Whether the «нет интернета» notification may come now, the last one having come at [last].
bool happNoInternetNotifyDue(DateTime? last, DateTime now) =>
    last == null || now.difference(last) >= happNoInternetNotifyEvery;

/// Whole days left until [expire], counted up (2 days 3 hours is 3), at least 1.
int happDaysLeft({required DateTime expire, required DateTime now}) {
  final minutes = expire.difference(now).inMinutes;
  if (minutes <= 0) return 1;
  final days = (minutes + 24 * 60 - 1) ~/ (24 * 60);
  return days < 1 ? 1 : days;
}

/// «Остался 1 день», «Осталось 3 дня», «Осталось 5 дней»; English «1 day left», «3 days left».
String happDaysLeftText(int days, {required bool ru}) {
  if (!ru) return days == 1 ? '1 day left' : '$days days left';
  final mod10 = days % 10;
  final mod100 = days % 100;
  if (mod10 == 1 && mod100 != 11) return 'Остался $days день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'Осталось $days дня';
  return 'Осталось $days дней';
}

/// Whether [type] is on, given what is saved ([saved] null: never changed).
bool happNotifyOn(HappNotifyType type, bool? saved) => saved ?? type.defaultOn;

/// Which warning is due for a subscription ending at [expire]: 1 (a day or less left), 3 (three
/// days or less), or null (none due, already sent, or already over). [sent] holds the ones already
/// sent for this same end date. A day-left warning replaces the three-day one when both are due.
int? happExpiryWarning({required DateTime expire, required DateTime now, required Set<int> sent}) {
  final left = expire.difference(now);
  if (left <= Duration.zero) return null;
  // an end date far away is a subscription without one (Happ writes 2099 or 0)
  if (expire.year > 2900) return null;
  if (left <= const Duration(days: 1)) return sent.contains(1) ? null : 1;
  if (left <= const Duration(days: 3)) return sent.contains(3) ? null : 3;
  return null;
}

/// The saved record of expiry warnings: "<end ms>:<sent,…>"; another end date (a renewal) starts over.
Set<int> happReadExpirySent(String? raw, DateTime expire) {
  if (raw == null) return {};
  final parts = raw.split(':');
  if (parts.length != 2 || parts[0] != '${expire.millisecondsSinceEpoch}') return {};
  return {
    for (final s in parts[1].split(','))
      if (int.tryParse(s) case final n?) n,
  };
}

String happWriteExpirySent(DateTime expire, Set<int> sent) =>
    '${expire.millisecondsSinceEpoch}:${(sent.toList()..sort()).join(',')}';

/// Whether the traffic is running out: a real limit (not unlimited) with a tenth of it or less left.
bool happTrafficLow({required int used, required int total}) {
  if (total <= 0) return false;
  // what the card calls unlimited
  if (total > 10 * 1099511627776) return false;
  return total - used <= total ~/ 10;
}

/// One traffic warning per period: the period is the limit and the end date together.
String happTrafficPeriod(int total, DateTime? expire) => '$total:${expire?.millisecondsSinceEpoch ?? 0}';
