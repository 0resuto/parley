import 'package:dio/dio.dart';

import 'package:parley/core/constants.dart';

/// Creates the [Dio] used for LLM requests with the timeout defaults.
///
/// Shared by `DioLlmClient` and `ModelCatalog` (A-12): a stalled connection
/// must fail instead of hanging the app forever. Tests inject their own
/// [Dio] with a scripted adapter instead.
Dio createLlmDio() {
  return Dio(
    BaseOptions(
      connectTimeout: llmConnectTimeout,
      sendTimeout: llmSendTimeout,
      receiveTimeout: llmReceiveTimeout,
    ),
  );
}
