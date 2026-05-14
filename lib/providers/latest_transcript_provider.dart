import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/bindings/signals/signals.dart';

final latestTranscriptProvider = StreamProvider<String>((ref) {
  return TranscriptReady.rustSignalStream.map(
    (signalPack) => signalPack.message.transcript,
  );
});
