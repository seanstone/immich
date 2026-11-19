import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:logging/logging.dart';

/// Loads the album list and its sort keys in the background, so the first
/// album picker opened after launch can show the albums immediately. Sorting by
/// asset date reads every album asset, which takes seconds on a large library.
Future<void> warmAlbumList(WidgetRef ref) async {
  try {
    final notifier = ref.read(remoteAlbumProvider.notifier);
    await notifier.refresh();
    final config = ref.read(appConfigProvider).album;
    await notifier.sortAlbums(ref.read(remoteAlbumProvider).albums, config.sortMode, isReverse: config.isReverse);
  } catch (error, stack) {
    Logger('AlbumListWarmup').warning('Failed to preload the album list', error, stack);
  }
}
