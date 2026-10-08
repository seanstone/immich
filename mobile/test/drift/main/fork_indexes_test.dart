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

  test('the keyset page query seeks the timeline order index', () async {
    await ensureForkIndexes(db);
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT rae.id FROM remote_asset_entity rae '
          'WHERE rae.deleted_at IS NULL AND rae.visibility = 0 AND rae.owner_id IN (?) '
          'AND (rae.created_at, rae.id) < (?, ?) ORDER BY rae.created_at DESC, rae.id DESC LIMIT 10',
          variables: [
            Variable.withString('u'),
            Variable.withString('2020-01-01T00:00:00.000Z'),
            Variable.withString('x'),
          ],
        )
        .get();
    final details = plan.map((row) => row.read<String>('detail')).join('\n');
    expect(details, contains('idx_remote_asset_timeline_order'));
    expect(details, isNot(contains('TEMP B-TREE')));
  });
}
