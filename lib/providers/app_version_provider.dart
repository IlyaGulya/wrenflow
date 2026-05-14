import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_version.dart';

final appVersionProvider = FutureProvider<AppVersionInfo>((ref) async {
  if (AppVersion.current.isAvailable) {
    return AppVersion.current;
  }
  return AppVersion.load();
});

final appVersionLabelProvider = Provider<String>((ref) {
  final versionAsync = ref.watch(appVersionProvider);
  return versionAsync.when(
    data: (version) => version.isAvailable
        ? 'v${version.displayVersion}'
        : 'Version unavailable',
    error: (error, stackTrace) => 'Version unavailable',
    loading: () => 'Loading...',
  );
});
