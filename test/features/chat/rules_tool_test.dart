import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/chat/rules_tool.dart';

void main() {
  group('rules_tool 6.8', () {
    test('tool definition matches SPEC 6.4 verbatim', () {
      expect(updateRulesTool['type'], 'function');
      final Map func = updateRulesTool['function'] as Map;
      expect(func['name'], 'update_rules');
      expect(
        func['description'],
        'Replace the tutor rules document. Call ONLY when the user clearly and directly asks to change the rules. Provide the COMPLETE new rules document in Markdown, keeping everything the user did not ask to change. Maximum 6000 characters.',
      );
      final Map params = func['parameters'] as Map;
      expect(params['type'], 'object');
      final Map props = params['properties'] as Map;
      expect((props['content'] as Map)['description'], 'complete new rules.md');
      expect(
        (props['summary'] as Map)['description'],
        'one short sentence describing the change',
      );
      expect(params['required'], ['content', 'summary']);
    });

    test('parses valid args', () {
      final args = tryParseUpdateRulesArgs(
        jsonEncode({'content': 'new rules', 'summary': 'test change'}),
      );
      expect(args, isNotNull);
      expect(args!.content, 'new rules');
      expect(args.summary, 'test change');
    });

    test('invalid JSON returns null', () {
      expect(tryParseUpdateRulesArgs('not json'), isNull);
      expect(tryParseUpdateRulesArgs('{"content":'), isNull);
    });

    test('missing content returns null', () {
      expect(tryParseUpdateRulesArgs(jsonEncode({'summary': 'x'})), isNull);
      expect(
        tryParseUpdateRulesArgs(jsonEncode({'content': 42, 'summary': 'x'})),
        isNull,
      );
    });

    test('too-long message format matches SPEC', () {
      expect(
        updateRulesTooLongResult(6001, 6000),
        'ERROR: too long (6001 > 6000). Shorten it and call again.',
      );
      expect(updateRulesOkResult, 'OK: rules updated.');
      expect(updateRulesEmptyResult, 'ERROR: content is empty.');
    });

    test('event round trip with reverted flag', () {
      final String json = buildRulesUpdatedEvent(
        summary: 'made it shorter',
        versionId: 'rules_123.md',
      );
      final event = parseRulesUpdatedEvent(json);
      expect(event, isNotNull);
      expect(event!.summary, 'made it shorter');
      expect(event.versionId, 'rules_123.md');
      expect(event.reverted, isFalse);

      final String revertedJson = buildRulesUpdatedEvent(
        summary: 's',
        versionId: 'v',
        reverted: true,
      );
      expect(parseRulesUpdatedEvent(revertedJson)!.reverted, isTrue);
    });

    test('non-event content returns null', () {
      expect(parseRulesUpdatedEvent('hello'), isNull);
      expect(parseRulesUpdatedEvent(jsonEncode({'type': 'other'})), isNull);
    });
  });
}
