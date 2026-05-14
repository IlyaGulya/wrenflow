import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_lifecycle_state.dart';
import 'settings_provider.dart';

class WizardDraftState {
  const WizardDraftState({
    this.selectedHotkey = '61',
    this.vocabularyDraft = '',
    this.lastHydratedHotkey,
    this.lastHydratedVocabulary,
    this.autoRequested = const <OnboardingStep>{},
    this.hasSyncedCompleteStep = false,
  });

  final String selectedHotkey;
  final String vocabularyDraft;
  final String? lastHydratedHotkey;
  final String? lastHydratedVocabulary;
  final Set<OnboardingStep> autoRequested;
  final bool hasSyncedCompleteStep;

  WizardDraftState copyWith({
    String? selectedHotkey,
    String? vocabularyDraft,
    String? lastHydratedHotkey,
    String? lastHydratedVocabulary,
    Set<OnboardingStep>? autoRequested,
    bool? hasSyncedCompleteStep,
  }) {
    return WizardDraftState(
      selectedHotkey: selectedHotkey ?? this.selectedHotkey,
      vocabularyDraft: vocabularyDraft ?? this.vocabularyDraft,
      lastHydratedHotkey: lastHydratedHotkey ?? this.lastHydratedHotkey,
      lastHydratedVocabulary:
          lastHydratedVocabulary ?? this.lastHydratedVocabulary,
      autoRequested: autoRequested ?? this.autoRequested,
      hasSyncedCompleteStep:
          hasSyncedCompleteStep ?? this.hasSyncedCompleteStep,
    );
  }
}

class WizardDraftNotifier extends Notifier<WizardDraftState> {
  @override
  WizardDraftState build() => const WizardDraftState();

  void hydrateFromSettings(AppSettings settings) {
    final hotkeyWasEdited =
        state.lastHydratedHotkey != null &&
        state.selectedHotkey != state.lastHydratedHotkey;
    final vocabularyWasEdited =
        state.lastHydratedVocabulary != null &&
        state.vocabularyDraft != state.lastHydratedVocabulary;

    state = state.copyWith(
      selectedHotkey: hotkeyWasEdited
          ? state.selectedHotkey
          : settings.selectedHotkey,
      vocabularyDraft: vocabularyWasEdited
          ? state.vocabularyDraft
          : settings.customVocabulary,
      lastHydratedHotkey: settings.selectedHotkey,
      lastHydratedVocabulary: settings.customVocabulary,
    );
  }

  void setSelectedHotkey(String value) {
    state = state.copyWith(
      selectedHotkey: value,
      lastHydratedHotkey: value,
    );
  }

  void setVocabularyDraft(String value) {
    state = state.copyWith(
      vocabularyDraft: value,
      lastHydratedVocabulary: value,
    );
  }

  bool consumeAutoRequest(OnboardingStep step) {
    if (state.autoRequested.contains(step)) return false;
    state = state.copyWith(autoRequested: {...state.autoRequested, step});
    return true;
  }

  bool shouldSyncCompleteStep(OnboardingStep step) {
    final shouldSync =
        step == OnboardingStep.complete && !state.hasSyncedCompleteStep;
    final shouldReset =
        step != OnboardingStep.complete && state.hasSyncedCompleteStep;

    if (shouldSync) {
      state = state.copyWith(hasSyncedCompleteStep: true);
      return true;
    }
    if (shouldReset) {
      state = state.copyWith(hasSyncedCompleteStep: false);
    }
    return false;
  }
}

final wizardDraftProvider =
    NotifierProvider<WizardDraftNotifier, WizardDraftState>(
      WizardDraftNotifier.new,
      isAutoDispose: true,
    );
