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
import 'package:parley/services/tts/tts_service.dart';
import 'package:parley/services/tutor/tap_again_policy.dart';

/// Shown when the tapped word has no dictionary unit and the device is
/// offline (SPEC 5.5, exact string).
const String wordPopupOfflineMessage = 'Translation isn\'t available offline.';

/// Verbatim system prompt for translation (SPEC 6.3).
const String translateSystemPrompt =
    'You are a precise English-Russian dictionary. Output ONLY JSON: '
    '{"lemma":"...","translation_ru":"...","translation_in_context":"...","pos":"noun|verb|adj|adv|phrase|other"}. '
    'lemma is the base form of the word as used in the sentence. '
    'translation_ru is the main dictionary meaning: 1-3 short Russian equivalents '
    'separated by commas that describe the word itself, as a dictionary does. '
    'translation_in_context is 1-3 short Russian equivalents matching the meaning '
    'in the given sentence; use the same text as translation_ru when the meanings match. '
    'pos is the part of speech.';

/// Builds the non-streaming translate request (SPEC 6.3).
List<LlmMessage> buildTranslateMessages(String surface, String sentence) {
  return [
    const LlmMessage(role: LlmRole.system, content: translateSystemPrompt),
    LlmMessage(
      role: LlmRole.user,
      content: 'Word: $surface\nSentence: $sentence',
    ),
  ];
}

/// In-memory translate cache for one app session (SPEC 5.5).
class TranslationCache {
  final Map<String, TranslateResult> _entries = {};

  TranslateResult? get(String key) => _entries[key];

  void set(String key, TranslateResult value) {
    _entries[key] = value;
  }
}

/// Cache provider (one instance per app session).
final translationCacheProvider = Provider<TranslationCache>((ref) {
  return TranslationCache();
});

/// Bundled dictionary lookups (SPEC 5.11).
///
/// Defaults to an empty service so tests and startup before `main()`'s
/// override never crash; every word then falls back to the LLM.
final dictionaryServiceProvider = Provider<DictionaryService>((ref) {
  return EmptyDictionaryService();
});

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
  DictionaryEntry? _bundle;
  bool _loading = false;
  bool _offline = false;
  AppFailure? _error;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _unit = widget.initialUnit;
    if (_unit == null) {
      Future.microtask(_load);
    } else {
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
    final DictionaryEntry? bundle = await _lookupBundle();
    final TranslationCache cache = ref.read(translationCacheProvider);
    final TranslateResult? cached = cache.get(widget.wordKey);
    if (!mounted) {
      return;
    }
    if (cached != null) {
      setState(() {
        _fetched = cached;
        _bundle = bundle;
        _loading = false;
      });
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
        _bundle = bundle;
        _offline = bundle == null;
      });
      return;
    }
    try {
      final LlmClient llm = ref.read(llmClientProvider);
      final TranslateResult result = await completeJson(
        llm,
        buildTranslateMessages(widget.surface, widget.sentence),
        validateTranslateJson,
      );
      cache.set(widget.wordKey, result);
      if (!mounted) {
        return;
      }
      setState(() {
        _fetched = result;
        _bundle = bundle;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _bundle = bundle;
        if (bundle == null) {
          _error = e is AppFailure ? e : const ServerFailure();
        }
      });
    }
  }

  /// Looks up the bundled dictionary; a broken bundle just means a miss.
  Future<DictionaryEntry?> _lookupBundle() async {
    try {
      return await ref.read(dictionaryServiceProvider).lookup(widget.wordKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _add() async {
    if (_unit != null || _adding) {
      return;
    }
    setState(() {
      _adding = true;
    });
    try {
      final UnitRepository repo = ref.read(unitRepositoryProvider);
      final String lemma = _fetched?.lemma.trim() ?? '';
      final String dictionary =
          (_bundle?.translation ?? _fetched?.translationRu ?? '').trim();
      late final String text;
      late final String translationRu;
      late final List<String> forms;
      if (lemma.isEmpty) {
        text = widget.surface.trim();
        translationRu = dictionary;
        forms = [widget.wordKey];
      } else {
        text = lemma;
        translationRu = dictionary;
        final String lemmaKey = normalizeKey(lemma);
        final List<String> raw = [widget.wordKey, lemmaKey];
        final Set<String> seen = {};
        forms = [
          for (final String f in raw)
            if (f.isNotEmpty && seen.add(f)) f,
        ];
      }
      try {
        final Unit created = await repo.add(
          text: text.isEmpty ? widget.surface.trim() : text,
          translationRu: translationRu,
          forms: forms,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _unit = created;
          _adding = false;
        });
      } catch (_) {
        final Unit? existing = await repo.findByKey(widget.wordKey);
        if (!mounted) {
          return;
        }
        if (existing != null) {
          setState(() {
            _unit = existing;
            _adding = false;
          });
        } else {
          setState(() {
            _adding = false;
            _error = const ServerFailure();
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _adding = false;
          _error = const ServerFailure();
        });
      }
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
    final String translation;
    String? contextTranslation;
    bool aiGenerated = false;
    if (unit != null) {
      translation = unit.translationRu.isEmpty
          ? '(no translation)'
          : unit.translationRu;
    } else if (_loading) {
      translation = '';
    } else if (_fetched != null) {
      translation = _bundle?.translation ?? _fetched!.translationRu;
      aiGenerated = _bundle == null;
      final String inContext = _fetched!.translationInContext;
      if (inContext != translation) {
        contextTranslation = inContext;
      }
    } else if (_bundle != null) {
      translation = _bundle!.translation;
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
            Text(
              widget.surface,
              key: const Key('wordPopupTitle'),
              style: Theme.of(context).textTheme.titleLarge,
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
                          onPressed: _adding ? null : _add,
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
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('wordPopupSpeakButton'),
                    onPressed: _speak,
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Speak'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
