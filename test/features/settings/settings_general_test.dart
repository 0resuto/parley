import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/llm/model_catalog.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

class FakeSettingsRepository implements SettingsRepository {
  FakeSettingsRepository({
    this.baseUrlValue = 'https://api.openai.com/v1',
    this.modelValue = '',
    this.percent = 10,
    this.autoPlayValue = false,
    this.speed = 1.0,
    this.contextTranslationValue = true,
  });

  String baseUrlValue;
  String modelValue;
  int percent;
  bool autoPlayValue;
  double speed;
  bool contextTranslationValue;

  @override
  String get baseUrl => baseUrlValue;

  @override
  String get model => modelValue;

  @override
  int get newWordPercent => percent;

  @override
  bool get autoPlay => autoPlayValue;

  @override
  double get speechSpeed => speed;

  @override
  bool get contextTranslation => contextTranslationValue;

  @override
  Future<void> setBaseUrl(String value) async {
    baseUrlValue = value.trim();
  }

  @override
  Future<void> setModel(String value) async {
    modelValue = value.trim();
  }

  @override
  Future<void> setNewWordPercent(int value) async {
    percent = value;
  }

  @override
  Future<void> setAutoPlay(bool value) async {
    autoPlayValue = value;
  }

  @override
  Future<void> setSpeechSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> setContextTranslation(bool value) async {
    contextTranslationValue = value;
  }

  @override
  Future<bool> isLlmConfigured() async {
    return baseUrlValue.trim().isNotEmpty && modelValue.trim().isNotEmpty;
  }
}

class FakeSecureKeyStore implements SecureKeyStore {
  FakeSecureKeyStore([this.apiKey]);

  String? apiKey;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<void> writeApiKey(String apiKey) async {
    this.apiKey = apiKey;
  }

  @override
  Future<void> deleteApiKey() async {
    apiKey = null;
  }
}

class FakeLlmClient implements LlmClient {
  FakeLlmClient({this.completeHandler});

  Future<String> Function(List<LlmMessage> messages)? completeHandler;
  final List<List<LlmMessage>> completeCalls = [];

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    completeCalls.add(messages);
    if (completeHandler != null) {
      return completeHandler!(messages);
    }
    return 'ok';
  }

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  late FakeSettingsRepository settings;
  late FakeSecureKeyStore keys;
  late FakeLlmClient llm;

  setUp(() {
    settings = FakeSettingsRepository();
    keys = FakeSecureKeyStore();
    llm = FakeLlmClient();
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    ModelCatalog? catalog,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          secureKeyStoreProvider.overrideWithValue(keys),
          llmClientProvider.overrideWithValue(llm),
          modelCatalogProvider.overrideWithValue(catalog ?? ModelCatalog()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  ModelCatalog scriptedCatalog(List<Object> script) {
    final Dio dio = Dio()..httpClientAdapter = _ScriptedAdapter(script);
    return ModelCatalog(dio: dio, delay: (_) async {});
  }

  group('SettingsScreen general (4.5)', () {
    testWidgets('shows all sections', (WidgetTester tester) async {
      await pumpSettings(tester);

      expect(find.text('AI provider'), findsOneWidget);
      expect(find.text('Tutor'), findsOneWidget);
      expect(find.text('Translation'), findsOneWidget);
      expect(
        find.text('Only OpenAI-format models are supported.'),
        findsOneWidget,
      );
      // Lower sections are off-screen in a 800x600 viewport; scroll to them.
      await tester.ensureVisible(find.text('Data'));
      await tester.pumpAndSettle();
      expect(find.text('Voice'), findsOneWidget);
      expect(find.text('Data'), findsOneWidget);
      await tester.ensureVisible(find.text('Version 0.1.0'));
      await tester.pumpAndSettle();
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Version 0.1.0'), findsOneWidget);
      expect(find.text('Dictionary data'), findsOneWidget);
      expect(find.text('Wiktionary via kaikki.org (CC BY-SA)'), findsOneWidget);
    });

    testWidgets('base url, model and key persist', (WidgetTester tester) async {
      await pumpSettings(tester);

      await tester.enterText(
        find.byKey(const Key('baseUrlField')),
        'https://example.com/v1',
      );
      await tester.pumpAndSettle();
      expect(settings.baseUrlValue, 'https://example.com/v1');

      await tester.enterText(find.byKey(const Key('modelField')), 'my-model');
      await tester.pumpAndSettle();
      expect(settings.modelValue, 'my-model');

      await tester.enterText(
        find.byKey(const Key('apiKeyField')),
        'secret-key',
      );
      await tester.pumpAndSettle();
      expect(keys.apiKey, 'secret-key');
    });

    testWidgets('tutor density and voice settings persist', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(const Key('densitySlider')));
      await tester.pumpAndSettle();
      final Slider density = tester.widget(
        find.byKey(const Key('densitySlider')),
      );
      density.onChanged!(20);
      await tester.pumpAndSettle();
      expect(settings.percent, 20);
      expect(find.text('New-word density: 20%'), findsOneWidget);

      await tester.ensureVisible(find.text('Auto-play replies'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auto-play replies'));
      await tester.pumpAndSettle();
      expect(settings.autoPlayValue, isTrue);

      await tester.ensureVisible(find.byKey(const Key('speechSpeedSlider')));
      await tester.pumpAndSettle();
      final Slider speed = tester.widget(
        find.byKey(const Key('speechSpeedSlider')),
      );
      speed.onChanged!(1.2);
      await tester.pumpAndSettle();
      expect(settings.speed, 1.2);
    });

    testWidgets('in-sentence translation toggle persists', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.ensureVisible(
        find.byKey(const Key('contextTranslationSwitch')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Ask the AI how the word is meant in the sentence '
          '(uses extra tokens).',
        ),
        findsOneWidget,
      );
      expect(settings.contextTranslationValue, isTrue);

      await tester.tap(find.byKey(const Key('contextTranslationSwitch')));
      await tester.pumpAndSettle();

      expect(settings.contextTranslationValue, isFalse);
    });

    testWidgets('test connection success shows a message', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(llm.completeCalls, hasLength(1));
      expect(find.text('Connection works.'), findsOneWidget);
    });

    testWidgets('test connection failure shows the failure message', (
      WidgetTester tester,
    ) async {
      llm.completeHandler = (_) async {
        throw const AuthFailure();
      };
      await pumpSettings(tester);

      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(find.text(const AuthFailure().userMessage), findsOneWidget);
      expect(find.text('Connection works.'), findsNothing);
    });

    testWidgets('load models shows a picker and fills the model', (
      WidgetTester tester,
    ) async {
      keys.apiKey = 'secret-123';
      final ModelCatalog catalog = scriptedCatalog([
        _Canned(
          200,
          jsonEncode({
            'data': [
              {'id': 'model-a'},
              {'id': 'model-b'},
            ],
          }),
        ),
      ]);
      await pumpSettings(tester, catalog: catalog);

      await tester.tap(find.byKey(const Key('loadModelsButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('modelPickerDialog')), findsOneWidget);
      expect(find.text('model-a'), findsOneWidget);
      expect(find.text('model-b'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('modelOption_model-b')));
      await tester.pumpAndSettle();

      expect(settings.modelValue, 'model-b');
      expect(find.byKey(const Key('modelPickerDialog')), findsNothing);
    });

    testWidgets('load models failure shows the failure message', (
      WidgetTester tester,
    ) async {
      keys.apiKey = 'secret-123';
      final ModelCatalog catalog = scriptedCatalog([
        _Canned(401, jsonEncode({'error': 'boom'})),
      ]);
      await pumpSettings(tester, catalog: catalog);

      await tester.tap(find.byKey(const Key('loadModelsButton')));
      await tester.pumpAndSettle();

      expect(find.text(const AuthFailure().userMessage), findsOneWidget);
      expect(find.byKey(const Key('modelPickerDialog')), findsNothing);
    });

    testWidgets('load models with no key asks for url and key first', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const Key('loadModelsButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('Enter the base URL and API key first.'),
        findsOneWidget,
      );
    });

    testWidgets('load models with an empty list keeps the text field', (
      WidgetTester tester,
    ) async {
      keys.apiKey = 'secret-123';
      final ModelCatalog catalog = scriptedCatalog([
        _Canned(200, jsonEncode({'data': []})),
      ]);
      await pumpSettings(tester, catalog: catalog);

      await tester.tap(find.byKey(const Key('loadModelsButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('No models found. Type the model name.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('modelField')), findsOneWidget);
    });

    testWidgets('api key field is obscured', (WidgetTester tester) async {
      keys.apiKey = 'secret-123';
      await pumpSettings(tester);

      final TextField field = tester.widget(
        find.byKey(const Key('apiKeyField')),
      );
      expect(field.obscureText, isTrue);
      // The raw key lives only in the obscured editable field, never as
      // plain Text (obscured input still carries the value for editing).
      expect(find.widgetWithText(Text, 'secret-123'), findsNothing);
    });
  });
}

class _Canned {
  const _Canned(this.status, this.body);

  final int status;
  final String body;
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<Object> script;
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object next = _index < script.length ? script[_index++] : script.last;
    if (next is _Canned) {
      return ResponseBody.fromString(
        next.body,
        next.status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    throw StateError('Bad script entry: $next');
  }

  @override
  void close({bool force = false}) {}
}
