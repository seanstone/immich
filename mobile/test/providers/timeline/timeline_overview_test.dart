import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/providers/timeline/timeline_overview.provider.dart';

void main() {
  TimeBucket day(int year, int month, int day, int count) =>
      TimeBucket(date: DateTime(year, month, day), assetCount: count);

  test('groups day buckets into months and years, newest first', () {
    final years = summariseTimelineBuckets([
      day(2025, 3, 20, 4),
      day(2025, 3, 2, 1),
      day(2025, 1, 31, 2),
      day(2023, 12, 25, 7),
    ])!;

    expect(years.map((year) => year.year), [2025, 2023]);
    expect(years.map((year) => year.assetCount), [7, 7]);
    expect([for (final month in years.first.months) (month.month, month.assetCount)], [(3, 5), (1, 2)]);
    // scrolling the timeline to the newest day lands on the month's first header
    expect(years.first.months.first.newestDate, DateTime(2025, 3, 20));
  });

  test('accepts month buckets', () {
    final years = summariseTimelineBuckets([day(2024, 6, 1, 10), day(2024, 5, 1, 3)])!;
    expect([for (final month in years.single.months) (month.month, month.assetCount)], [(6, 10), (5, 3)]);
  });

  test('ranges are half-open group_date ranges, December rolling into the next year', () {
    final years = summariseTimelineBuckets([day(2024, 12, 31, 1), day(2024, 2, 29, 1)])!;
    final year = years.single;
    expect(year.range, (start: '2024-01-01', end: '2025-01-01'));
    expect(year.months.first.range, (start: '2024-12-01', end: '2025-01-01'));
    expect(year.months.last.range, (start: '2024-02-01', end: '2024-03-01'));
  });

  test('returns null when the buckets carry no dates', () {
    expect(summariseTimelineBuckets([const Bucket(assetCount: 3)]), isNull);
    expect(summariseTimelineBuckets([]), isEmpty);
  });
}
