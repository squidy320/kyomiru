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
    _debounce = Timer(const Duration(milliseconds: 320), () async {
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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          const Text('Discovery',
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.all(10),
            child: TextField(
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
          ),
          const SizedBox(height: 14),
          if (showingSearch) ...[
            if (_searching)
              const Center(child: CircularProgressIndicator())
            else if (_searchResults.isEmpty)
              const GlassCard(child: Text('No results.'))
            else
              _HorizontalSection(
                title: 'SEARCH RESULTS',
                items: _searchResults,
              ),
          ] else
            FutureBuilder<List<AniListDiscoverySection>>(
              future: client.discoverySections(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return GlassCard(
                      child: Text('Discovery load failed: ${snap.error}'));
                }
                final sections = snap.data ?? const [];
                return Column(
                  children: [
                    for (final section in sections)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _HorizontalSection(
                          title: section.title,
                          items: section.items,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _HorizontalSection extends StatelessWidget {
  const _HorizontalSection({required this.title, required this.items});

  final String title;
  final List<AniListMedia> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            TextButton(onPressed: () {}, child: const Text('View All')),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 250,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: 148,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => DetailsScreen(mediaId: item.id)),
                  ),
                  child: GlassCard(
                    padding: const EdgeInsets.all(6),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: item.cover.best == null
                                ? Container(color: const Color(0x22111111))
                                : Image.network(item.cover.best!,
                                    fit: BoxFit.cover),
                          ),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xAA2A3248),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              item.averageScore?.toString() ?? 'NR',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: Text(
                            item.title.best,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 6)
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
