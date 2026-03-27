import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rinf/rinf.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

/// Manages the transcription history list by listening to both
/// [HistoryLoaded] (full list replacement) and [HistoryEntryAdded]
/// (incremental additions) signals from Rust.
class HistoryNotifier extends Notifier<List<HistoryEntryData>> {
  StreamSubscription<RustSignalPack<HistoryLoaded>>? _historyLoadedSub;
  StreamSubscription<RustSignalPack<HistoryEntryAdded>>? _historyEntryAddedSub;

  @override
  List<HistoryEntryData> build() {
    _historyLoadedSub = HistoryLoaded.rustSignalStream.listen((signalPack) {
      state = List.unmodifiable(signalPack.message.entries);
    });

    _historyEntryAddedSub =
        HistoryEntryAdded.rustSignalStream.listen((signalPack) {
      state = List.unmodifiable([signalPack.message.entry, ...state]);
    });

    ref.onDispose(() {
      _historyLoadedSub?.cancel();
      _historyEntryAddedSub?.cancel();
    });

    return const [];
  }

  /// Remove a history entry locally by id.
  /// The caller should also send [DeleteHistoryEntry] to Rust.
  void removeEntry(String id) {
    state = List.unmodifiable(
      state.where((entry) => entry.id != id).toList(),
    );
  }

  /// Clear all history locally.
  /// The caller should also send [ClearHistory] to Rust.
  void clearAll() {
    state = const [];
  }
}

final historyProvider =
    NotifierProvider<HistoryNotifier, List<HistoryEntryData>>(
  HistoryNotifier.new,
);
