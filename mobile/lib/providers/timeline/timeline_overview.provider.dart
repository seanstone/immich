import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

/// What the main timeline page shows: the year or month overview, or the timeline.
enum TimelineOverviewMode { years, months, all }

final timelineOverviewModeProvider = StateProvider<TimelineOverviewMode>((_) => TimelineOverviewMode.all);

/// Where an overview should open: a year, or a month within it.
typedef OverviewFocus = ({int year, int? month});

/// Consumed by the overview once it has laid out the focused mode.
final timelineOverviewFocusProvider = StateProvider<OverviewFocus?>((_) => null);

/// Switches the main timeline page to [mode], scrolled to [focus] if given.
void showTimelineOverview(WidgetRef ref, TimelineOverviewMode mode, {OverviewFocus? focus}) {
  ref.read(timelineOverviewFocusProvider.notifier).state = focus;
  ref.read(timelineOverviewModeProvider.notifier).state = mode;
}

class OverviewMonth {
  final int year;
  final int month;
  final int assetCount;

  /// The newest bucket date in this month; scrolling the timeline to it lands on
  /// the month's first header.
  final DateTime newestDate;

  const OverviewMonth({required this.year, required this.month, required this.assetCount, required this.newestDate});

  OverviewRange get range => (start: _groupDate(year, month), end: _groupDate(year + month ~/ 12, month % 12 + 1));
}

class OverviewYear {
  final int year;

  /// Newest first.
  final List<OverviewMonth> months;

  const OverviewYear({required this.year, required this.months});

  int get assetCount => months.fold(0, (sum, month) => sum + month.assetCount);

  OverviewRange get range => (start: _groupDate(year, 1), end: _groupDate(year + 1, 1));
}

/// A half-open range of group_date strings (yyyy-MM-dd).
typedef OverviewRange = ({String start, String end});

String _groupDate(int year, int month) =>
    '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-01';

/// Groups timeline buckets (by day or by month, newest first) into years and
/// months, newest first. Returns null when the buckets carry no dates, i.e.
/// the timeline is not grouped by date.
List<OverviewYear>? summariseTimelineBuckets(List<Bucket> buckets) {
  if (buckets.any((bucket) => bucket is! TimeBucket)) {
    return null;
  }

  final months = <(int, int), OverviewMonth>{};
  for (final bucket in buckets.cast<TimeBucket>()) {
    final key = (bucket.date.year, bucket.date.month);
    final existing = months[key];
    months[key] = OverviewMonth(
      year: key.$1,
      month: key.$2,
      assetCount: (existing?.assetCount ?? 0) + bucket.assetCount,
      newestDate: existing == null || bucket.date.isAfter(existing.newestDate) ? bucket.date : existing.newestDate,
    );
  }

  final sorted = months.values.toList()
    ..sort((a, b) => b.year != a.year ? b.year.compareTo(a.year) : b.month.compareTo(a.month));
  final years = <OverviewYear>[];
  for (final month in sorted) {
    if (years.isEmpty || years.last.year != month.year) {
      years.add(OverviewYear(year: month.year, months: [month]));
    } else {
      years.last.months.add(month);
    }
  }
  return years;
}

/// The main timeline summarised into years and months. Built from the buckets the
/// timeline has already loaded, so it costs no extra query and follows its updates.
final timelineOverviewProvider = StreamProvider.autoDispose<List<OverviewYear>?>(
  (ref) => ref.watch(timelineServiceProvider).watchLoadedBuckets().map(summariseTimelineBuckets),
);

/// The asset shown for a year or month: its newest favorite, or else its newest asset.
final timelineOverviewCoverProvider = FutureProvider.autoDispose.family<BaseAsset?, OverviewRange>((ref, range) async {
  // look again whenever the timeline reloads
  ref.watch(timelineOverviewProvider);
  final userIds = ref.watch(timelineUsersProvider).valueOrNull ?? const <String>[];
  if (userIds.isEmpty) {
    return null;
  }
  return ref
      .watch(driftProvider)
      .timelineRepository
      .mainCover(userIds, rangeStart: range.start, rangeEnd: range.end);
});
