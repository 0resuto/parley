import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

class FakeSettings implements SettingsRepository {
  FakeSettings({
    this.baseUrlValue = 'https://example.com/v1',
    this.modelValue = 'test-model',
  });

  String baseUrlValue;
  String modelValue;
  int percent = 10;
  bool autoPlayValue = false;
  double speed = 1.0;

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
  Future<void> setBaseUrl(String value) async {
    baseUrlValue = value;
  }

  @override
  Future<void> setModel(String value) async {
    modelValue = value;
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
  Future<bool> isLlmConfigured() async {
    return baseUrlValue.trim().isNotEmpty && modelValue.trim().isNotEmpty;
  }
}

class FakeSecureKeyStore implements SecureKeyStore {
  FakeSecureKeyStore([this.apiKey = 'test-key-123']);

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

class Canned {
  const Canned(this.status, this.body);

  final int status;
  final String body;
}

class NetworkError {
  const NetworkError([this.type = DioExceptionType.connectionError]);

  final DioExceptionType type;
}

Canned ok(String content) {
  return Canned(
    200,
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
        },
      ],
    }),
  );
}

Canned status(int code) {
  return Canned(code, jsonEncode({'error': 'boom'}));
}

class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter(this.script);

  final List<Object> script;
  final List<RequestOptions> requests = [];
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final Object next = _index < script.length ? script[_index++] : script.last;
    if (next is Canned) {
      return ResponseBody.fromString(
        next.body,
        next.status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (next is NetworkError) {
      throw DioException(requestOptions: options, type: next.type);
    }
    throw StateError('Bad script entry: $next');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeSettings settings;
  late FakeSecureKeyStore keys;
  late List<Duration> delays;
  late ScriptedAdapter adapter;
  late DioLlmClient client;

  void setUpClient(List<Object> script) {
    settings = FakeSettings();
    keys = FakeSecureKeyStore();
    delays = [];
    adapter = ScriptedAdapter(script);
    final Dio dio = Dio()..httpClientAdapter = adapter;
    client = DioLlmClient(
      settings: settings,
      keys: keys,
      dio: dio,
      delay: (Duration d) async {
        delays.add(d);
      },
    );
  }

  List<LlmMessage> messages() {
    return const [
      LlmMessage(role: LlmRole.system, content: 'sys'),
      LlmMessage(role: LlmRole.user, content: 'hi'),
    ];
  }

  test('success returns content and sends the right request', () async {
    setUpClient([ok('hello')]);

    final String result = await client.complete(messages());

    expect(result, 'hello');
    expect(adapter.requests, hasLength(1));
    final RequestOptions request = adapter.requests.single;
    expect(request.uri.toString(), 'https://example.com/v1/chat/completions');
    expect(request.headers['Authorization'], 'Bearer test-key-123');
    expect(request.method, 'POST');
    final Map<String, dynamic> body = request.data as Map<String, dynamic>;
    expect(body['model'], 'test-model');
    expect(body['stream'], isFalse);
    expect(body['temperature'], 0.2);
    final List<dynamic> sent = body['messages'] as List<dynamic>;
    expect(sent, hasLength(2));
    expect(sent[0]['role'], 'system');
    expect(sent[0]['content'], 'sys');
    expect(sent[1]['role'], 'user');
    expect(delays, isEmpty);
  });

  test('trailing slash in base url is handled', () async {
    setUpClient([ok('hi')]);
    settings.baseUrlValue = 'https://example.com/v1///';

    final String result = await client.complete(messages());

    expect(result, 'hi');
    expect(
      adapter.requests.single.uri.toString(),
      'https://example.com/v1/chat/completions',
    );
  });

  test('missing base url throws NotConfigured without a request', () async {
    setUpClient([ok('hi')]);
    settings.baseUrlValue = '   ';

    await expectLater(
      client.complete(messages()),
      throwsA(isA<NotConfiguredFailure>()),
    );
    expect(adapter.requests, isEmpty);
    expect(delays, isEmpty);
  });

  test('missing model throws NotConfigured without a request', () async {
    setUpClient([ok('hi')]);
    settings.modelValue = '';

    await expectLater(
      client.complete(messages()),
      throwsA(isA<NotConfiguredFailure>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('missing api key throws NotConfigured without a request', () async {
    setUpClient([ok('hi')]);
    keys.apiKey = null;

    await expectLater(
      client.complete(messages()),
      throwsA(isA<NotConfiguredFailure>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('blank api key throws NotConfigured without a request', () async {
    setUpClient([ok('hi')]);
    keys.apiKey = '   ';

    await expectLater(
      client.complete(messages()),
      throwsA(isA<NotConfiguredFailure>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('401 throws AuthFailure without retry', () async {
    setUpClient([status(401)]);

    await expectLater(client.complete(messages()), throwsA(isA<AuthFailure>()));
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('403 throws AuthFailure without retry', () async {
    setUpClient([status(403)]);

    await expectLater(client.complete(messages()), throwsA(isA<AuthFailure>()));
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('429 retried then RateLimitFailure', () async {
    setUpClient([status(429), status(429), status(429)]);

    await expectLater(
      client.complete(messages()),
      throwsA(isA<RateLimitFailure>()),
    );
    expect(adapter.requests, hasLength(3));
    expect(delays, [llmRetryDelayFirst, llmRetryDelaySecond]);
    expect(delays, [const Duration(seconds: 1), const Duration(seconds: 3)]);
  });

  test('429 then success returns content', () async {
    setUpClient([status(429), ok('recovered')]);

    final String result = await client.complete(messages());

    expect(result, 'recovered');
    expect(adapter.requests, hasLength(2));
    expect(delays, [llmRetryDelayFirst]);
  });

  test('5xx retried then ServerFailure', () async {
    setUpClient([status(500), status(500), status(500)]);

    await expectLater(
      client.complete(messages()),
      throwsA(isA<ServerFailure>()),
    );
    expect(adapter.requests, hasLength(3));
    expect(delays, [llmRetryDelayFirst, llmRetryDelaySecond]);
  });

  test('network error retried then ServerFailure', () async {
    setUpClient([
      const NetworkError(),
      const NetworkError(),
      const NetworkError(),
    ]);

    await expectLater(
      client.complete(messages()),
      throwsA(isA<ServerFailure>()),
    );
    expect(adapter.requests, hasLength(3));
    expect(delays, [llmRetryDelayFirst, llmRetryDelaySecond]);
  });

  test('network error then success returns content', () async {
    setUpClient([const NetworkError(), ok('back')]);

    final String result = await client.complete(messages());

    expect(result, 'back');
    expect(adapter.requests, hasLength(2));
  });

  test('400 throws InvalidResponse without retry', () async {
    setUpClient([status(400)]);

    await expectLater(
      client.complete(messages()),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('unparseable body throws InvalidResponse without retry', () async {
    setUpClient([
      Canned(200, jsonEncode({'choices': []})),
    ]);

    await expectLater(
      client.complete(messages()),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('missing content throws InvalidResponse', () async {
    setUpClient([
      Canned(
        200,
        jsonEncode({
          'choices': [
            {
              'message': {'content': null},
            },
          ],
        }),
      ),
    ]);

    await expectLater(
      client.complete(messages()),
      throwsA(isA<InvalidResponseFailure>()),
    );
  });

  test('api key never appears in any exception message', () async {
    const String secret = 'super-secret-key-xyz-123';
    final List<List<Object>> scripts = [
      [status(401)],
      [status(429), status(429), status(429)],
      [status(500), status(500), status(500)],
      [const NetworkError(), const NetworkError(), const NetworkError()],
      [
        Canned(200, jsonEncode({'nope': true})),
      ],
      [status(400)],
    ];
    for (final List<Object> script in scripts) {
      setUpClient(script);
      keys.apiKey = secret;
      try {
        await client.complete(messages());
        fail('expected an AppFailure for $script');
      } on AppFailure catch (e) {
        expect(e.toString(), isNot(contains(secret)));
        expect(e.userMessage, isNot(contains(secret)));
      }
    }
    // The header itself carries the key, but failures must not.
    setUpClient([ok('x')]);
    keys.apiKey = secret;
    await client.complete(messages());
    expect(adapter.requests.single.headers['Authorization'], contains(secret));
  });
}
