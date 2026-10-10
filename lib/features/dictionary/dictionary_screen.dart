import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'dictionary_edit_screen.dart';
import 'dictionary_providers.dart';
import 'relative_due.dart';
import 'word_meaning.dart';

/// Dictionary list per SPEC 5.1.
///
/// Search + status chips filter through [UnitRepository.watchAll].
/// Rows show text, the resolved meaning, status chip and relative due.
/// The FAB opens the add/edit screen.
class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({super.key});

  @override
  ConsumerState<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends ConsumerState<DictionaryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  UnitStatus? _filter;

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final UnitRepository repo = ref.watch(unitRepositoryProvider);
    final Clock clock = ref.watch(clockProvider);
    final DateTime now = clock.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Dictionary')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search dictionary',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (String value) {
                setState(() {
                  _query = value;
                });
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _filterChip(label: 'All', status: null),
                _filterChip(label: 'New', status: UnitStatus.newUnit),
                _filterChip(label: 'Learning', status: UnitStatus.learning),
                _filterChip(label: 'Young', status: UnitStatus.young),
                _filterChip(label: 'Mature', status: UnitStatus.mature),
                _filterChip(label: 'Known', status: UnitStatus.known),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: StreamBuilder<List<Unit>>(
              stream: repo.watchAll(
                status: _filter,
                query: _query.isEmpty ? null : _query,
              ),
              builder: (BuildContext context, AsyncSnapshot<List<Unit>> snap) {
                if (snap.hasError) {
                  return const Center(child: Text('Something went wrong.'));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final List<Unit> units = snap.data!;
                if (units.isEmpty) {
                  final bool isFiltering =
                      _filter != null || _query.trim().isNotEmpty;
                  return Center(
                    child: Text(
                      isFiltering
                          ? 'No words found'
                          : 'Your dictionary is empty. Tap + to add a word.',
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: units.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Unit unit = units[index];
                    final UnitStatus status = statusOf(unit);
                    return ListTile(
                      title: Text(unit.text),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          WordMeaning(textKey: unit.textKey),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Chip(
                                label: Text(
                                  statusLabel(status),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  formatRelativeDue(unit.due, now),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      onTap: () => _openEdit(unit.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add word',
        onPressed: _openAdd,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _filterChip({required String label, required UnitStatus? status}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == status,
        onSelected: (bool selected) {
          setState(() {
            _filter = selected ? status : null;
          });
        },
      ),
    );
  }
}

/// English chip label for a dictionary status.
String statusLabel(UnitStatus status) {
  switch (status) {
    case UnitStatus.newUnit:
      return 'New';
    case UnitStatus.learning:
      return 'Learning';
    case UnitStatus.young:
      return 'Young';
    case UnitStatus.mature:
      return 'Mature';
    case UnitStatus.known:
      return 'Known';
  }
}
