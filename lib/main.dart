import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parley/app.dart';
import 'package:parley/core/clock.dart';
import 'package:parley/features/chat/word_popup.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/dictionary/dictionary_initializer.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
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
  final File dictionaryFile = await ensureDictionaryFile(
    loader: RootBundleDictionaryLoader(),
  );
  final DictionaryService dictionary = SqliteDictionaryService(
    NativeDatabase(dictionaryFile),
  );
  runApp(
    ProviderScope(
      overrides: [
        secureKeyStoreProvider.overrideWithValue(keys),
        settingsRepositoryProvider.overrideWithValue(settings),
        documentStoreProvider.overrideWithValue(documents),
        dictionaryServiceProvider.overrideWithValue(dictionary),
      ],
      child: const ParleyApp(),
    ),
  );
}
