import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/feature_message/feature_message_dialog.widget.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_overview.widget.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_overview.provider.dart';

@RoutePage()
class MainTimelinePage extends ConsumerStatefulWidget {
  const MainTimelinePage({super.key});

  @override
  ConsumerState<MainTimelinePage> createState() => _MainTimelinePageState();
}

class _MainTimelinePageState extends ConsumerState<MainTimelinePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final service = ref.read(featureMessageServiceProvider);
      if (!service.shouldShow()) {
        return;
      }

      await service.markSeen();
      if (!mounted) {
        return;
      }

      await showFeatureMessageDialog(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasMemories = ref.watch(memoryLaneProvider.select((state) => state.value?.isNotEmpty ?? false));
    final showOverview = ref.watch(timelineOverviewModeProvider) != TimelineOverviewMode.all;
    final isMultiSelectEnabled = ref.watch(multiSelectProvider.select((state) => state.isEnabled));
    // the timeline stays mounted under the overview, keeping its position and
    // letting a tapped month scroll it right away
    return Stack(
      children: [
        Timeline(
          topSliverWidget: const SliverToBoxAdapter(child: MemoryLane()),
          topSliverWidgetHeight: hasMemories ? 200 : 0,
          bottomSliverWidget: const SliverPadding(padding: EdgeInsets.only(bottom: kTimelineOverviewSwitchSpace)),
          showStorageIndicator: true,
          onPinchOutPastMinimum: (date) => showTimelineOverview(
            ref,
            TimelineOverviewMode.months,
            focus: date == null ? null : (year: date.year, month: date.month),
          ),
        ),
        if (showOverview) const Positioned.fill(child: TimelineOverview()),
        if (!isMultiSelectEnabled) const PositionedTimelineOverviewSwitch(),
      ],
    );
  }
}
