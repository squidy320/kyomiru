import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/library_preferences_state.dart';

class LibraryPreferencesScreen extends ConsumerWidget {
  const LibraryPreferencesScreen({super.key});

  static const List<MapEntry<String, String>> _standardCatalogs = [
    MapEntry('current', 'Currently Watching'),
    MapEntry('planning', 'Planning'),
    MapEntry('completed', 'Completed'),
    MapEntry('paused', 'Paused'),
    MapEntry('dropped', 'Dropped'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(libraryPreferencesProvider);
    final notifier = ref.read(libraryPreferencesProvider.notifier);

    final titleById = <String, String>{
      for (final e in _standardCatalogs) e.key: e.value,
      for (final c in prefs.customCatalogs) c.id: c.title,
    };
    final ordered = <String>[
      ...prefs.catalogOrder.where(titleById.containsKey),
      ...titleById.keys.where((id) => !prefs.catalogOrder.contains(id)),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Library Preferences')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Card(
            child: ListTile(
              title: const Text('Default Sort Method'),
              trailing: DropdownButton<LibrarySortMode>(
                value: prefs.defaultSort,
                items: LibrarySortMode.values
                    .map(
                      (e) => DropdownMenuItem<LibrarySortMode>(
                        value: e,
                        child: Text(e.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  notifier.setDefaultSort(value);
                },
              ),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Default Layout'),
              trailing: SegmentedButton<LibraryLayoutMode>(
                segments: const [
                  ButtonSegment<LibraryLayoutMode>(
                    value: LibraryLayoutMode.grid,
                    label: Text('Grid'),
                    icon: Icon(Icons.grid_view_rounded),
                  ),
                  ButtonSegment<LibraryLayoutMode>(
                    value: LibraryLayoutMode.list,
                    label: Text('List'),
                    icon: Icon(Icons.view_list_rounded),
                  ),
                ],
                selected: {prefs.layoutMode},
                onSelectionChanged: (value) {
                  notifier.setLayoutMode(value.first);
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Catalog Visibility',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (final e in _standardCatalogs)
                  SwitchListTile.adaptive(
                    title: Text(e.value),
                    value: notifier.isVisible(e.key),
                    onChanged: (v) => notifier.setCatalogVisible(e.key, v),
                  ),
                for (final c in prefs.customCatalogs)
                  SwitchListTile.adaptive(
                    title: Text(c.title),
                    value: notifier.isVisible(c.id),
                    onChanged: (v) => notifier.setCatalogVisible(c.id, v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Custom Catalogs',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showCreateCatalogDialog(context, notifier),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: prefs.customCatalogs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('No custom catalogs yet.'),
                  )
                : Column(
                    children: [
                      for (final c in prefs.customCatalogs)
                        ListTile(
                          title: Text(c.title),
                          subtitle: Text('${c.mediaIds.length} items'),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              IconButton(
                                onPressed: () => _showRenameDialog(
                                  context,
                                  notifier,
                                  c.id,
                                  c.title,
                                ),
                                icon: const Icon(Icons.edit_rounded),
                              ),
                              IconButton(
                                onPressed: () => notifier.deleteCustomCatalog(
                                  c.id,
                                ),
                                icon: const Icon(Icons.delete_rounded),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Catalog Order',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Card(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: ordered.length,
              onReorder: (oldIndex, newIndex) {
                final next = List<String>.from(ordered);
                if (newIndex > oldIndex) newIndex -= 1;
                final moved = next.removeAt(oldIndex);
                next.insert(newIndex, moved);
                notifier.reorderCatalogs(next);
              },
              itemBuilder: (context, index) {
                final id = ordered[index];
                final title = titleById[id] ?? id;
                return ListTile(
                  key: ValueKey(id),
                  title: Text(title),
                  subtitle: Text(id),
                  trailing: const Icon(Icons.drag_handle_rounded),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateCatalogDialog(
    BuildContext context,
    LibraryPreferencesNotifier notifier,
  ) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Catalog'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Favorites'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await notifier.createCustomCatalog(controller.text);
    }
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    LibraryPreferencesNotifier notifier,
    String catalogId,
    String oldTitle,
  ) async {
    final controller = TextEditingController(text: oldTitle);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Catalog'),
        content: TextField(controller: controller),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await notifier.renameCustomCatalog(catalogId, controller.text);
    }
  }
}

