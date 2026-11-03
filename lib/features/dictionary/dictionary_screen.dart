import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'dictionary_edit_screen.dart';
import 'dictionary_providers.dart';
import 'dictionary_word_card.dart';

/// Dictionary list per SPEC 5.1.
///
/// Search + status chips filter through [UnitRepository.watchAll]. Rows show
/// the word, its resolved meaning, a colored status chip and the relative due
/// time. The FAB opens the add/edit screen.
class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({super.key});

  @override
  ConsumerState<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends ConsumerState<DictionaryScreen> {
  static const List<(String, UnitStatus?)> _filters = <(String, UnitStatus?)>[
    ('All', null),
    ('New', UnitStatus.newUnit),
    ('Learning', UnitStatus.learning),
    ('Young', UnitStatus.young),
    ('Mature', UnitStatus.mature),
    ('Known', UnitStatus.known),
  ];

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  UnitStatus? _filter;

  /// Refreshes the relative due labels while the screen stays open (A-50).
  Timer? _ticker;

  /// Bumped by Retry to resubscribe after a stream error (A-50).
  int _reload = 0;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _openAdd() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DictionaryEditScreen()));
  }

  void _openEdit(int unitId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DictionaryEditScreen(unitId: unitId)),
    );
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _query = '';
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final UnitRepository repo = ref.watch(unitRepositoryProvider);
    final Clock clock = ref.watch(clockProvider);
    final DateTime now = clock.now();
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      // The shell owns the keyboard inset for tab screens.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Dictionary')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search dictionary',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        key: const Key('dictionaryClearSearch'),
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: _clearSearch,
                      ),
                filled: true,
                fillColor: colors.surfaceContainerHigh,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: colors.primary, width: 1.2),
                ),
              ),
              onChanged: (String value) {
                setState(() {
                  _query = value;
                });
              },
            ),
          ),
          SizedBox(
            height: 42,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (final (String label, UnitStatus? status) in _filters)
                    _filterChip(label: label, status: status),
                ],
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<({List<Unit> units, int total})>(
              // A new key forces a fresh subscription after Retry (A-50).
              key: ValueKey<int>(_reload),
              stream: repo.watchAllWithTotal(
                status: _filter,
                query: _query.isEmpty ? null : _query,
              ),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<({List<Unit> units, int total})> snap,
                  ) {
                    if (snap.hasError) {
                      return _errorState();
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final List<Unit> units = snap.data!.units;
                    final int total = snap.data!.total;
                    final bool isFiltering =
                        _filter != null || _query.trim().isNotEmpty;
                    return Column(
                      children: [
                        _countRow(
                          units: units.length,
                          total: total,
                          isFiltering: isFiltering,
                        ),
                        Expanded(
                          child: units.isEmpty
                              ? _emptyState(isFiltering: isFiltering)
                              : ListView.builder(
                                  padding: const EdgeInsets.only(
                                    top: 4,
                                    bottom: 96,
                                  ),
                                  itemCount: units.length,
                                  itemBuilder:
                                      (BuildContext context, int index) {
                                        final Unit unit = units[index];
                                        return DictionaryWordCard(
                                          unit: unit,
                                          status: statusOf(unit),
                                          now: now,
                                          onTap: () => _openEdit(unit.id),
                                        );
                                      },
                                ),
                        ),
                      ],
                    );
                  },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'Add word',
        onPressed: _openAdd,
        icon: const Icon(Icons.add),
        label: const Text('Add word'),
      ),
    );
  }

  Widget _countRow({
    required int units,
    required int total,
    required bool isFiltering,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
      child: Row(
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 15,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            isFiltering
                ? '${formatCount(units)}/${formatCount(total)}'
                : formatWords(total),
            key: const Key('dictionaryWordCount'),
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const Spacer(),
          if (isFiltering)
            TextButton(
              key: const Key('dictionaryClearFilters'),
              onPressed: _clearFilters,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  Widget _emptyState({required bool isFiltering}) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 96),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isFiltering ? Icons.search_off : Icons.auto_stories_outlined,
                size: 30,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isFiltering ? 'No words found' : 'Your dictionary is empty',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              isFiltering
                  ? 'Try a different search or filter.'
                  : 'Add your first word to start building vocabulary.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (isFiltering)
              TextButton(
                onPressed: _clearFilters,
                child: const Text('Clear filters'),
              )
            else
              FilledButton.tonalIcon(
                onPressed: _openAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add word'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Something went wrong.'),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('dictionaryRetry'),
            onPressed: () {
              setState(() {
                _reload++;
              });
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _filterChip({required String label, required UnitStatus? status}) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool selected = _filter == status;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        selectedColor: colors.primaryContainer,
        backgroundColor: colors.surfaceContainerHigh,
        side: BorderSide(
          color: selected
              ? colors.primary.withValues(alpha: 0.5)
              : colors.outlineVariant.withValues(alpha: 0.4),
        ),
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (bool value) {
          setState(() {
            _filter = value ? status : null;
          });
        },
      ),
    );
  }
}

/// Formats a dictionary count with the locale's thousands separators.
String formatCount(int count) => NumberFormat.decimalPattern().format(count);

/// Formats a standalone word count, e.g. `1 word` or `1,204 words`.
String formatWords(int count) {
  return '${formatCount(count)} ${count == 1 ? 'word' : 'words'}';
}
