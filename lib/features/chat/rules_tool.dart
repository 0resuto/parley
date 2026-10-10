import 'dart:convert';

/// Tool name for SPEC 6.4.
const String updateRulesToolName = 'update_rules';

/// `update_rules` tool definition (SPEC 6.4, verbatim strings).
const Map<String, dynamic> updateRulesTool = {
  'type': 'function',
  'function': {
    'name': 'update_rules',
    'description':
        'Replace the tutor rules document. Call ONLY when the user clearly and directly asks to change the rules. Provide the COMPLETE new rules document in Markdown, keeping everything the user did not ask to change. Maximum 6000 characters.',
    'parameters': {
      'type': 'object',
      'properties': {
        'content': {'type': 'string', 'description': 'complete new rules.md'},
        'summary': {
          'type': 'string',
          'description': 'one short sentence describing the change',
        },
      },
      'required': ['content', 'summary'],
    },
  },
};

/// Tool result when rules were written.
const String updateRulesOkResult = 'OK: rules updated.';

/// Tool result when the new content is missing or unparseable.
const String updateRulesEmptyResult = 'ERROR: content is empty.';

/// Tool result prefix/suffix for over-limit content (SPEC 6.4).
String updateRulesTooLongResult(int length, int limit) {
  return 'ERROR: too long ($length > $limit). Shorten it and call again.';
}

/// Tool result when the tool name is unknown (not in SPEC; keeps the
/// OpenAI assistant/tool sequence valid).
const String updateRulesUnknownToolResult = 'ERROR: unknown tool.';

/// Parsed `update_rules` arguments.
class UpdateRulesArgs {
  const UpdateRulesArgs({required this.content, required this.summary});

  final String content;
  final String summary;
}

/// Parses `update_rules` `argsJson`.
///
/// Returns null when the JSON is invalid or `content` is missing/not a
/// string. Callers treat null as empty content (SPEC has no separate
/// invalid-JSON result).
UpdateRulesArgs? tryParseUpdateRulesArgs(String argsJson) {
  try {
    final Object? decoded = jsonDecode(argsJson);
    if (decoded is! Map) {
      return null;
    }
    final Map<dynamic, dynamic> map = decoded;
    final Object? content = map['content'];
    if (content is! String) {
      return null;
    }
    final Object? summary = map['summary'];
    return UpdateRulesArgs(
      content: content,
      summary: summary is String ? summary : '',
    );
  } catch (_) {
    return null;
  }
}

/// One `rules_updated` event message (SPEC 4.1).
class RulesUpdatedEvent {
  const RulesUpdatedEvent({
    required this.summary,
    required this.versionId,
    this.reverted = false,
  });

  final String summary;
  final String versionId;
  final bool reverted;
}

/// Builds the JSON stored in an `event` message.
String buildRulesUpdatedEvent({
  required String summary,
  required String versionId,
  bool reverted = false,
}) {
  final Map<String, Object?> map = {
    'type': 'rules_updated',
    'summary': summary,
    'versionId': versionId,
  };
  if (reverted) {
    map['reverted'] = true;
  }
  return jsonEncode(map);
}

/// Parses a `rules_updated` event, or null when [content] is not one.
RulesUpdatedEvent? parseRulesUpdatedEvent(String content) {
  try {
    final Object? decoded = jsonDecode(content);
    if (decoded is! Map) {
      return null;
    }
    final Map<dynamic, dynamic> map = decoded;
    if (map['type'] != 'rules_updated') {
      return null;
    }
    final Object? summary = map['summary'];
    final Object? versionId = map['versionId'];
    final Object? reverted = map['reverted'];
    return RulesUpdatedEvent(
      summary: summary is String ? summary : '',
      versionId: versionId is String ? versionId : '',
      reverted: reverted == true,
    );
  } catch (_) {
    return null;
  }
}
