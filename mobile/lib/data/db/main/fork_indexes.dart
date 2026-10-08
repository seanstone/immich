import 'package:immich_mobile/data/db/main/database.dart';
import 'package:logging/logging.dart';

/// Indexes added on top of the upstream schema. They are created at runtime
/// rather than through schema migrations, so no schema version is claimed that
/// upstream may later use for its own migration.
const kForkIndexes = <String>[
  // Makes the main timeline bucket aggregate a covering index scan.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_timeline_bucket ON remote_asset_entity (owner_id, visibility, deleted_at, local_date_time, created_at, stack_id, id)',
  // Serves timeline paging in sort order, covering the stack check, so skipped
  // and sought rows are read from the index alone.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_timeline_order ON remote_asset_entity (owner_id, visibility, deleted_at, created_at DESC, id DESC, stack_id)',
  // Covers the album list's per-membership trash check.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_id_deleted ON remote_asset_entity (id, deleted_at)',
  // Covers the backed-up check that hides local assets with a remote copy.
  'CREATE INDEX IF NOT EXISTS idx_remote_asset_checksum_owner ON remote_asset_entity (checksum, owner_id)',
];

/// Creates any missing index from [kForkIndexes].
///
/// Call from the main isolate only, after the first frame. Building an index on
/// a populated table holds the write lock for the whole build, and isolates that
/// open the database meanwhile wait on it up to the busy timeout.
Future<void> ensureForkIndexes(Drift db) async {
  final log = Logger('ForkIndexes');
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
