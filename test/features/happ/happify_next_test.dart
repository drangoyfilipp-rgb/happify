import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/happ/happify_traffic_saving.dart';

void main() {
  test('saving traffic updates far less often', () {
    expect(happSavingUpdateInterval(const Duration(hours: 1)), const Duration(hours: 6));
    expect(happSavingUpdateInterval(const Duration(hours: 4)), const Duration(hours: 12));
    expect(happTrafficSavingMode('nope'), HappTrafficSaving.auto);
    expect(happTrafficSavingMode('on'), HappTrafficSaving.on);
    expect(happPingBudget(true), greaterThan(happPingBudget(false)));
  });
}
