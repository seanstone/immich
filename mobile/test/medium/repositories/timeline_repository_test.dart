import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;

  setUpAll(() async {
    await initializeDateFormatting();
  });

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('main timeline keyset paging', () {
    String keyOf(BaseAsset asset) => asset is RemoteAsset ? 'r:${asset.id}' : 'l:${(asset as LocalAsset).id}';

    // 40 remote assets in groups of 3 sharing a timestamp, plus local-only assets
    // interleaved with them (some on the same timestamps), four remote assets whose
    // local date puts them in a later day group than their timestamp would, and
    // one local asset that is already backed up and must only appear as its
    // remote copy.
    Future<({TimelineKeysetSource keyset, List<String> reference, List<TimelineCursor> cursors})> seed() async {
      final user = await ctx.newUser();
      final album = await ctx.newLocalAlbum(backupSelection: .selected);
      final base = DateTime.utc(2024, 1, 1);
      for (var i = 0; i < 40; i++) {
        await ctx.newRemoteAsset(
          ownerId: user.id,
          checksum: 'remote-$i',
          createdAt: base.add(Duration(hours: i ~/ 3)),
        );
      }
      for (var i = 0; i < 4; i++) {
        await ctx.newRemoteAsset(
          ownerId: user.id,
          checksum: 'shifted-$i',
          createdAt: base.add(Duration(hours: i ~/ 2)),
          localDateTime: DateTime(2024, 1, 5, 12),
        );
      }
      for (var i = 0; i < 6; i++) {
        final local = await ctx.newLocalAsset(
          checksum: 'local-$i',
          createdAt: base.add(Duration(hours: i * 2, minutes: i.isEven ? 0 : 30)),
        );
        await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      }
      final backedUp = await ctx.newLocalAsset(checksum: 'remote-7', createdAt: base);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: backedUp.id);

      final keyset = sut.mainKeyset([user.id]);
      final reference = <String>[];
      final cursors = <TimelineCursor>[];
      for (var offset = 0; ; offset += 7) {
        final page = await keyset.atOffset(offset, 7);
        if (page.assets.isEmpty) {
          break;
        }
        reference.addAll(page.assets.map(keyOf));
        cursors.addAll(page.cursors);
      }
      return (keyset: keyset, reference: reference, cursors: cursors);
    }

    test('offset paging returns every asset exactly once, matching the offset asset source', () async {
      final (:keyset, :reference, :cursors) = await seed();
      expect(reference, hasLength(50));
      expect(reference.toSet(), hasLength(50));
      // the day group sorts first, so the shifted assets lead despite older timestamps
      expect(reference.take(4), everyElement(startsWith('r:')));
      expect(cursors.take(4).map((cursor) => cursor.groupDate), everyElement('2024-01-05'));

      final userId = (await ctx.db.select(ctx.db.userEntity).getSingle()).id;
      final viaAssetSource = (await sut.main([userId], .day).assetSource(0, 100)).map(keyOf).toList();
      expect(viaAssetSource, reference);
    });

    // Page sizes 1-8 against groups of 3 equal timestamps guarantee page
    // boundaries that split a tie group, where a missing tiebreaker drops assets.
    test('seeking older from each page end reproduces offset paging, ties included', () async {
      final (:keyset, :reference, cursors: _) = await seed();
      for (var size = 1; size <= 8; size++) {
        var page = await keyset.atOffset(0, size);
        final walked = [...page.assets.map(keyOf)];
        while (true) {
          page = await keyset.olderThan(page.cursors.last, size);
          if (page.assets.isEmpty) {
            break;
          }
          walked.addAll(page.assets.map(keyOf));
        }
        expect(walked, reference, reason: 'page size $size');
      }
    });

    test('seeking newer from each page start reproduces offset paging, ties included', () async {
      final (:keyset, :reference, cursors: _) = await seed();
      for (var size = 1; size <= 8; size++) {
        var page = await keyset.atOffset(reference.length - size, size);
        final walked = [...page.assets.map(keyOf)];
        while (true) {
          page = await keyset.newerThan(page.cursors.first, size);
          if (page.assets.isEmpty) {
            break;
          }
          walked.insertAll(0, page.assets.map(keyOf));
        }
        expect(walked, reference, reason: 'page size $size');
      }
    });
  });

  group('main timeline cover', () {
    test('picks the newest favorite in the range, else the newest asset, ignoring the range end', () async {
      final user = await ctx.newUser();
      Future<String> remote(String checksum, DateTime localDate, {bool favorite = false}) async =>
          (await ctx.newRemoteAsset(
            ownerId: user.id,
            checksum: checksum,
            createdAt: localDate.toUtc(),
            localDateTime: localDate,
            isFavorite: favorite,
          )).id;

      final oldFavorite = await remote('fav', DateTime(2024, 3, 5), favorite: true);
      final newest = await remote('newest', DateTime(2024, 3, 30));
      await remote('next-month', DateTime(2024, 4, 1));

      final march = await sut.mainCover([user.id], rangeStart: '2024-03-01', rangeEnd: '2024-04-01');
      expect((march! as RemoteAsset).id, oldFavorite);

      await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(oldFavorite))).write(
        const RemoteAssetEntityCompanion(isFavorite: Value(false)),
      );
      final unfavorited = await sut.mainCover([user.id], rangeStart: '2024-03-01', rangeEnd: '2024-04-01');
      expect((unfavorited! as RemoteAsset).id, newest);

      expect(await sut.mainCover([user.id], rangeStart: '2024-05-01', rangeEnd: '2024-06-01'), isNull);
    });

    test('includes local assets that are not backed up', () async {
      final user = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: user.id, checksum: 'remote', createdAt: DateTime.utc(2024, 3, 2, 12));
      final album = await ctx.newLocalAlbum(backupSelection: .selected);
      final local = await ctx.newLocalAsset(checksum: 'local', createdAt: DateTime.utc(2024, 3, 20, 12));
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);

      final cover = await sut.mainCover([user.id], rangeStart: '2024-03-01', rangeEnd: '2024-04-01');
      expect((cover! as LocalAsset).id, local.id);
    });
  });

  group('remoteAlbum assets', () {
    test('no duplicate assets when identical checksum appears in multiple local asset rows', () async {
      // Regression check for #23273: a LEFT OUTER JOIN on checksum would fan out and create duplicates
      // happens when same photo exists in multiple albums on device
      final user = await ctx.newUser();
      const checksum = 'yolo';
      final album = await ctx.newRemoteAlbum(ownerId: user.id);
      final remoteAsset = await ctx.newRemoteAsset(ownerId: user.id, checksum: checksum);
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: remoteAsset.id);

      final localAsset1 = await ctx.newLocalAsset(checksum: checksum);
      final localAsset2 = await ctx.newLocalAsset(checksum: checksum);

      final query = sut.remoteAlbum(album.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);

      final assets = await query.assetSource(0, 10);
      expect(assets, hasLength(1));
      expect((assets.first as RemoteAsset).id, remoteAsset.id);
      expect([localAsset1.id, localAsset2.id], contains((assets.first as RemoteAsset).localId));
    });

    test('orders shifted album assets in both directions and keeps normal asset order (#28852)', () async {
      final user = await ctx.newUser();
      final descendingAlbum = await ctx.newRemoteAlbum(ownerId: user.id, order: .desc);
      final ascendingAlbum = await ctx.newRemoteAlbum(ownerId: user.id, order: .asc);
      final shiftedLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final shiftedEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 3, 12),
        localDateTime: DateTime.utc(2024, 9, 2, 12),
      );
      final normalLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 4, 14),
        localDateTime: DateTime.utc(2024, 9, 4, 14),
      );
      final normalEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 4, 12),
        localDateTime: DateTime.utc(2024, 9, 4, 12),
      );
      final seeded = [shiftedLater, shiftedEarlier, normalLater, normalEarlier];
      for (final asset in seeded) {
        await ctx.newRemoteAlbumAsset(albumId: descendingAlbum.id, assetId: asset.id);
        await ctx.newRemoteAlbumAsset(albumId: ascendingAlbum.id, assetId: asset.id);
      }

      final descending = sut.remoteAlbum(descendingAlbum.id, .day);
      final ascending = sut.remoteAlbum(ascendingAlbum.id, .day);

      final buckets = await descending.bucketSource().first;
      expect(buckets, hasLength(3));
      expect(buckets.map((bucket) => bucket.assetCount), [2, 1, 1]);

      final descendingAssets = await descending.assetSource(0, 10);
      expect(descendingAssets.map((asset) => (asset as RemoteAsset).id), [
        normalLater.id,
        normalEarlier.id,
        shiftedLater.id,
        shiftedEarlier.id,
      ]);

      final ascendingAssets = await ascending.assetSource(0, 10);
      expect(ascendingAssets.map((asset) => (asset as RemoteAsset).id), [
        shiftedEarlier.id,
        shiftedLater.id,
        normalEarlier.id,
        normalLater.id,
      ]);
    });
  });

  group('person assets', () {
    test('includes partner assets even when the partner is not shown in the timeline', () async {
      final user = await ctx.newUser();
      final partner = await ctx.newUser();
      final stranger = await ctx.newUser();
      await ctx.newPartner(sharedById: partner.id, sharedWithId: user.id, inTimeline: false);

      final person = await ctx.newPerson(ownerId: user.id);
      final partnerAsset = await ctx.newRemoteAsset(ownerId: partner.id);
      final strangerAsset = await ctx.newRemoteAsset(ownerId: stranger.id);
      await ctx.newFace(assetId: partnerAsset.id, personId: person.id);
      await ctx.newFace(assetId: strangerAsset.id, personId: person.id);

      final assets = await sut.person(user.id, person.id, .day).assetSource(0, 10);
      expect(assets.map((a) => (a as RemoteAsset).id), [partnerAsset.id]);
    });

    test('does not duplicate an asset that has multiple face records for the same person', () async {
      // Regression check for #26723: an INNER JOIN between remote_asset_entity and asset_face_entity
      // fanned out one asset into N rows when N face records pointed at the same (asset, person) pair
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);

      final person = await ctx.newPerson(ownerId: user.id);
      await ctx.newFace(assetId: asset.id, personId: person.id);
      await ctx.newFace(assetId: asset.id, personId: person.id);

      final query = sut.person(user.id, person.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);

      final assets = await query.assetSource(0, 10);
      expect(assets, hasLength(1));
      expect((assets.first as RemoteAsset).id, asset.id);
    });

    test('orders shifted person assets by effective date (#28852)', () async {
      final user = await ctx.newUser();
      final person = await ctx.newPerson(ownerId: user.id);
      final shiftedLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final shiftedEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 3, 12),
        localDateTime: DateTime.utc(2024, 9, 2, 12),
      );
      await ctx.newFace(assetId: shiftedLater.id, personId: person.id);
      await ctx.newFace(assetId: shiftedEarlier.id, personId: person.id);

      final query = sut.person(user.id, person.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(2));

      final assets = await query.assetSource(0, 10);
      expect(assets.map((asset) => (asset as RemoteAsset).id), [shiftedLater.id, shiftedEarlier.id]);
    });
  });

  group('live photos', () {
    test('remote-only live photo contains livePhotoVideoId and is marked as a motion photo', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id, livePhotoVideoId: 'motion-photo-1');

      final assets = await sut.main([user.id], .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect(remote.livePhotoVideoId, 'motion-photo-1');
      expect(remote.isMotionPhoto, isTrue);
      expect(remote.localId, isNull);
    });

    test('merged live photo resolves localId and is marked as a motion photo', () async {
      final user = await ctx.newUser();
      const checksum = 'shared-live-photo-checksum';
      final asset = await ctx.newRemoteAsset(ownerId: user.id, checksum: checksum, livePhotoVideoId: 'motion-photo-2');
      final local = await ctx.newLocalAsset(checksum: checksum);

      final assets = await sut.main([user.id], .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect(remote.livePhotoVideoId, 'motion-photo-2');
      expect(remote.isMotionPhoto, isTrue);
      expect(remote.localId, local.id);
    });
  });

  group('localAlbum assets', () {
    late String userId;
    late String otherUserId;

    setUp(() async {
      final user = await ctx.newUser();
      userId = user.id;
      await ctx.newAuthUser(id: userId);
      final other = await ctx.newUser();
      otherUserId = other.id;
    });

    test('does not duplicate assets when a partner shares the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final album = await ctx.newLocalAlbum();
      final local = await ctx.newLocalAsset(checksum: checksum);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      final myRemote = await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      await ctx.newRemoteAsset(ownerId: otherUserId, checksum: checksum);

      final assets = await sut.localAlbum(album.id, .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final asset = assets.single as LocalAsset;
      expect(asset.id, local.id);
      // Must resolve the current user's remote id
      expect(asset.remoteId, myRemote.id);
    });

    test('bucket count ignores a partner sharing the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final album = await ctx.newLocalAlbum();
      final local = await ctx.newLocalAsset(checksum: checksum);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      await ctx.newRemoteAsset(ownerId: otherUserId, checksum: checksum);

      final buckets = await sut.localAlbum(album.id, .day).bucketSource().first;

      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);
    });
  });
}
