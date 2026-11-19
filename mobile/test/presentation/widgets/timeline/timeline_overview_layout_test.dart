import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_overview.widget.dart';
import 'package:immich_mobile/providers/timeline/timeline_overview.provider.dart';

void main() {
  // 2025: Mar, Jan (one row); 2024: Dec, Nov, Oct (two rows)
  final years = [
    OverviewYear(year: 2025, months: [_month(2025, 3), _month(2025, 1)]),
    OverviewYear(year: 2024, months: [_month(2024, 12), _month(2024, 11), _month(2024, 10)]),
  ];
  // width 388 → month cards (388 - 24 - 8) / 2 = 178 high, rows 186 apart
  const layout = TimelineOverviewLayout(388);
  const header = TimelineOverviewLayout.yearHeaderHeight;

  test('month sections stack headers and rows', () {
    expect(layout.monthRowExtent, 186);
    expect([for (final (year, offset) in layout.monthSections(years)) (year.year, offset)], [
      (2025, 0),
      (2024, header + 186),
    ]);
  });

  test('finds the month card under a point', () {
    String at(double x, double y) {
      final (year, month) = layout.monthAt(years, x, y);
      return month == null ? '${year.year} header' : '${month.year}-${month.month}';
    }

    expect(at(50, 10), '2025 header');
    expect(at(50, header + 10), '2025-3');
    expect(at(300, header + 10), '2025-1');
    const section2024 = header + 186;
    expect(at(300, section2024 + 10), '2024 header');
    expect(at(300, section2024 + header + 10), '2024-11');
    // the lone card on the last row, and anything right of it or below
    expect(at(50, section2024 + header + 186 + 10), '2024-10');
    expect(at(300, section2024 + header + 186 + 10), '2024-10');
    expect(at(300, 1e6), '2024-10');
  });

  test('finds the year card under a point', () {
    expect(layout.yearAt(years, 0).year, 2025);
    expect(layout.yearAt(years, layout.yearExtent + 1).year, 2024);
    expect(layout.yearAt(years, 1e6).year, 2024);
  });

  test('focus offsets centre the card, or put a year header on top', () {
    const viewport = 600.0;
    const section2024 = header + 186;
    expect(layout.focusOffset(.months, years, (year: 2024, month: null), viewport), section2024);
    // October is on the second row of 2024
    expect(
      layout.focusOffset(.months, years, (year: 2024, month: 10), viewport),
      section2024 + header + 186 - (viewport - 186) / 2,
    );
    expect(
      layout.focusOffset(.years, years, (year: 2024, month: null), viewport),
      layout.yearExtent - (viewport - layout.yearExtent) / 2,
    );
    expect(layout.focusOffset(.years, years, (year: 1999, month: null), viewport), isNull);
  });
}

OverviewMonth _month(int year, int month) =>
    OverviewMonth(year: year, month: month, assetCount: 1, newestDate: DateTime(year, month));
