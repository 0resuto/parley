import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/data/db/database.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/export/csv_importer.dart';
import 'package:parley/services/export/export_service.dart';
import 'package:parley/services/export/file_picker_service.dart';
import 'package:parley/services/export/share_service.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/llm/model_catalog.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

/// Tutor documents. In-memory until task 5.1 provides the file version.
final documentStoreProvider = Provider<DocumentStore>((ref) {
  return MemoryDocumentStore();
});

/// API key storage. In-memory by default so widget tests work without
/// platform plugins; `main()` overrides with [FlutterSecureKeyStore].
final secureKeyStoreProvider = Provider<SecureKeyStore>((ref) {
  return MemorySecureKeyStore();
});

/// App settings. In-memory by default so widget tests work without
/// `SharedPreferences`; `main()` overrides with
/// [SharedPreferencesSettingsRepository].
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return MemorySettingsRepository(ref.watch(secureKeyStoreProvider));
});

/// LLM client built from the current settings and key store.
final llmClientProvider = Provider<LlmClient>((ref) {
  return DioLlmClient(
    settings: ref.watch(settingsRepositoryProvider),
    keys: ref.watch(secureKeyStoreProvider),
  );
});

/// Model catalog for the optional model picker.
///
/// Tests override this with a [ModelCatalog] backed by a scripted adapter.
final modelCatalogProvider = Provider<ModelCatalog>((ref) {
  return ModelCatalog();
});

/// JSON export/import (task 2.6).
final exportServiceProvider = Provider<ExportService>((ref) {
  return ExportService(
    database: ref.watch(appDatabaseProvider),
    units: ref.watch(unitRepositoryProvider),
    documents: ref.watch(documentStoreProvider),
    clock: ref.watch(clockProvider),
  );
});

/// CSV import (task 2.7).
final csvImporterProvider = Provider<CsvImporter>((ref) {
  return CsvImporter(units: ref.watch(unitRepositoryProvider));
});

/// Sharing behind an interface so widget tests can use a fake.
final shareServiceProvider = Provider<ShareService>((ref) {
  return TempFileShareService();
});

/// File picking behind an interface so widget tests can use a fake.
final filePickerServiceProvider = Provider<FilePickerService>((ref) {
  return SystemFilePickerService();
});
