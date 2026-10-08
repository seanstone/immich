import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/fork_indexes.dart';

void main() {
  late Drift db;

  setUp(() => db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true)));
  tearDown(() => db.close());

  Future<Set<String>> indexNames() async => {
    for (final row in await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index'").get())
      row.read<String>('name'),
  };

  test('creates every fork index and is a no-op when run again', () async {
    final expected = {
      for (final statement in kForkIndexes) RegExp(r'IF NOT EXISTS (\w+)').firstMatch(statement)!.group(1)!,
    };
    expect(expected, hasLength(kForkIndexes.length));

    await ensureForkIndexes(db);
    expect(await indexNames(), containsAll(expected));

    await ensureForkIndexes(db);
    expect(await indexNames(), containsAll(expected));
  });

  test('drops the indexes earlier fork builds created', () async {
    for (final name in kObsoleteForkIndexes) {
      await db.customStatement('CREATE INDEX $name ON remote_asset_entity (created_at)');
    }
    await ensureForkIndexes(db);
    expect(await indexNames(), isNot(containsAll(kObsoleteForkIndexes)));
    for (final name in kObsoleteForkIndexes) {
      expect(await indexNames(), isNot(contains(name)));
    }
  });

  Future<String> plan(String query, List<Variable> variables) async {
    final rows = await db.customSelect('EXPLAIN QUERY PLAN $query', variables: variables).get();
    return rows.map((row) => row.read<String>('detail')).join('\n');
  }

  test('the keyset page query seeks the timeline group index', () async {
    await ensureForkIndexes(db);
    final details = await plan(
      'SELECT rae.id FROM remote_asset_entity rae '
      'WHERE rae.deleted_at IS NULL AND rae.visibility = 0 AND rae.owner_id IN (?) AND rae.group_date IS NOT NULL '
      'AND (rae.group_date, rae.created_at, rae.id) < (?, ?, ?) '
      'ORDER BY rae.group_date DESC, rae.created_at DESC, rae.id DESC LIMIT 10',
      [
        Variable.withString('u'),
        Variable.withString('2020-01-01'),
        Variable.withString('2020-01-01T00:00:00.000Z'),
        Variable.withString('x'),
      ],
    );
    expect(details, contains('idx_remote_asset_timeline_group'));
    expect(details, isNot(contains('TEMP B-TREE')));
  });

  test('the timeline bucket query is a covering scan of the timeline group index', () async {
    await ensureForkIndexes(db);
    final details = await plan(
      'SELECT rae.group_date FROM remote_asset_entity rae '
      'LEFT JOIN stack_entity se ON rae.stack_id = se.id '
      'WHERE rae.deleted_at IS NULL AND rae.visibility = 0 AND rae.owner_id IN (?) AND rae.group_date IS NOT NULL '
      'AND (rae.stack_id IS NULL OR rae.id = se.primary_asset_id)',
      [Variable.withString('u')],
    );
    expect(details, contains('COVERING INDEX idx_remote_asset_timeline_group'));
  });
}
