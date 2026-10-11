import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/failures.dart';
import 'package:parley/core/json_extract.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/translation/translation.dart';
import 'package:parley/services/tts/tts_service.dart';
import 'package:parley/services/tutor/tap_again_policy.dart';

/// Shown when the tapped word has no dictionary unit and the device is
/// offline (SPEC 5.5, exact string).
const String wordPopupOfflineMessage = 'Translation isn\'t available offline.';

/// Opens the word popup bottom sheet (SPEC 5.5).
Future<void> showWordPopup({
  required BuildContext context,
  required String surface,
  required String wordKey,
  required String sentence,
  Unit? initialUnit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => WordPopup(
      surface: surface,
      wordKey: wordKey,
      sentence: sentence,
      initialUnit: initialUnit,
    ),
  );
}

/// Word popup bottom sheet (SPEC 5.5, PLAN 6.6).
class WordPopup extends ConsumerStatefulWidget {
  const WordPopup({
    super.key,
    required this.surface,
    required this.wordKey,
    required this.sentence,
    this.initialUnit,
  });

  final String surface;
  final String wordKey;
  final String sentence;
  final Unit? initialUnit;

  @override
  ConsumerState<WordPopup> createState() => _WordPopupState();
}

class _WordPopupState extends ConsumerState<WordPopup> {
  Unit? _unit;
  TranslateResult? _fetched;
  DictionaryEntry? _local;
  bool _loading = false;
  bool _offline = false;
  AppFailure? _error;
  bool _adding = false;
  bool _markingKnown = false;
  late final bool _contextEnabled;

  @override
  void initState() {
    super.initState();
    _contextEnabled = ref.read(settingsRepositoryProvider).contextTranslation;
    _unit = widget.initialUnit;
    Future.microtask(_load);
    if (_unit != null) {
      Future.microtask(_maybeTapRate);
    }
  }

  /// Best-effort tap-as-Again review (PLAN 7.2, SPEC 5.5).
  ///
  /// Opening the popup on a non-Known dictionary unit counts as an Again
  /// review with source `tap`, at most once per 24 h per unit. Failures
  /// are swallowed: the popup must work even when the review cannot
  /// be recorded (e.g. fake repositories in widget tests).
  Future<void> _maybeTapRate() async {
    final Unit? unit = _unit;
    if (unit == null) {
      return;
    }
    try {
      await ref.read(tapAgainPolicyProvider).maybeRate(unit);
    } catch (_) {
      // Best-effort; never break the popup.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offline = false;
      _error = null;
    });
    final DictionaryEntry? local = await _lookupDictionary();
    if (!mounted) {
      return;
    }
    setState(() {
      _local = local;
      if (local != null) {
        // The dictionary meaning is ready: show it at once, the
        // contextual line may follow from the LLM.
        _loading = false;
      }
    });
    final TranslationCache cache = ref.read(translationCacheProvider);
    final TranslateResult? cached = cache.get(widget.wordKey);
    if (cached != null) {
      setState(() {
        _fetched = cached;
        _loading = false;
      });
      return;
    }
    if (!_contextEnabled && local != null) {
      // Nothing left to fetch: the local dictionary covers the meaning.
      return;
    }
    bool online = false;
    try {
      online = await ref.read(connectivityServiceProvider).isOnline();
    } catch (_) {
      online = false;
    }
    if (!mounted) {
      return;
    }
    if (!online) {
      setState(() {
        _loading = false;
        _offline = local == null;
      });
      return;
    }
    try {
      final LlmClient llm = ref.read(llmClientProvider);
      final TranslateResult result = await completeJson(
        llm,
        buildTranslateMessages(
          widget.surface,
          widget.sentence,
          meaningLanguage: ref.read(settingsRepositoryProvider).meaningLanguage,
        ),
        validateTranslateJson,
      );
      cache.set(widget.wordKey, result);
      if (!mounted) {
        return;
      }
      setState(() {
        _fetched = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        if (local == null) {
          _error = e is AppFailure ? e : const ServerFailure();
        }
      });
    }
  }

  /// Looks up the local dictionary sources (user dictionaries, then the
  /// bundle, SPEC 5.12); a broken source just means a miss.
  Future<DictionaryEntry?> _lookupDictionary() async {
    try {
      return await ref
          .read(meaningResolverProvider)
          .dictionaryEntry(widget.wordKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _add() => _addOrMarkKnown(known: false);

  /// Marks the word Known: flips an existing unit or adds it as Known.
  Future<void> _markKnown() async {
    final Unit? unit = _unit;
    if (unit == null) {
      await _addOrMarkKnown(known: true);
      return;
    }
    if (statusOf(unit) == UnitStatus.known || _adding || _markingKnown) {
      return;
    }
    setState(() {
      _markingKnown = true;
    });
    try {
      final Unit? updated = await ref
          .read(unitRepositoryProvider)
          .setKnown(unit.id, true);
      if (!mounted) {
        return;
      }
      setState(() {
        _unit = updated ?? unit.copyWith(knownManual: true);
        _markingKnown = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _markingKnown = false;
        _error = const ServerFailure();
      });
    }
  }

  /// Fields for a new unit: the local dictionary spelling wins over the
  /// tapped surface (lookups are case-insensitive, so "Nice" must not enter
  /// the user's dictionary when the dictionary spells the word "nice"); the
  /// lemma, or the token itself, is the AI fallback (SPEC 5.5).
  /// Meanings are not stored; they resolve live (PLAN 19.1).
  ({String text, List<String> forms}) _newUnitFields() {
    final String lemma = _fetched?.lemma.trim() ?? '';
    final String dictionaryKey = _local?.textKey.trim() ?? '';
    final String text = dictionaryKey.isNotEmpty
        ? dictionaryKey
        : (lemma.isEmpty ? widget.surface.trim() : lemma);
    final String lemmaKey = normalizeKey(lemma);
    final Set<String> seen = {};
    final List<String> forms = [
      for (final String f in [widget.wordKey, lemmaKey])
        if (f.isNotEmpty && seen.add(f)) f,
    ];
    return (text: text, forms: forms);
  }

  /// Adds the word to the dictionary, optionally straight into Known.
  Future<void> _addOrMarkKnown({required bool known}) async {
    if (_unit != null || _adding || _markingKnown) {
      return;
    }
    setState(() {
      _adding = !known;
      _markingKnown = known;
    });
    try {
      final UnitRepository repo = ref.read(unitRepositoryProvider);
      final ({String text, List<String> forms}) fields = _newUnitFields();
      Unit unit;
      try {
        unit = await repo.add(
          text: fields.text.isEmpty ? widget.surface.trim() : fields.text,
          forms: fields.forms,
        );
      } catch (_) {
        final Unit? existing = await repo.findByKey(widget.wordKey);
        if (existing == null) {
          rethrow;
        }
        unit = existing;
      }
      if (known && statusOf(unit) != UnitStatus.known) {
        unit =
            await repo.setKnown(unit.id, true) ??
            unit.copyWith(knownManual: true);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _unit = unit;
        _adding = false;
        _markingKnown = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _adding = false;
        _markingKnown = false;
        _error = const ServerFailure();
      });
    }
  }

  Future<void> _speak() async {
    try {
      await ref.read(ttsServiceProvider).speak(widget.surface);
    } catch (_) {
      // Speak is best-effort; never show an error.
    }
  }

  /// Explains that the shown meaning is AI-generated (SPEC 5.5).
  void _explainAiTranslation() {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('AI-generated translation'),
          content: const Text(
            'This word is not in the bundled dictionary, so the translation '
            'was generated by the AI.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Unit? unit = _unit;
    final bool wordKnown = unit != null && statusOf(unit) == UnitStatus.known;
    final String translation;
    String? contextTranslation;
    bool aiGenerated = false;
    if (_loading) {
      translation = '';
    } else if (_local != null) {
      translation = _local!.translation;
      if (_fetched != null) {
        final String inContext = _fetched!.translationInContext;
        if (_contextEnabled && inContext != translation) {
          contextTranslation = inContext;
        }
      }
    } else if (_fetched != null) {
      translation = _fetched!.translation;
      aiGenerated = true;
      final String inContext = _fetched!.translationInContext;
      if (_contextEnabled && inContext != translation) {
        contextTranslation = inContext;
      }
    } else if (_offline) {
      translation = wordPopupOfflineMessage;
    } else if (_error != null) {
      translation = _error!.userMessage;
    } else {
      translation = '';
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.surface,
                    key: const Key('wordPopupTitle'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const Key('wordPopupSpeakButton'),
                  onPressed: _speak,
                  icon: const Icon(Icons.volume_up),
                  tooltip: 'Speak',
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      translation,
                      key: const Key('wordPopupTranslation'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  if (aiGenerated)
                    IconButton(
                      key: const Key('wordPopupAiWarning'),
                      icon: const Icon(Icons.warning_amber_rounded),
                      tooltip: 'AI-generated translation',
                      onPressed: _explainAiTranslation,
                    ),
                ],
              ),
              if (contextTranslation != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'In this sentence: $contextTranslation',
                    key: const Key('wordPopupTranslationContext'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
            ],
            const SizedBox(height: 12),
            if (_error != null && unit == null && !_offline)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    key: const Key('wordPopupRetryButton'),
                    onPressed: _load,
                    child: const Text('Retry'),
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: unit != null
                      ? OutlinedButton(
                          key: const Key('wordPopupInDictionary'),
                          onPressed: null,
                          child: const Text('In dictionary'),
                        )
                      : ElevatedButton(
                          key: const Key('wordPopupAddButton'),
                          onPressed: _adding || _markingKnown ? null : _add,
                          child: _adding
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Add to dictionary'),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              key: const Key('wordPopupMarkKnownButton'),
              onPressed: wordKnown || _adding || _markingKnown
                  ? null
                  : _markKnown,
              icon: _markingKnown
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      wordKnown
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                    ),
              label: Text(wordKnown ? 'Known' : 'Mark as known'),
            ),
          ],
        ),
      ),
    );
  }
}
