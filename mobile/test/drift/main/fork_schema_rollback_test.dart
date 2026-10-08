import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart';

import 'generated/schema.dart';

// The indexes that fork builds before v3.3.0 created through schema versions 32-34.
const _legacyForkIndexes = [
  'CREATE INDEX idx_remote_asset_timeline_bucket ON remote_asset_entity (owner_id, visibility, deleted_at, local_date_time, created_at, stack_id, id)',
  'CREATE INDEX idx_remote_asset_timeline_order ON remote_asset_entity (owner_id, visibility, deleted_at, created_at DESC, id DESC, stack_id)',
  'CREATE INDEX idx_remote_asset_id_deleted ON remote_asset_entity (id, deleted_at)',
  'CREATE INDEX idx_remote_asset_checksum_owner ON remote_asset_entity (checksum, owner_id)',
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;
  late Directory tempDir;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));
  setUp(() => tempDir = Directory.systemTemp.createTempSync('fork_schema_rollback'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // Copies the schema at [version] to a file so sqlite_async and drift can open it.
  Future<String> databaseAt(int version, {void Function(sqlite3.Database db)? alter}) async {
    final schema = await verifier.schemaAt(version);
    alter?.call(schema.rawDatabase);
    final path = '${tempDir.path}/v$version.sqlite';
    schema.rawDatabase.execute("VACUUM INTO '$path'");
    return path;
  }

  int userVersion(String path) {
    final db = sqlite3.sqlite3.open(path);
    try {
      return db.select('PRAGMA user_version').single['user_version'] as int;
    } finally {
      db.close();
    }
  }

  Future<void> rollBack(String path) async {
    final db = SqliteDatabase(path: path);
    try {
      await rollBackForkSchemaVersion(db);
    } finally {
      await db.close();
    }
  }

  // Column names per table and index names, from the database's own catalogue.
  Map<String, Set<String>> shape(String path, {Set<String> ignoreIndexes = const {}}) {
    final db = sqlite3.sqlite3.open(path);
    try {
      final result = <String, Set<String>>{};
      final objects = db.select("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
      for (final row in objects) {
        final name = row['name'] as String;
        if (row['type'] == 'table') {
          result['table:$name'] = {
            for (final column in db.select("SELECT name FROM pragma_table_info('$name')")) column['name'] as String,
          };
        } else if (row['type'] == 'index' && !ignoreIndexes.contains(name)) {
          result['index:$name'] = {};
        }
      }
      return result;
    } finally {
      db.close();
    }
  }

  test('a database migrated by an old fork build is rolled back and then gets the upstream migrations', () async {
    final path = await databaseAt(
      31,
      alter: (db) {
        _legacyForkIndexes.forEach(db.execute);
        db.execute('PRAGMA user_version = 34');
      },
    );

    await rollBack(path);
    expect(userVersion(path), 31);

    final drift = Drift(NativeDatabase(File(path)));
    await drift.customSelect('SELECT 1').get(); // opening runs the pending migrations
    await drift.close();

    expect(userVersion(path), 34);
    final upstream = shape(await databaseAt(34));
    final migrated = shape(
      path,
      ignoreIndexes: {
        'idx_remote_asset_timeline_bucket',
        'idx_remote_asset_timeline_order',
        'idx_remote_asset_id_deleted',
        'idx_remote_asset_checksum_owner',
      },
    );
    expect(migrated['table:local_asset_entity'], contains('previous_checksum'));
    expect(migrated, upstream);
  });

  test('a database already on upstream v34 is left alone', () async {
    final path = await databaseAt(34);
    await rollBack(path);
    expect(userVersion(path), 34);
  });

  test('a database on upstream v31 is left alone', () async {
    final path = await databaseAt(31);
    await rollBack(path);
    expect(userVersion(path), 31);
  });
}
