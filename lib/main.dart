import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parley/app.dart';
import 'package:parley/core/clock.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/documents/document_initializer.dart';
import 'package:parley/services/documents/file_document_store.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final SecureKeyStore keys = FlutterSecureKeyStore();
  final SettingsRepository settings = SharedPreferencesSettingsRepository(
    prefs,
    keys,
  );
  const Clock clock = SystemClock();
  final FileDocumentStore documents = await createFileDocumentStore(clock);
  await ensureDefaultDocuments(
    store: documents,
    templates: AssetTemplateLoader(),
  );
  runApp(
    ProviderScope(
      overrides: [
        secureKeyStoreProvider.overrideWithValue(keys),
        settingsRepositoryProvider.overrideWithValue(settings),
        documentStoreProvider.overrideWithValue(documents),
      ],
      child: const ParleyApp(),
    ),
  );
}
