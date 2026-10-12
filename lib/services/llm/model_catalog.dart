import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/llm_dio.dart';

/// Lists model ids from an OpenAI-format `GET <base>/models` endpoint.
///
/// Returns `{"data": [{"id": "..."}, ...]}`.ids in response order,
/// deduplicated; blank ids are skipped. An empty list is valid (the UI
/// then keeps the manual text field). Anything else throws
/// [InvalidResponseFailure].
List<String> parseModelIds(Object? data) {
  try {
    final Object? decoded = data is String ? jsonDecode(data) : data;
    final Map<String, dynamic> map = decoded as Map<String, dynamic>;
    final List<dynamic> items = map['data'] as List<dynamic>;
    final List<String> ids = [];
    for (final Object? item in items) {
      final Map<String, dynamic> entry = item as Map<String, dynamic>;
      final Object? id = entry['id'];
      if (id is! String || id.trim().isEmpty) {
        continue;
      }
      if (!ids.contains(id)) {
        ids.add(id);
      }
    }
    return ids;
  } on AppFailure {
    rethrow;
  } catch (_) {
    throw const InvalidResponseFailure();
  }
}

/// Fetches available model ids (OpenAI `GET <base>/models`).
///
/// Only the base URL and the API key are required: the model itself is
/// what the user is picking, so an empty model is fine. Failures follow
/// SPEC 5.9 like [DioLlmClient.complete]: 401/403 become [AuthFailure]
/// without retry, network errors / 429 / 5xx are retried up to 2 times
/// (waits 1 s then 3 s, injectable so tests are instant). Failures never
/// contain the API key.
class ModelCatalog {
  ModelCatalog({Dio? dio, Future<void> Function(Duration)? delay})
    : _dio = dio ?? createLlmDio(),
      _delay = delay ?? Future.delayed;

  final Dio _dio;
  final Future<void> Function(Duration) _delay;

  Future<List<String>> fetchModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    final String base = baseUrl.trim();
    final String key = apiKey.trim();
    if (base.isEmpty || key.isEmpty) {
      throw const NotConfiguredFailure();
    }
    final String url = '${_stripTrailingSlash(base)}/models';
    // Authorization header holds the key; it is never copied into errors.
    final Map<String, String> headers = {
      'Authorization': 'Bearer $key',
      'Content-Type': 'application/json',
    };

    for (int attempt = 0; ; attempt++) {
      try {
        final Response<dynamic> response = await _dio.get(
          url,
          options: Options(
            headers: headers,
            // Plain keeps Dio's JSON transformer out of the way: a broken
            // 200 body must become InvalidResponseFailure, not a
            // DioException that looks like a network error (A-18).
            responseType: ResponseType.plain,
          ),
        );
        return parseModelIds(response.data);
      } on DioException catch (e) {
        final int? status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          throw const AuthFailure();
        }
        final bool retriable =
            status == 429 ||
            (status != null && status >= 500 && status <= 599) ||
            _isNetworkError(e);
        if (retriable) {
          if (attempt < llmMaxRetries) {
            await _delay(
              attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond,
            );
            continue;
          }
          if (status == 429) {
            throw const RateLimitFailure();
          }
          throw const ServerFailure();
        }
        if (status != null && status >= 400 && status < 500) {
          throw const InvalidResponseFailure();
        }
        throw const ServerFailure();
      } on AppFailure {
        rethrow;
      } catch (_) {
        throw const ServerFailure();
      }
    }
  }

  /// True for transport problems without an HTTP response.
  ///
  /// Cancel and bad certificates are not retried.
  bool _isNetworkError(DioException e) {
    if (e.response != null) {
      return false;
    }
    if (e.type == DioExceptionType.cancel) {
      return false;
    }
    if (e.type == DioExceptionType.badCertificate) {
      return false;
    }
    return true;
  }

  String _stripTrailingSlash(String value) {
    String result = value;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
