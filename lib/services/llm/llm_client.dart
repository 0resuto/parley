import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/llm_dio.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

/// Role of one chat message (SPEC 6.1).
enum LlmRole {
  system('system'),
  user('user'),
  assistant('assistant'),
  tool('tool');

  const LlmRole(this.value);

  final String value;
}

/// One optional tool call attached to an assistant message.
class LlmToolCall {
  const LlmToolCall({required this.name, required this.argumentsJson, this.id});

  final String? id;
  final String name;
  final String argumentsJson;
}

/// One chat message sent to or received from the LLM.
class LlmMessage {
  const LlmMessage({
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
  });

  final LlmRole role;
  final String content;
  final List<LlmToolCall> toolCalls;
  final String? toolCallId;

  Map<String, Object?> toJson() {
    return {
      'role': role.value,
      'content': content,
      if (toolCallId != null) 'tool_call_id': toolCallId,
      if (toolCalls.isNotEmpty)
        'tool_calls': [
          for (final call in toolCalls)
            {
              if (call.id != null) 'id': call.id,
              'type': 'function',
              'function': {'name': call.name, 'arguments': call.argumentsJson},
            },
        ],
    };
  }
}

/// Streaming event (full implementation arrives in task 4.2).
sealed class LlmEvent {
  const LlmEvent();
}

/// One chunk of streamed assistant text.
final class TextDelta extends LlmEvent {
  const TextDelta(this.text);

  final String text;
}

/// The model asked to call a tool.
final class ToolCallRequest extends LlmEvent {
  const ToolCallRequest({
    required this.id,
    required this.name,
    required this.argsJson,
  });

  final String id;
  final String name;
  final String argsJson;
}

/// The stream finished.
final class StreamDone extends LlmEvent {
  const StreamDone();
}

/// OpenAI Chat Completions client (SPEC 6.1, 5.9).
abstract class LlmClient {
  /// Non-streaming completion (temperature defaults to 0.2 for JSON jobs).
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  });

  /// Streaming chat (temperature defaults to 0.8 for chat).
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  });
}

/// Accumulated fragments of one streamed tool call, keyed by `index`.
class _ToolAccum {
  String? id;
  String? name;
  final StringBuffer args = StringBuffer();
}

/// [LlmClient] backed by `dio`.
///
/// Retries network errors, 429 and 5xx up to 2 times with waits of
/// 1 s then 3 s, only before the first streamed event. 400/401/403
/// are never retried (except the one-time tools fallback of SPEC 5.9).
/// Failures never contain the API key.
class DioLlmClient implements LlmClient {
  DioLlmClient({
    required SettingsRepository settings,
    required SecureKeyStore keys,
    Dio? dio,
    Future<void> Function(Duration)? delay,
    Duration? completeTimeout,
  }) : _settings = settings,
       _keys = keys,
       _dio = dio ?? createLlmDio(),
       _delay = delay ?? Future.delayed,
       _completeTimeout = completeTimeout ?? llmCompleteTimeout;

  final SettingsRepository _settings;
  final SecureKeyStore _keys;
  final Dio _dio;
  final Future<void> Function(Duration) _delay;

  /// Overall cap for one non-streaming request (A-12); Dio's receive
  /// timeout only fires between body chunks.
  final Duration _completeTimeout;

  /// Once a tools request gets HTTP 400 mentioning "tool", all further
  /// streaming (and only streaming) requests in this session go
  /// without tools (SPEC 5.9).
  bool _dropToolsForSession = false;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    final String baseUrl = _settings.baseUrl.trim();
    final String model = _settings.model.trim();
    final String? apiKey = await _keys.readApiKey();
    if (baseUrl.isEmpty || model.isEmpty || (apiKey?.trim().isEmpty ?? true)) {
      throw const NotConfiguredFailure();
    }
    final String url = '${_stripTrailingSlash(baseUrl)}/chat/completions';
    final Map<String, Object?> body = {
      'model': model,
      'messages': [for (final LlmMessage message in messages) message.toJson()],
      'stream': false,
      'temperature': temperature,
    };
    // Authorization header holds the key; it is never copied into errors.
    final Map<String, String> headers = {
      'Authorization': 'Bearer ${apiKey!.trim()}',
      'Content-Type': 'application/json',
    };

    for (int attempt = 0; ; attempt++) {
      try {
        final Response<dynamic> response = await _dio
            .post(
              url,
              data: body,
              options: Options(
                headers: headers,
                // Plain keeps Dio's JSON transformer out of the way: a
                // broken 200 body must become InvalidResponseFailure, not
                // a DioException that looks like a network error (A-18).
                responseType: ResponseType.plain,
              ),
            )
            .timeout(_completeTimeout);
        return _parseComplete(response.data);
      } on TimeoutException {
        if (attempt < llmMaxRetries) {
          await _delay(attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond);
          continue;
        }
        throw const ServerFailure();
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

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) async* {
    final String baseUrl = _settings.baseUrl.trim();
    final String model = _settings.model.trim();
    final String? apiKey = await _keys.readApiKey();
    if (baseUrl.isEmpty || model.isEmpty || (apiKey?.trim().isEmpty ?? true)) {
      throw const NotConfiguredFailure();
    }
    final String url = '${_stripTrailingSlash(baseUrl)}/chat/completions';
    final Map<String, String> headers = {
      'Authorization': 'Bearer ${apiKey!.trim()}',
      'Content-Type': 'application/json',
    };

    List<Map<String, dynamic>>? effectiveTools = tools;
    if (_dropToolsForSession) {
      effectiveTools = null;
    }

    int attempt = 0;
    while (true) {
      final Map<String, Object?> body = {
        'model': model,
        'messages': [
          for (final LlmMessage message in messages) message.toJson(),
        ],
        'stream': true,
        'temperature': temperature,
        if (effectiveTools != null && effectiveTools.isNotEmpty)
          'tools': effectiveTools,
      };

      late final Response<ResponseBody> response;
      try {
        response = await _dio.post<ResponseBody>(
          url,
          data: body,
          options: Options(
            headers: headers,
            responseType: ResponseType.stream,
            // Handle error statuses by hand so the 400-with-tools body
            // can be inspected for the SPEC 5.9 fallback.
            validateStatus: (_) => true,
            receiveDataWhenStatusError: true,
          ),
        );
      } on DioException catch (e) {
        final int? status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          throw const AuthFailure();
        }
        final bool retriable =
            status == 429 ||
            (status != null && status >= 500 && status <= 599) ||
            _isNetworkError(e);
        if (retriable && attempt < llmMaxRetries) {
          await _delay(attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond);
          attempt++;
          continue;
        }
        if (status == 429) {
          throw const RateLimitFailure();
        }
        if (status != null && status >= 400 && status < 500) {
          throw const InvalidResponseFailure();
        }
        throw const ServerFailure();
      }

      final int status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw const AuthFailure();
      }
      if (status == 429) {
        if (attempt < llmMaxRetries) {
          await _delay(attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond);
          attempt++;
          continue;
        }
        throw const RateLimitFailure();
      }
      if (status >= 500 && status <= 599) {
        if (attempt < llmMaxRetries) {
          await _delay(attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond);
          attempt++;
          continue;
        }
        throw const ServerFailure();
      }
      if (status == 400 &&
          effectiveTools != null &&
          effectiveTools.isNotEmpty &&
          !_dropToolsForSession) {
        final String errorBody = await _readBodyString(response.data);
        if (errorBody.toLowerCase().contains('tool')) {
          _dropToolsForSession = true;
          effectiveTools = null;
          continue;
        }
        throw const InvalidResponseFailure();
      }
      if (status != 200) {
        if (status >= 400 && status < 500) {
          throw const InvalidResponseFailure();
        }
        throw const ServerFailure();
      }

      final ResponseBody? responseBody = response.data;
      if (responseBody == null) {
        throw const InvalidResponseFailure();
      }

      bool firstEvent = false;
      final Map<int, _ToolAccum> toolAccum = {};
      String buffer = '';
      bool doneSeen = false;
      String? finishReason;

      try {
        final Stream<String> textStream = const Utf8Decoder(
          allowMalformed: true,
        ).bind(responseBody.stream.cast<List<int>>());
        // SSE state: consecutive `data:` fields of one event are joined
        // with newlines and dispatched on the blank line (A-21).
        final List<String> dataLines = <String>[];
        final List<String> pendingTexts = <String>[];

        void dispatchPayload(String payload) {
          if (payload.trim() == '[DONE]') {
            doneSeen = true;
            return;
          }
          final ({List<String> texts, String? finishReason}) parsed =
              _parseSsePayload(payload, toolAccum);
          if (parsed.finishReason != null) {
            finishReason = parsed.finishReason;
          }
          pendingTexts.addAll(parsed.texts);
        }

        void handleSseLine(String line) {
          if (line.isEmpty) {
            if (dataLines.isNotEmpty) {
              final String payload = dataLines.join('\n');
              dataLines.clear();
              dispatchPayload(payload);
            }
            return;
          }
          if (line.startsWith(':')) {
            return;
          }
          if (!line.startsWith('data:')) {
            return;
          }
          String value = line.substring(5);
          if (value.startsWith(' ')) {
            value = value.substring(1);
          }
          dataLines.add(value);
        }

        await for (final String chunk in textStream) {
          buffer += chunk;
          int newline;
          while ((newline = buffer.indexOf('\n')) != -1) {
            String line = buffer.substring(0, newline);
            buffer = buffer.substring(newline + 1);
            if (line.endsWith('\r')) {
              line = line.substring(0, line.length - 1);
            }
            handleSseLine(line);
            while (pendingTexts.isNotEmpty) {
              firstEvent = true;
              yield TextDelta(pendingTexts.removeAt(0));
            }
            if (doneSeen) {
              buffer = '';
              break;
            }
          }
          if (doneSeen) {
            break;
          }
        }
        if (!doneSeen && buffer.isNotEmpty) {
          String line = buffer;
          buffer = '';
          if (line.endsWith('\r')) {
            line = line.substring(0, line.length - 1);
          }
          handleSseLine(line);
          while (pendingTexts.isNotEmpty) {
            firstEvent = true;
            yield TextDelta(pendingTexts.removeAt(0));
          }
        }
        if (!doneSeen && dataLines.isNotEmpty) {
          final String payload = dataLines.join('\n');
          dataLines.clear();
          dispatchPayload(payload);
          while (pendingTexts.isNotEmpty) {
            firstEvent = true;
            yield TextDelta(pendingTexts.removeAt(0));
          }
        }
      } catch (e) {
        if (e is AppFailure) {
          rethrow;
        }
        if (!firstEvent && toolAccum.isEmpty) {
          if (e is DioException) {
            final int? errorStatus = e.response?.statusCode;
            if (errorStatus == 401 || errorStatus == 403) {
              throw const AuthFailure();
            }
            final bool retriable =
                errorStatus == 429 ||
                (errorStatus != null &&
                    errorStatus >= 500 &&
                    errorStatus <= 599) ||
                _isNetworkError(e);
            if (retriable && attempt < llmMaxRetries) {
              await _delay(
                attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond,
              );
              attempt++;
              continue;
            }
            if (errorStatus == 429) {
              throw const RateLimitFailure();
            }
            if (errorStatus != null &&
                errorStatus >= 400 &&
                errorStatus < 500) {
              throw const InvalidResponseFailure();
            }
          } else if (attempt < llmMaxRetries) {
            await _delay(
              attempt == 0 ? llmRetryDelayFirst : llmRetryDelaySecond,
            );
            attempt++;
            continue;
          }
        }
        throw const ServerFailure();
      }

      // A truncated or filtered reply is not a usable answer: the text
      // that arrived is incomplete, so surface it as an invalid response
      // (the UI offers Retry) instead of saving it as a full reply (A-16).
      if (finishReason == 'length' || finishReason == 'content_filter') {
        throw const InvalidResponseFailure();
      }

      // A 200 whose body carries no parseable SSE events (a JSON error
      // body, HTML or an empty stream) must not surface as a silent empty
      // reply: the user would see nothing at all (A-17).
      if (!firstEvent && toolAccum.isEmpty) {
        throw const InvalidResponseFailure();
      }

      final List<int> indexes = toolAccum.keys.toList()..sort();
      for (final int index in indexes) {
        final _ToolAccum accum = toolAccum[index]!;
        if ((accum.name == null || accum.name!.isEmpty) &&
            accum.args.isEmpty &&
            (accum.id == null || accum.id!.isEmpty)) {
          continue;
        }
        yield ToolCallRequest(
          id: accum.id ?? '',
          name: accum.name ?? '',
          argsJson: accum.args.toString(),
        );
      }
      yield const StreamDone();
      return;
    }
  }

  /// Parses one SSE event payload (the `data:` fields joined with `\n`).
  ///
  /// Returns the text deltas to yield and the `finish_reason` when the
  /// chunk carries one; tool-call fragments accumulate into [toolAccum]
  /// by index. Malformed payloads return empty results (A-21).
  ({List<String> texts, String? finishReason}) _parseSsePayload(
    String payload,
    Map<int, _ToolAccum> toolAccum,
  ) {
    final List<String> texts = <String>[];
    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return (texts: texts, finishReason: null);
    }
    final Object? choicesObj = decoded['choices'];
    if (choicesObj is! List || choicesObj.isEmpty) {
      return (texts: texts, finishReason: null);
    }
    final Object? firstObj = choicesObj.first;
    if (firstObj is! Map<dynamic, dynamic>) {
      return (texts: texts, finishReason: null);
    }
    final Map<dynamic, dynamic> first = firstObj;
    final Object? finish = first['finish_reason'];
    final String? finishReason = finish is String && finish.isNotEmpty
        ? finish
        : null;
    final Object? deltaObj = first['delta'];
    if (deltaObj is Map<dynamic, dynamic>) {
      final Map<dynamic, dynamic> delta = deltaObj;
      final Object? content = delta['content'];
      if (content is String && content.isNotEmpty) {
        texts.add(content);
      }
      final Object? callsObj = delta['tool_calls'];
      if (callsObj is List) {
        for (final Object? entry in callsObj) {
          if (entry is! Map<dynamic, dynamic>) {
            continue;
          }
          final Map<dynamic, dynamic> call = entry;
          int index = 0;
          if (call['index'] is int) {
            index = call['index'] as int;
          }
          final _ToolAccum accum = toolAccum.putIfAbsent(
            index,
            () => _ToolAccum(),
          );
          if (call['id'] is String && (call['id'] as String).isNotEmpty) {
            accum.id = call['id'] as String;
          }
          if (call['function'] is Map) {
            final Map<dynamic, dynamic> function = call['function'] as Map;
            if (function['name'] is String &&
                (function['name'] as String).isNotEmpty) {
              accum.name = function['name'] as String;
            }
            if (function['arguments'] is String) {
              accum.args.write(function['arguments'] as String);
            }
          }
        }
      }
    }
    return (texts: texts, finishReason: finishReason);
  }

  /// Reads an error [ResponseBody] stream to a string for the 400
  /// tool-fallback check. Never throws; empty string means "no body".
  Future<String> _readBodyString(ResponseBody? body) async {
    if (body == null) {
      return '';
    }
    try {
      return await const Utf8Decoder(
        allowMalformed: true,
      ).bind(body.stream.cast<List<int>>()).join();
    } catch (_) {
      return '';
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

  /// Reads `choices[0].message.content` or throws [InvalidResponseFailure].
  String _parseComplete(Object? data) {
    try {
      final Object? decoded = data is String ? jsonDecode(data) : data;
      final Map<String, dynamic> map = decoded as Map<String, dynamic>;
      final List<dynamic> choices = map['choices'] as List<dynamic>;
      final Map<String, dynamic> message =
          (choices.first as Map<String, dynamic>)['message']
              as Map<String, dynamic>;
      final Object? content = message['content'];
      if (content is! String) {
        throw const InvalidResponseFailure();
      }
      return content;
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const InvalidResponseFailure();
    }
  }

  String _stripTrailingSlash(String value) {
    String result = value;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
