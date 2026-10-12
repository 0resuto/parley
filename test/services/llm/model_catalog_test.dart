import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/model_catalog.dart';

class Canned {
  const Canned(this.status, this.body);

  final int status;
  final String body;
}

class NetworkError {
  const NetworkError([this.type = DioExceptionType.connectionError]);

  final DioExceptionType type;
}

Canned models(List<String> ids) {
  return Canned(
    200,
    jsonEncode({
      'data': [
        for (final String id in ids) {'id': id},
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
    if (_index >= script.length) {
      throw StateError('script exhausted');
    }
    final Object next = script[_index++];
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
  late List<Duration> delays;
  late ScriptedAdapter adapter;
  late ModelCatalog catalog;

  void setUpCatalog(List<Object> script) {
    delays = [];
    adapter = ScriptedAdapter(script);
    final Dio dio = Dio()..httpClientAdapter = adapter;
    catalog = ModelCatalog(
      dio: dio,
      delay: (Duration d) async {
        delays.add(d);
      },
    );
  }

  Future<List<String>> fetch() {
    return catalog.fetchModels(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key-123',
    );
  }

  group('ModelCatalog', () {
    test(
      'success returns ids and sends a GET with the bearer header',
      () async {
        setUpCatalog([
          models(['gpt-a', 'gpt-b']),
        ]);

        final List<String> ids = await fetch();

        expect(ids, ['gpt-a', 'gpt-b']);
        expect(adapter.requests, hasLength(1));
        final RequestOptions request = adapter.requests.single;
        expect(request.method, 'GET');
        expect(request.uri.toString(), 'https://example.com/v1/models');
        expect(request.headers['Authorization'], 'Bearer test-key-123');
        expect(delays, isEmpty);
      },
    );

    test('trailing slash in base url is handled', () async {
      setUpCatalog([
        models(['gpt-a']),
      ]);

      final List<String> ids = await catalog.fetchModels(
        baseUrl: 'https://example.com/v1///',
        apiKey: 'test-key-123',
      );

      expect(ids, ['gpt-a']);
      expect(
        adapter.requests.single.uri.toString(),
        'https://example.com/v1/models',
      );
    });

    test('blank ids are skipped and duplicates removed', () async {
      setUpCatalog([
        Canned(
          200,
          jsonEncode({
            'data': [
              {'id': 'gpt-a'},
              {'id': '  '},
              {'id': 'gpt-a'},
              {'id': 'gpt-b'},
              {'nope': 1},
            ],
          }),
        ),
      ]);

      // The entry without an id is dropped by the parser guard.
      expect(await fetch(), ['gpt-a', 'gpt-b']);
    });

    test('empty data is valid and returns an empty list', () async {
      setUpCatalog([models([])]);

      expect(await fetch(), isEmpty);
      expect(adapter.requests, hasLength(1));
    });

    test('missing base url throws NotConfigured without a request', () async {
      setUpCatalog([
        models(['gpt-a']),
      ]);

      await expectLater(
        catalog.fetchModels(baseUrl: '   ', apiKey: 'test-key-123'),
        throwsA(isA<NotConfiguredFailure>()),
      );
      expect(adapter.requests, isEmpty);
      expect(delays, isEmpty);
    });

    test('missing api key throws NotConfigured without a request', () async {
      setUpCatalog([
        models(['gpt-a']),
      ]);

      await expectLater(
        catalog.fetchModels(baseUrl: 'https://example.com/v1', apiKey: '  '),
        throwsA(isA<NotConfiguredFailure>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('empty model is fine: listing does not need a model', () async {
      setUpCatalog([
        models(['gpt-a']),
      ]);

      // No model concept here at all; blank key is the only gate.
      final List<String> ids = await catalog.fetchModels(
        baseUrl: 'https://example.com/v1',
        apiKey: 'test-key-123',
      );

      expect(ids, ['gpt-a']);
    });

    test('401 throws AuthFailure without retry', () async {
      setUpCatalog([status(401)]);

      await expectLater(fetch(), throwsA(isA<AuthFailure>()));
      expect(adapter.requests, hasLength(1));
      expect(delays, isEmpty);
    });

    test('429 retried then RateLimitFailure', () async {
      setUpCatalog([status(429), status(429), status(429)]);

      await expectLater(fetch(), throwsA(isA<RateLimitFailure>()));
      expect(adapter.requests, hasLength(3));
      expect(delays, [llmRetryDelayFirst, llmRetryDelaySecond]);
    });

    test('429 then success returns ids', () async {
      setUpCatalog([
        status(429),
        models(['gpt-a']),
      ]);

      expect(await fetch(), ['gpt-a']);
      expect(adapter.requests, hasLength(2));
      expect(delays, [llmRetryDelayFirst]);
    });

    test('5xx retried then ServerFailure', () async {
      setUpCatalog([status(500), status(500), status(500)]);

      await expectLater(fetch(), throwsA(isA<ServerFailure>()));
      expect(adapter.requests, hasLength(3));
    });

    test('network error retried then ServerFailure', () async {
      setUpCatalog([
        const NetworkError(),
        const NetworkError(),
        const NetworkError(),
      ]);

      await expectLater(fetch(), throwsA(isA<ServerFailure>()));
      expect(adapter.requests, hasLength(3));
    });

    test('404 throws InvalidResponse without retry', () async {
      setUpCatalog([status(404)]);

      await expectLater(fetch(), throwsA(isA<InvalidResponseFailure>()));
      expect(adapter.requests, hasLength(1));
      expect(delays, isEmpty);
    });

    test('non-list data throws InvalidResponse', () async {
      setUpCatalog([const Canned(200, '{"data":"nope"}')]);

      await expectLater(fetch(), throwsA(isA<InvalidResponseFailure>()));
      expect(adapter.requests, hasLength(1));
      expect(delays, isEmpty);
    });

    test('missing data key throws InvalidResponse', () async {
      setUpCatalog([const Canned(200, '{"object":"list"}')]);

      await expectLater(fetch(), throwsA(isA<InvalidResponseFailure>()));
    });

    test('broken JSON on 200 throws InvalidResponse without retry', () async {
      setUpCatalog([const Canned(200, 'not json {')]);

      await expectLater(fetch(), throwsA(isA<InvalidResponseFailure>()));
      expect(adapter.requests, hasLength(1));
      expect(delays, isEmpty);
    });

    test('api key never appears in any exception message', () async {
      setUpCatalog([status(500), status(500), status(500)]);

      try {
        await catalog.fetchModels(
          baseUrl: 'https://example.com/v1',
          apiKey: 'super-secret-key',
        );
        fail('expected ServerFailure');
      } catch (e) {
        expect(e.toString(), isNot(contains('super-secret-key')));
        expect(e, isA<ServerFailure>());
      }
    });

    test('parser helper covers the shape rules', () {
      expect(parseModelIds({'data': []}), isEmpty);
      expect(
        parseModelIds({
          'data': [
            {'id': 'a'},
            {'id': 'b'},
          ],
        }),
        ['a', 'b'],
      );
      expect(
        () => parseModelIds({'object': 'list'}),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => parseModelIds('nope'),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });
  });
}
