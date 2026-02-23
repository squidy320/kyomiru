import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';
import '../details/details_screen.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  List<AniListMedia> _searchResults = const [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      if (value.trim().isEmpty) {
        setState(() {
          _searchResults = const [];
          _searching = false;
        });
        return;
      }
      setState(() => _searching = true);
      try {
        final items =
            await ref.read(anilistClientProvider).searchAnime(value.trim());
        if (!mounted) return;
        setState(() {
          _searchResults = items;
          _searching = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(anilistClientProvider);
    final showingSearch = _search.text.trim().isNotEmpty;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Discovery',
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search AniList anime...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _search.clear();
                        setState(() => _searchResults = const []);
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          if (showingSearch) ...[
            if (_searching)
              const Center(child: CircularProgressIndicator())
            else if (_searchResults.isEmpty)
              const GlassCard(child: Text('No results.'))
            else
              _Grid(items: _searchResults),
          ] else
            FutureBuilder<List<AniListMedia>>(
              future: client.discoveryTrending(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return GlassCard(
                      child: Text('Discovery load failed: ${snap.error}'));
                }
                return _Grid(items: snap.data ?? const []);
              },
            ),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.items});

  final List<AniListMedia> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final item in items)
          SizedBox(
            width: 160,
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => DetailsScreen(mediaId: item.id)),
              ),
              child: GlassCard(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 190,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        image: item.cover.best != null
                            ? DecorationImage(
                                image: NetworkImage(item.cover.best!),
                                fit: BoxFit.cover,
                              )
                            : null,
                        color: const Color(0x22111111),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      item.title.best,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text('Score ${item.averageScore ?? 'N/A'}'),
                  ],
                ),
              ),
            ),
          )
      ],
    );
  }
}
