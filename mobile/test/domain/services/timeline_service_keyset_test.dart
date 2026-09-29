import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

import '../../fixtures/asset.stub.dart';

const _total = 5000;

class _FakeLibrary {
  final assets = List<BaseAsset>.generate(_total, (i) => LocalAssetStub.image1.copyWith(id: 'a$i'));
  final calls = <String>[];
  // Makes the next seek return one asset too few, as if the library changed
  bool shortenNextSeek = false;

  TimelineCursor cursorAt(int i) => (createdAt: 'created-$i', id: 'a$i');
  int positionOf(TimelineCursor cursor) => int.parse(cursor.id.substring(1));

  TimelinePage page(int from, int to) {
    final end = to.clamp(0, _total);
    return (assets: assets.sublist(from, end), cursors: [for (var i = from; i < end; i++) cursorAt(i)]);
  }

  TimelinePage seek(TimelinePage page) {
    if (!shortenNextSeek) {
      return page;
    }
    shortenNextSeek = false;
    return (assets: page.assets.skip(1).toList(), cursors: page.cursors.skip(1).toList());
  }

  late final TimelineKeysetSource keyset = (
    atOffset: (offset, count) async {
      calls.add('offset $offset');
      return page(offset, offset + count);
    },
    olderThan: (cursor, count) async {
      final from = positionOf(cursor) + 1;
      calls.add('older $from');
      return seek(page(from, from + count));
    },
    newerThan: (cursor, count) async {
      final to = positionOf(cursor);
      calls.add('newer ${to - count}');
      return seek(page(to - count, to));
    },
  );

  TimelineService service() => TimelineService((
    assetSource: (offset, count) async => throw StateError('offset source must not be used when a keyset exists'),
    bucketSource: () => Stream.value([TimeBucket(date: DateTime(2025), assetCount: _total)]),
    origin: TimelineOrigin.main,
  ), keysetSource: keyset);
}

void main() {
  late _FakeLibrary library;
  late TimelineService sut;

  Future<void> expectAssets(int index, int count) async {
    final loaded = await sut.loadAssets(index, count);
    expect(loaded, library.assets.sublist(index, index + count));
  }

  setUp(() async {
    library = _FakeLibrary();
    sut = library.service();
    await pumpEventQueue();
    expect(sut.totalAssets, _total);
    expect(library.calls, ['offset 0']);
    library.calls.clear();
  });

  tearDown(() => sut.dispose());

  test('scrolling down past the buffer seeks from the last loaded neighbour', () async {
    await expectAssets(1000, 50);
    expect(library.calls, ['older 936']);

    await expectAssets(1950, 30);
    expect(library.calls, ['older 936', 'older 1886']);
  });

  test('scrolling up past the buffer seeks from the first loaded neighbour', () async {
    await expectAssets(3000, 10); // jump: loads [2936, 3960) by offset
    library.calls.clear();

    await expectAssets(2900, 50); // starts above the buffer, ends inside it
    expect(library.calls, ['newer 1926']);
  });

  test('a scrubber jump far from the buffer counts by offset', () async {
    await expectAssets(4000, 10);
    expect(library.calls, ['offset 3936']);
  });

  test('a seek returning the wrong number of assets falls back to offset', () async {
    library.shortenNextSeek = true;
    await expectAssets(1000, 50);
    expect(library.calls, ['older 936', 'offset 936']);
  });

  test('the window at the end of the timeline seeks and returns the tail', () async {
    await expectAssets(4000, 10);
    library.calls.clear();
    await expectAssets(4990, 10);
    expect(library.calls, ['older 4926']);
  });
}
