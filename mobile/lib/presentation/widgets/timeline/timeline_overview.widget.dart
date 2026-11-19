import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/timeline/timeline_overview.provider.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:intl/intl.dart';

const double _switchHeight = 40;
const double _switchMargin = 12;

/// Space to leave below scrolling content so the floating switch does not cover it.
const double kTimelineOverviewSwitchSpace = _switchHeight + 2 * _switchMargin;

/// Shows the timeline at [month], leaving the overview.
void showTimelineAtMonth(WidgetRef ref, OverviewMonth month) {
  showTimelineOverview(ref, TimelineOverviewMode.all);
  // the timeline stays mounted under the overview, so it can scroll right away
  WidgetsBinding.instance.addPostFrameCallback((_) => EventStream.shared.emit(ScrollToDateEvent(month.newestDate)));
}

/// Floating Year / Month / All photos switch.
class TimelineOverviewSwitch extends ConsumerWidget {
  const TimelineOverviewSwitch({super.key});

  static const _inset = 3.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(timelineOverviewModeProvider);
    final labels = {
      TimelineOverviewMode.years: context.t.year,
      TimelineOverviewMode.months: context.t.month,
      TimelineOverviewMode.all: context.t.all_photos,
    };
    return Material(
      elevation: 3,
      shape: const StadiumBorder(),
      color: context.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(_inset),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final MapEntry(key: value, value: label) in labels.entries)
              _SwitchSegment(label: label, selected: value == mode, onTap: () => showTimelineOverview(ref, value)),
          ],
        ),
      ),
    );
  }
}

class _SwitchSegment extends StatelessWidget {
  const _SwitchSegment({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: _switchHeight - 2 * TimelineOverviewSwitch._inset,
          constraints: const BoxConstraints(minWidth: 72),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: selected ? colorScheme.secondaryContainer : Colors.transparent,
          ),
          child: Text(
            label,
            style: context.textTheme.labelLarge?.copyWith(
              color: selected ? colorScheme.onSecondaryContainer : colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// The floating switch, positioned over the bottom of a page-sized [Stack].
class PositionedTimelineOverviewSwitch extends StatelessWidget {
  const PositionedTimelineOverviewSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 0,
      right: 0,
      bottom: _switchMargin,
      child: Center(child: TimelineOverviewSwitch()),
    );
  }
}

/// Geometry of the overview grids, which is fixed so positions are computed
/// rather than measured. Offsets are from the start of the cards.
@visibleForTesting
class TimelineOverviewLayout {
  static const padding = 12.0;
  static const spacing = 8.0;
  static const yearHeaderHeight = 52.0;

  final double width;

  const TimelineOverviewLayout(this.width);

  double get yearExtent => (width - 2 * padding) * 0.62 + spacing;
  double get monthCardHeight => (width - 2 * padding - spacing) / 2;
  double get monthRowExtent => monthCardHeight + spacing;

  double yearSectionExtent(OverviewYear year) => yearHeaderHeight + (year.months.length / 2).ceil() * monthRowExtent;

  /// Each year's section in the month overview, with its offset.
  Iterable<(OverviewYear, double)> monthSections(List<OverviewYear> years) sync* {
    var offset = 0.0;
    for (final year in years) {
      yield (year, offset);
      offset += yearSectionExtent(year);
    }
  }

  /// The year card at [y] in the year overview.
  OverviewYear yearAt(List<OverviewYear> years, double y) => years[(y / yearExtent).floor().clamp(0, years.length - 1)];

  /// The year section and month card at ([x], [y]) in the month overview; the
  /// month is null on a year header.
  (OverviewYear, OverviewMonth?) monthAt(List<OverviewYear> years, double x, double y) {
    var found = years.first;
    var sectionTop = 0.0;
    for (final (year, offset) in monthSections(years)) {
      if (offset > y) {
        break;
      }
      found = year;
      sectionTop = offset;
    }
    final inSection = y - sectionTop - yearHeaderHeight;
    if (inSection < 0) {
      return (found, null);
    }
    final row = (inSection / monthRowExtent).floor();
    final index = (row * 2 + (x < width / 2 ? 0 : 1)).clamp(0, found.months.length - 1);
    return (found, found.months[index]);
  }

  /// Offset that centres the card for [focus] in a viewport of [viewport] height,
  /// or puts the year header at the top when [focus] names no month.
  double? focusOffset(TimelineOverviewMode mode, List<OverviewYear> years, OverviewFocus focus, double viewport) {
    if (mode == TimelineOverviewMode.years) {
      final index = years.indexWhere((year) => year.year == focus.year);
      return index < 0 ? null : index * yearExtent - (viewport - yearExtent) / 2;
    }
    for (final (year, offset) in monthSections(years)) {
      if (year.year != focus.year) {
        continue;
      }
      final monthIndex = year.months.indexWhere((month) => month.month == focus.month);
      if (monthIndex < 0) {
        return offset;
      }
      final rowTop = offset + yearHeaderHeight + (monthIndex ~/ 2) * monthRowExtent;
      return rowTop - (viewport - monthRowExtent) / 2;
    }
    return null;
  }
}

/// The main timeline summarised as one card per year or per month. Tap or pinch
/// in to go a level deeper (year → months → timeline), pinch out to go back up.
class TimelineOverview extends ConsumerStatefulWidget {
  const TimelineOverview({super.key});

  @override
  ConsumerState<TimelineOverview> createState() => _TimelineOverviewState();
}

class _TimelineOverviewState extends ConsumerState<TimelineOverview> {
  final _scrollController = ScrollController();
  // Scroll offset where the cards start, below the app bar; set during layout
  double _contentStart = 0;
  bool _pinchHandled = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToFocus(TimelineOverviewMode mode, OverviewFocus focus, List<OverviewYear> years, double width) {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final offset = TimelineOverviewLayout(width).focusOffset(mode, years, focus, position.viewportDimension);
    if (offset != null) {
      _scrollController.jumpTo((_contentStart + offset).clamp(0.0, position.maxScrollExtent));
    }
  }

  void _onPinch(ScaleUpdateDetails details, TimelineOverviewMode mode, List<OverviewYear>? years, double width) {
    if (_pinchHandled || details.pointerCount < 2 || years == null || years.isEmpty || !_scrollController.hasClients) {
      return;
    }
    final zoomOut = details.scale < 0.75;
    final zoomIn = details.scale > 1.35;
    if (!zoomOut && !zoomIn) {
      return;
    }
    _pinchHandled = true;
    final contentY = _scrollController.offset + details.localFocalPoint.dy - _contentStart;

    if (mode == TimelineOverviewMode.years) {
      if (zoomIn) {
        final year = TimelineOverviewLayout(width).yearAt(years, contentY);
        showTimelineOverview(ref, TimelineOverviewMode.months, focus: (year: year.year, month: null));
      }
      return;
    }

    final (year, month) = TimelineOverviewLayout(width).monthAt(years, details.localFocalPoint.dx, contentY);
    if (zoomOut) {
      showTimelineOverview(ref, TimelineOverviewMode.years, focus: (year: year.year, month: null));
    } else {
      showTimelineAtMonth(ref, month ?? year.months.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(timelineOverviewModeProvider);
    final years = ref.watch(timelineOverviewProvider).valueOrNull;
    final focus = ref.watch(timelineOverviewFocusProvider);

    return Material(
      color: context.colorScheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (focus != null && years != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) {
                return;
              }
              ref.read(timelineOverviewFocusProvider.notifier).state = null;
              _scrollToFocus(mode, focus, years, width);
            });
          }

          final List<Widget> content = switch (years) {
            null => [
              const SliverToBoxAdapter(
                child: SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
              ),
            ],
            _ when mode == TimelineOverviewMode.years => _yearSlivers(years, width),
            _ => _monthSlivers(years, width),
          };

          return RawGestureDetector(
            gestures: {
              _SharedScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<_SharedScaleGestureRecognizer>(
                _SharedScaleGestureRecognizer.new,
                (recognizer) {
                  recognizer.onStart = (_) => _pinchHandled = false;
                  recognizer.onUpdate = (details) => _onPinch(details, mode, years, width);
                },
              ),
            },
            child: CustomScrollView(
              // a fresh position for each mode, so switching starts at the top
              key: ValueKey(mode),
              controller: _scrollController,
              slivers: [
                const ImmichSliverAppBar(floating: true, pinned: false, snap: false),
                SliverLayoutBuilder(
                  builder: (context, constraints) {
                    _contentStart = constraints.precedingScrollExtent;
                    return SliverMainAxisGroup(slivers: content);
                  },
                ),
                const SliverPadding(padding: EdgeInsets.only(bottom: kTimelineOverviewSwitchSpace)),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _yearSlivers(List<OverviewYear> years, double width) {
    final layout = TimelineOverviewLayout(width);
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: TimelineOverviewLayout.padding),
        sliver: SliverFixedExtentList(
          itemExtent: layout.yearExtent,
          delegate: SliverChildBuilderDelegate((context, index) {
            final year = years[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: TimelineOverviewLayout.spacing),
              child: _OverviewCard(
                range: year.range,
                title: year.year.toString(),
                titleStyle: context.textTheme.headlineMedium,
                assetCount: year.assetCount,
                large: true,
                onTap: () =>
                    showTimelineOverview(ref, TimelineOverviewMode.months, focus: (year: year.year, month: null)),
              ),
            );
          }, childCount: years.length),
        ),
      ),
    ];
  }

  List<Widget> _monthSlivers(List<OverviewYear> years, double width) {
    final monthFormat = DateFormat.MMMM(resolvedDateTimeLocale());
    final layout = TimelineOverviewLayout(width);
    return [
      for (final year in years) ...[
        SliverToBoxAdapter(
          child: SizedBox(
            height: TimelineOverviewLayout.yearHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: TimelineOverviewLayout.padding + 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  year.year.toString(),
                  style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.only(
            left: TimelineOverviewLayout.padding,
            right: TimelineOverviewLayout.padding,
            bottom: TimelineOverviewLayout.spacing,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: TimelineOverviewLayout.spacing,
              crossAxisSpacing: TimelineOverviewLayout.spacing,
              mainAxisExtent: layout.monthCardHeight,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final month = year.months[index];
              return _OverviewCard(
                range: month.range,
                title: monthFormat.format(DateTime(month.year, month.month)),
                titleStyle: context.textTheme.titleMedium,
                assetCount: month.assetCount,
                large: false,
                onTap: () => showTimelineAtMonth(ref, month),
              );
            }, childCount: year.months.length),
          ),
        ),
      ],
    ];
  }
}

/// Takes part in the gesture arena without stopping the scroll view underneath,
/// as the timeline's pinch zoom does.
class _SharedScaleGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void rejectGesture(int pointer) {
    acceptGesture(pointer);
  }
}

class _OverviewCard extends ConsumerWidget {
  const _OverviewCard({
    required this.range,
    required this.title,
    required this.titleStyle,
    required this.assetCount,
    required this.large,
    required this.onTap,
  });

  final OverviewRange range;
  final String title;
  final TextStyle? titleStyle;
  final int assetCount;
  // large cards decode a preview rather than the small thumbnail
  final bool large;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cover = ref.watch(timelineOverviewCoverProvider(range)).valueOrNull;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: context.colorScheme.surfaceContainerHighest),
            if (cover != null)
              large
                  ? Thumbnail(
                      imageProvider: getFullImageProvider(cover, size: const Size(1080, 1080)),
                      thumbhashProvider: getThumbnailImageProvider(cover),
                    )
                  : Thumbnail.fromAsset(asset: cover),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.55, 1],
                  colors: [Colors.transparent, Color(0x99000000)],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    context.t.items_count(count: assetCount),
                    style: context.textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
