import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/watch_history_store.dart';

final watchHistoryStoreProvider =
    Provider<WatchHistoryStore>((ref) => WatchHistoryStore());
