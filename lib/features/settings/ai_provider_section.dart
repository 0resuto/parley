import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'settings_providers.dart';

/// AI provider settings (SPEC 5.10).
///
/// Base URL, API key (obscured, in secure storage), model free text,
/// and a Test connection button. Shows the hint that only OpenAI-format
/// models are supported.
class AiProviderSection extends ConsumerStatefulWidget {
  const AiProviderSection({super.key});

  @override
  ConsumerState<AiProviderSection> createState() => _AiProviderSectionState();
}

class _AiProviderSectionState extends ConsumerState<AiProviderSection> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _apiKeyController;
  bool _testing = false;
  bool _loadingModels = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsRepositoryProvider);
    _baseUrlController = TextEditingController(text: settings.baseUrl);
    _modelController = TextEditingController(text: settings.model);
    _apiKeyController = TextEditingController();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final String? key = await ref.read(secureKeyStoreProvider).readApiKey();
    if (mounted) {
      _apiKeyController.text = key ?? '';
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _onKeyChanged(String value) {
    final store = ref.read(secureKeyStoreProvider);
    if (value.isEmpty) {
      store.deleteApiKey();
    } else {
      store.writeApiKey(value);
    }
  }

  /// Loads available model ids and lets the user pick one.
  ///
  /// The manual text field always stays: when the endpoint is missing,
  /// fails, or returns nothing, the user just types the model name.
  Future<void> _loadModels() async {
    if (_testing || _loadingModels) {
      return;
    }
    final String baseUrl = _baseUrlController.text.trim();
    final String apiKey = _apiKeyController.text.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      setState(() {
        _status = 'Enter the base URL and API key first.';
      });
      return;
    }
    setState(() {
      _loadingModels = true;
      _status = null;
    });
    List<String>? models;
    try {
      models = await ref
          .read(modelCatalogProvider)
          .fetchModels(baseUrl: baseUrl, apiKey: apiKey);
    } on AppFailure catch (e) {
      if (mounted) {
        setState(() {
          _status = e.userMessage;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = const ServerFailure().userMessage;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingModels = false;
        });
      }
    }
    if (!mounted || models == null) {
      return;
    }
    if (models.isEmpty) {
      setState(() {
        _status = 'No models found. Type the model name.';
      });
      return;
    }
    await _pickModel(models);
  }

  /// Shows the fetched model ids; a tap fills the model field.
  Future<void> _pickModel(List<String> models) async {
    final String? selected = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          key: const Key('modelPickerDialog'),
          title: const Text('Choose a model'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: models.length,
              itemBuilder: (BuildContext context, int index) {
                final String id = models[index];
                return ListTile(
                  key: ValueKey('modelOption_$id'),
                  title: Text(id),
                  onTap: () => Navigator.of(context).pop(id),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
    if (selected == null || !mounted) {
      return;
    }
    _modelController.text = selected;
    await ref.read(settingsRepositoryProvider).setModel(selected);
  }

  Future<void> _testConnection() async {
    if (_testing) {
      return;
    }
    setState(() {
      _testing = true;
      _status = null;
    });
    try {
      await ref.read(llmClientProvider).complete(const [
        LlmMessage(role: LlmRole.user, content: 'Hi'),
      ]);
      if (mounted) {
        setState(() {
          _status = 'Connection works.';
        });
      }
    } on AppFailure catch (e) {
      if (mounted) {
        setState(() {
          _status = e.userMessage;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = const ServerFailure().userMessage;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'AI provider',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            key: const Key('baseUrlField'),
            controller: _baseUrlController,
            decoration: const InputDecoration(labelText: 'Base URL'),
            keyboardType: TextInputType.url,
            onChanged: (String value) {
              ref.read(settingsRepositoryProvider).setBaseUrl(value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            key: const Key('apiKeyField'),
            controller: _apiKeyController,
            decoration: const InputDecoration(labelText: 'API key'),
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: _onKeyChanged,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            key: const Key('modelField'),
            controller: _modelController,
            decoration: const InputDecoration(labelText: 'Model'),
            onChanged: (String value) {
              ref.read(settingsRepositoryProvider).setModel(value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Only OpenAI-format models are supported.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              ElevatedButton(
                onPressed: _testing || _loadingModels ? null : _testConnection,
                child: const Text('Test connection'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const Key('loadModelsButton'),
                onPressed: _testing || _loadingModels ? null : _loadModels,
                child: const Text('Load models'),
              ),
              if (_testing || _loadingModels)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_status!, key: const Key('connectionStatus')),
          ),
      ],
    );
  }
}
