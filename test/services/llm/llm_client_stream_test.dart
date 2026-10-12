import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

class StreamFakeSettings implements SettingsRepository {
  @override
  String get meaningLanguage => 'ru';

  @override
  Future<void> setMeaningLanguage(String value) async {}

  StreamFakeSettings({
    this.baseUrlValue = 'https://example.com/v1',
    this.modelValue = 'test-model',
  });

  String baseUrlValue;
  String modelValue;

  @override
  String get baseUrl => baseUrlValue;

  @override
  String get model => modelValue;

  @override
  int get newWordPercent => 10;

  @override
  bool get autoPlay => false;

  @override
  double get speechSpeed => 1.0;

  @override
  Future<void> setBaseUrl(String value) async => baseUrlValue = value;

  @override
  Future<void> setModel(String value) async => modelValue = value;

  @override
  Future<void> setNewWordPercent(int value) async {}

  @override
  Future<void> setAutoPlay(bool value) async {}

  @override
  Future<void> setSpeechSpeed(double value) async {}

  @override
  bool get contextTranslation => true;

  @override
  Future<void> setContextTranslation(bool value) async {}

  @override
  Future<bool> isLlmConfigured() async => true;
}

class StreamFakeKeys implements SecureKeyStore {
  StreamFakeKeys([this.apiKey = 'test-key-123']);

  String? apiKey;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<void> writeApiKey(String value) async => apiKey = value;

  @override
  Future<void> deleteApiKey() async => apiKey = null;
}

class StreamNetworkError {
  const StreamNetworkError([this.type = DioExceptionType.connectionError]);

  final DioExceptionType type;
}

class SseOk {
  SseOk(this.body, {this.chunkSize = 1000});

  final String body;
  final int chunkSize;
}

class SseStatus {
  SseStatus(this.status, this.body);

  final int status;
  final String body;
}

class SseFailAfter {
  SseFailAfter(this.prefix, {this.chunkSize = 1000});

  final String prefix;
  final int chunkSize;
}

class StreamScriptedAdapter implements HttpClientAdapter {
  StreamScriptedAdapter(this.script);

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
    if (_index >= script.length) {
      throw StateError('script exhausted');
    }
    final Object next = script[_index++];
    if (next is SseOk) {
      final List<int> bytes = utf8.encode(next.body);
      final List<Uint8List> chunks = [];
      for (int i = 0; i < bytes.length; i += next.chunkSize) {
        final int end = min(i + next.chunkSize, bytes.length);
        chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
      }
      return ResponseBody(
        Stream<Uint8List>.fromIterable(chunks),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
    }
    if (next is SseStatus) {
      return ResponseBody.fromString(
        next.body,
        next.status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (next is StreamNetworkError) {
      throw DioException(requestOptions: options, type: next.type);
    }
    if (next is SseFailAfter) {
      Stream<Uint8List> stream() async* {
        final List<int> bytes = utf8.encode(next.prefix);
        for (int i = 0; i < bytes.length; i += next.chunkSize) {
          final int end = min(i + next.chunkSize, bytes.length);
          yield Uint8List.fromList(bytes.sublist(i, end));
        }
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }

      return ResponseBody(
        stream(),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
    }
    throw StateError('Bad script entry: $next');
  }

  @override
  void close({bool force = false}) {}
}

String sseJson(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

String sseText(String content) => sseJson({
  'choices': [
    {
      'delta': {'content': content},
      'finish_reason': null,
    },
  ],
});

String sseToolFirst({
  required int index,
  required String id,
  required String name,
  required String argsPart,
}) => sseJson({
  'choices': [
    {
      'delta': {
        'tool_calls': [
          {
            'index': index,
            'id': id,
            'function': {'name': name, 'arguments': argsPart},
          },
        ],
      },
      'finish_reason': null,
    },
  ],
});

String sseToolArgs({required int index, required String argsPart}) => sseJson({
  'choices': [
    {
      'delta': {
        'tool_calls': [
          {
            'index': index,
            'function': {'arguments': argsPart},
          },
        ],
      },
      'finish_reason': null,
    },
  ],
});

const String sseDone = 'data: [DONE]\n\n';

String sseFinish(String reason) => sseJson({
  'choices': [
    {'delta': <String, dynamic>{}, 'finish_reason': reason},
  ],
});

void main() {
  late StreamFakeSettings settings;
  late StreamFakeKeys keys;
  late List<Duration> delays;
  late StreamScriptedAdapter adapter;
  late DioLlmClient client;

  void setUpClient(List<Object> script) {
    settings = StreamFakeSettings();
    keys = StreamFakeKeys();
    delays = [];
    adapter = StreamScriptedAdapter(script);
    final Dio dio = Dio()..httpClientAdapter = adapter;
    client = DioLlmClient(
      settings: settings,
      keys: keys,
      dio: dio,
      delay: (Duration d) async => delays.add(d),
    );
  }

  List<LlmMessage> messages() => const [
    LlmMessage(role: LlmRole.user, content: 'hi'),
  ];

  Future<List<LlmEvent>> collect(Stream<LlmEvent> stream) => stream.toList();

  test('plain text streams deltas then done', () async {
    setUpClient([SseOk('${sseText('Hello ')}${sseText('world')}$sseDone')]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));

    expect(events, hasLength(3));
    expect((events[0] as TextDelta).text, 'Hello ');
    expect((events[1] as TextDelta).text, 'world');
    expect(events[2], isA<StreamDone>());
    expect(delays, isEmpty);
  });

  test('awkward byte splits still parse (partial lines)', () async {
    final String body = '${sseText('Hello ')}${sseText('world')}$sseDone';
    for (final int size in [1, 3, 7]) {
      setUpClient([SseOk(body, chunkSize: size)]);
      final List<LlmEvent> events = await collect(
        client.streamChat(messages()),
      );
      expect(
        events.whereType<TextDelta>().map((e) => e.text).join(),
        'Hello world',
      );
      expect(events.last, isA<StreamDone>());
    }
  });

  test('comments and empty lines are ignored', () async {
    setUpClient([
      SseOk(
        ': comment\n\n${sseText('hi')}\n: another\n\nevent: message\ndata: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': ' there'},
              'finish_reason': null,
            },
          ],
        })}\n\n$sseDone',
      ),
    ]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'hi there');
    expect(events.last, isA<StreamDone>());
  });

  test('multi-line data fields are joined into one event', () async {
    final String body =
        'data: {"choices":[\n'
        'data: {"delta":{"content":"joined"},"finish_reason":null}]}\n\n'
        '$sseDone';
    setUpClient([SseOk(body)]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));

    expect(events.whereType<TextDelta>().single.text, 'joined');
    expect(events.last, isA<StreamDone>());
  });

  test('multi-line data with a trailing [DONE] still finishes', () async {
    final String body =
        'data: {"choices":[\n'
        'data: {"delta":{"content":"hi"},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n';
    setUpClient([SseOk(body)]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));

    expect(events.whereType<TextDelta>().single.text, 'hi');
    expect(events.last, isA<StreamDone>());
  });

  test('text then tool call emits delta, tool request, done', () async {
    setUpClient([
      SseOk(
        '${sseText('Sure, ')}'
        '${sseToolFirst(index: 0, id: 'call_1', name: 'update_rules', argsPart: '{"con')}'
        '${sseToolArgs(index: 0, argsPart: 'tent":"new rules"}')}'
        '$sseDone',
        chunkSize: 11,
      ),
    ]);

    final List<LlmEvent> events = await collect(
      client.streamChat(
        messages(),
        tools: [
          {
            'type': 'function',
            'function': {'name': 'update_rules'},
          },
        ],
      ),
    );

    expect(events.first, isA<TextDelta>());
    final ToolCallRequest tool = events.whereType<ToolCallRequest>().single;
    expect(tool.id, 'call_1');
    expect(tool.name, 'update_rules');
    expect(tool.argsJson, '{"content":"new rules"}');
    expect(events.last, isA<StreamDone>());
  });

  test('tool arguments split across chunks accumulate by index', () async {
    setUpClient([
      SseOk(
        '${sseToolFirst(index: 0, id: 'call_9', name: 'update_rules', argsPart: '{"a":')}'
        '${sseToolArgs(index: 0, argsPart: '1}')}'
        '$sseDone',
        chunkSize: 5,
      ),
    ]);

    final List<LlmEvent> events = await collect(
      client.streamChat(
        messages(),
        tools: const [
          {
            'type': 'function',
            'function': {'name': 'update_rules'},
          },
        ],
      ),
    );

    final ToolCallRequest tool = events.whereType<ToolCallRequest>().single;
    expect(tool.argsJson, '{"a":1}');
    expect(events.last, isA<StreamDone>());
  });

  test('mid-stream disconnect after text surfaces ServerFailure', () async {
    setUpClient([SseFailAfter(sseText('partial '), chunkSize: 4)]);

    final Stream<LlmEvent> stream = client.streamChat(messages());
    final List<LlmEvent> received = [];
    await expectLater(() async {
      await for (final LlmEvent event in stream) {
        received.add(event);
      }
    }(), throwsA(isA<ServerFailure>()));
    expect(received, hasLength(1));
    expect((received.single as TextDelta).text, 'partial ');
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('finish_reason length surfaces InvalidResponse', () async {
    setUpClient([
      SseOk('${sseText('truncated ')}${sseFinish('length')}$sseDone'),
    ]);

    final Stream<LlmEvent> stream = client.streamChat(messages());
    final List<LlmEvent> received = [];
    await expectLater(() async {
      await for (final LlmEvent event in stream) {
        received.add(event);
      }
    }(), throwsA(isA<InvalidResponseFailure>()));
    expect(received, hasLength(1));
    expect((received.single as TextDelta).text, 'truncated ');
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('finish_reason content_filter surfaces InvalidResponse', () async {
    setUpClient([
      SseOk('${sseText('filtered ')}${sseFinish('content_filter')}$sseDone'),
    ]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('finish_reason on a trailing line without newline is checked', () async {
    final String trailing = jsonEncode({
      'choices': [
        {'delta': <String, dynamic>{}, 'finish_reason': 'length'},
      ],
    });
    setUpClient([SseOk('${sseText('part')}data: $trailing')]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
  });

  test('finish_reason stop and tool_calls are not errors', () async {
    setUpClient([SseOk('${sseText('ok')}${sseFinish('stop')}$sseDone')]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));
    expect(events.whereType<TextDelta>().single.text, 'ok');
    expect(events.last, isA<StreamDone>());

    setUpClient([
      SseOk(
        '${sseToolFirst(index: 0, id: 'call_1', name: 'update_rules', argsPart: '{}')}'
        '${sseFinish('tool_calls')}$sseDone',
      ),
    ]);

    final List<LlmEvent> toolEvents = await collect(
      client.streamChat(
        messages(),
        tools: const [
          {
            'type': 'function',
            'function': {'name': 'update_rules'},
          },
        ],
      ),
    );
    expect(toolEvents.whereType<ToolCallRequest>(), hasLength(1));
    expect(toolEvents.last, isA<StreamDone>());
  });

  test('a 200 with a non-SSE JSON body is an invalid response', () async {
    setUpClient([
      SseOk(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'not a stream'},
            },
          ],
        }),
      ),
    ]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('a 200 with an empty body is an invalid response', () async {
    setUpClient([SseOk('')]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('a [DONE]-only stream with no content is an invalid response', () async {
    setUpClient([SseOk(sseDone)]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
  });

  test(
    'a stream that ends without [DONE] still finishes with its text',
    () async {
      setUpClient([SseOk('${sseText('no done')}${sseText(' marker')}')]);

      final List<LlmEvent> events = await collect(
        client.streamChat(messages()),
      );

      expect(
        events.whereType<TextDelta>().map((e) => e.text).join(),
        'no done marker',
      );
      expect(events.last, isA<StreamDone>());
      expect(adapter.requests, hasLength(1));
      expect(delays, isEmpty);
    },
  );

  test('a broken JSON data line between deltas is skipped', () async {
    setUpClient([
      SseOk(
        '${sseText('before ')}data: {not json}\n\n${sseText('after')}$sseDone',
      ),
    ]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));

    expect(
      events.whereType<TextDelta>().map((e) => e.text).join(),
      'before after',
    );
    expect(events.last, isA<StreamDone>());
  });

  test('a stream whose only data line is broken JSON is invalid', () async {
    setUpClient([SseOk('data: {not json}\n\n')]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('disconnect before first event retries then succeeds', () async {
    setUpClient([
      const StreamNetworkError(),
      SseOk('${sseText('recovered')}$sseDone'),
    ]);

    final List<LlmEvent> events = await collect(client.streamChat(messages()));

    expect(events.whereType<TextDelta>().single.text, 'recovered');
    expect(adapter.requests, hasLength(2));
    expect(delays, [llmRetryDelayFirst]);
  });

  test('no retry after first event (second script entry unused)', () async {
    setUpClient([
      SseFailAfter(sseText('hello '), chunkSize: 3),
      SseOk('${sseText('should not be used')}$sseDone'),
    ]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<ServerFailure>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('400 mentioning tool retries without tools once per session', () async {
    setUpClient([
      SseStatus(400, jsonEncode({'error': 'tools are not supported'})),
      SseOk('${sseText('ok without tools')}$sseDone'),
      SseOk('${sseText('second ok')}$sseDone'),
    ]);
    const List<Map<String, dynamic>> tools = [
      {
        'type': 'function',
        'function': {'name': 'update_rules'},
      },
    ];

    final List<LlmEvent> first = await collect(
      client.streamChat(messages(), tools: tools),
    );
    expect(first.whereType<TextDelta>().single.text, 'ok without tools');
    expect(adapter.requests, hasLength(2));
    expect(
      (adapter.requests[0].data as Map<String, dynamic>).containsKey('tools'),
      isTrue,
    );
    expect(
      (adapter.requests[1].data as Map<String, dynamic>).containsKey('tools'),
      isFalse,
    );
    expect(delays, isEmpty);

    final List<LlmEvent> second = await collect(
      client.streamChat(messages(), tools: tools),
    );
    expect(second.whereType<TextDelta>().single.text, 'second ok');
    expect(adapter.requests, hasLength(3));
    expect(
      (adapter.requests[2].data as Map<String, dynamic>).containsKey('tools'),
      isFalse,
    );
  });

  test('400 without tool mention throws InvalidResponse', () async {
    setUpClient([
      SseStatus(400, jsonEncode({'error': 'bad request'})),
    ]);

    await expectLater(
      client
          .streamChat(
            messages(),
            tools: const [
              {
                'type': 'function',
                'function': {'name': 'update_rules'},
              },
            ],
          )
          .toList(),
      throwsA(isA<InvalidResponseFailure>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('request shape: url, auth, stream, temperature, tools', () async {
    setUpClient([SseOk('${sseText('x')}$sseDone')]);
    settings.baseUrlValue = 'https://example.com/v1///';

    await collect(
      client.streamChat(
        messages(),
        tools: const [
          {
            'type': 'function',
            'function': {'name': 'update_rules'},
          },
        ],
      ),
    );

    final RequestOptions request = adapter.requests.single;
    expect(request.uri.toString(), 'https://example.com/v1/chat/completions');
    expect(request.headers['Authorization'], 'Bearer test-key-123');
    final Map<String, dynamic> body = request.data as Map<String, dynamic>;
    expect(body['model'], 'test-model');
    expect(body['stream'], isTrue);
    expect(body['temperature'], 0.8);
    expect(body['tools'], hasLength(1));
  });

  test('401 throws AuthFailure without retry', () async {
    setUpClient([SseStatus(401, '{"error":"no"}')]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<AuthFailure>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('429 retried then RateLimitFailure', () async {
    setUpClient([
      SseStatus(429, 'busy'),
      SseStatus(429, 'busy'),
      SseStatus(429, 'busy'),
    ]);

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<RateLimitFailure>()),
    );
    expect(adapter.requests, hasLength(3));
    expect(delays, [llmRetryDelayFirst, llmRetryDelaySecond]);
  });

  test('not configured throws without a request', () async {
    setUpClient([SseOk('${sseText('x')}$sseDone')]);
    keys.apiKey = null;

    await expectLater(
      client.streamChat(messages()).toList(),
      throwsA(isA<NotConfiguredFailure>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('api key never appears in stream errors', () async {
    const String secret = 'super-secret-key-xyz-123';
    setUpClient([SseStatus(401, 'denied')]);
    keys.apiKey = secret;

    try {
      await client.streamChat(messages()).toList();
      fail('expected AuthFailure');
    } on AppFailure catch (e) {
      expect(e.toString(), isNot(contains(secret)));
      expect(e.userMessage, isNot(contains(secret)));
    }
  });
}
