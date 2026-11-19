import 'package:immich_mobile/data/db/main/database.dart';
import 'package:logging/logging.dart';

/// Indexes added on top of the upstream schema. They are created at runtime
/// rather than through schema migrations, so no schema version is claimed that
/// upstream may later use for its own migration.
const kForkIndexes = <String>[
  // Covers the timeline's stack check in sort order, so the bucket aggregate is
  // a covering index scan and timeline pages can skip and seek on the index
  // alone. Upstream's idx_remote_asset_group lacks stack_id, which forces a
  // table lookup for every timeline asset.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_timeline_group ON remote_asset_entity (owner_id, visibility, deleted_at, group_date DESC, created_at DESC, id DESC, stack_id)',
  // Seeks the newest favorite in a date range for the year and month overview
  // covers. Partial, so it only holds favorites.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_timeline_favorite ON remote_asset_entity (owner_id, visibility, deleted_at, group_date DESC, created_at DESC, id DESC, stack_id) WHERE is_favorite = 1',
  // Covers the album list's per-membership trash check.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_id_deleted ON remote_asset_entity (id, deleted_at)',
  // Covers the backed-up check that hides local assets with a remote copy.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_checksum_owner ON remote_asset_entity (checksum, owner_id)',
];

/// Fork indexes that earlier builds created and nothing uses any more. Index
/// names are never reused with a different definition, since an existing
/// index would keep its old columns under IF NOT EXISTS.
const kObsoleteForkIndexes = <String>[
  // Sorted on created_at, before upstream grouped the timeline on group_date.
  'idx_remote_asset_timeline_bucket',
  'idx_remote_asset_timeline_order',
];

/// Drops [kObsoleteForkIndexes] and creates any missing index from [kForkIndexes].
///
/// Call from the main isolate only, after the first frame. Building an index on
/// a populated table holds the write lock for the whole build, and isolates that
/// open the database meanwhile wait on it up to the busy timeout.
Future<void> ensureForkIndexes(Drift db) async {
  final log = Logger('ForkIndexes');
  for (final name in kObsoleteForkIndexes) {
    try {
      await db.customStatement('DROP INDEX IF EXISTS $name');
    } catch (error, stack) {
      log.warning('Failed to drop index $name', error, stack);
    }
  }
  for (final statement in kForkIndexes) {
    final stopwatch = Stopwatch()..start();
    try {
      await db.customStatement(statement);
    } catch (error, stack) {
      log.warning('Failed to create index: $statement', error, stack);
      continue;
    }
    if (stopwatch.elapsedMilliseconds > 100) {
      log.info('Built index in ${stopwatch.elapsedMilliseconds}ms: $statement');
    }
  }
}
