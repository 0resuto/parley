import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/dictionary/dictionary_importer.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/meaning_resolver.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';

/// Injectable clock for dictionary UI (relative due dates).
final clockProvider = Provider<Clock>((ref) => const SystemClock());

/// Builds the dictionary repository from the app database and clock.
///
/// Tests override this (or [appDatabaseProvider] and [clockProvider])
/// with an in-memory database and a fake clock.
final unitRepositoryProvider = Provider<UnitRepository>((ref) {
  final AppDatabase db = ref.watch(appDatabaseProvider);
  final Clock clock = ref.watch(clockProvider);
  return UnitRepository(db, clock: clock);
});

/// Storage for imported user dictionaries (SPEC 5.12).
final userDictionaryRepositoryProvider = Provider<UserDictionaryRepository>((
  ref,
) {
  return UserDictionaryRepository(
    ref.watch(appDatabaseProvider),
    clock: ref.watch(clockProvider),
  );
});

/// The user-dictionary lookup seam used by the resolver (SPEC 5.12).
///
/// Tests override this with a fake; the app uses the repository above.
final userDictionaryLookupProvider = Provider<UserDictionaryLookup>((ref) {
  return ref.watch(userDictionaryRepositoryProvider);
});

/// All imported dictionaries, highest priority first (SPEC 5.12).
final userDictionariesProvider = StreamProvider<List<UserDictionary>>((ref) {
  return ref.watch(userDictionaryRepositoryProvider).watchAll();
});

/// Imports dictionary files into the app database (SPEC 5.12).
final dictionaryImporterProvider = Provider<DictionaryImporter>((ref) {
  return DictionaryImporter(
    dictionaries: ref.watch(userDictionaryRepositoryProvider),
  );
});

/// Bundled dictionary lookups (SPEC 5.11).
///
/// Defaults to an empty service so tests and startup before `main()`'s
/// override never crash; every word then falls back to the LLM.
final dictionaryServiceProvider = Provider<DictionaryService>((ref) {
  return EmptyDictionaryService();
});

/// Resolves meanings at display time from the current sources
/// (PLAN 19.1, SPEC 5.12).
final meaningResolverProvider = Provider<MeaningResolver>((ref) {
  return MeaningResolver(
    dictionary: ref.watch(dictionaryServiceProvider),
    llm: ref.watch(llmClientProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    userDictionaries: ref.watch(userDictionaryLookupProvider),
    settings: ref.watch(settingsRepositoryProvider),
  );
});
