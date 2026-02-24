import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/glass_widgets.dart';
import '../../models/anilist_models.dart';
import '../../models/sora_models.dart';
import '../../services/download_manager.dart';
import '../../services/sora_runtime.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../player/player_screen.dart';

class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({super.key, required this.mediaId});

  final int mediaId;

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  int _tab = 0;
  final SoraRuntime _sora = SoraRuntime();
  SoraAnimeMatch? _manualMatch;
  Future<_PaheData>? _paheFuture;
  int? _paheMediaId;

  Future<_PaheData> _loadPaheData(AniListMedia media) async {
    final match = _manualMatch ?? await _sora.autoMatchTitle(media.title.best);
    if (match == null) return const _PaheData(match: null, episodes: []);
    final eps = await _sora.getEpisodes(match);
    return _PaheData(match: match, episodes: eps);
  }

  void _ensurePaheFuture(AniListMedia media) {
    if (_paheMediaId == media.id && _paheFuture != null) return;
    _paheMediaId = media.id;
    _paheFuture = _loadPaheData(media);
  }

  void _refreshPahe(AniListMedia media, {SoraAnimeMatch? manual}) {
    setState(() {
      _manualMatch = manual;
      _paheMediaId = media.id;
      _paheFuture = _loadPaheData(media);
    });
  }

  int _qualityRank(String q) {
    final m = RegExp(r'(\d+)').firstMatch(q);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  SoraSource _pickSourceByPreference(
      List<SoraSource> sources, AppSettings settings,
      {String? preferredQuality, String? preferredAudio}) {
    var pool = [...sources]..sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    final audio = (preferredAudio ?? settings.preferredAudio).toLowerCase();
    final quality =
        (preferredQuality ?? settings.preferredQuality).toLowerCase();

    if (audio != 'any') {
      final filtered =
          pool.where((s) => s.subOrDub.toLowerCase() == audio).toList();
      if (filtered.isNotEmpty) pool = filtered;
    }
    if (quality != 'auto') {
      final exact =
          pool.where((s) => s.quality.toLowerCase().contains(quality)).toList();
      if (exact.isNotEmpty) return exact.first;
    }
    return pool.isNotEmpty ? pool.first : sources.first;
  }

  Future<SoraSource?> _showSourcePicker(List<SoraSource> sources) async {
    final sorted = [...sources]..sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    return showModalBottomSheet<SoraSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Choose Stream',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              ...sorted.map((s) => ListTile(
                    title: Text('${s.quality} - ${s.subOrDub.toUpperCase()}'),
                    subtitle: Text(s.format.toUpperCase()),
                    onTap: () => Navigator.of(context).pop(s),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Future<SoraAnimeMatch?> _openManualMatchPicker(AniListMedia media) async {
    final controller = TextEditingController(text: media.title.best);
    var results = <SoraAnimeMatch>[];
    return showModalBottomSheet<SoraAnimeMatch>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text('Manual Match',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: 'Search AnimePahe title',
                      suffixIcon: IconButton(
                        onPressed: () async {
                          final r =
                              await _sora.searchAnime(controller.text.trim());
                          setModalState(() => results = r);
                        },
                        icon: const Icon(Icons.search),
                      ),
                    ),
                    onSubmitted: (value) async {
                      final r = await _sora.searchAnime(value.trim());
                      setModalState(() => results = r);
                    },
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final item = results[index];
                        return ListTile(
                          title: Text(item.title,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(item.session),
                          onTap: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(anilistClientProvider);
    final progressStore = ref.watch(progressStoreProvider);
    final downloads = ref.watch(downloadControllerProvider);

    return FutureBuilder<AniListMedia>(
      future: client.mediaDetails(widget.mediaId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || snap.data == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Details')),
            body: Center(child: Text('Failed to load details: ${snap.error}')),
          );
        }

        final media = snap.data!;
        _ensurePaheFuture(media);
        final description = (media.description ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .trim();

        return Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Header(media: media),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _TabPill(
                        label: 'Watch',
                        selected: _tab == 0,
                        onTap: () => setState(() => _tab = 0)),
                    const SizedBox(width: 8),
                    _TabPill(
                        label: 'AniList',
                        selected: _tab == 1,
                        onTap: () => setState(() => _tab = 1)),
                    const SizedBox(width: 8),
                    _TabPill(
                        label: 'More',
                        selected: _tab == 2,
                        onTap: () => setState(() => _tab = 2)),
                  ],
                ),
                const SizedBox(height: 12),
                if (_tab == 0)
                  FutureBuilder<_PaheData>(
                    future: _paheFuture,
                    builder: (context, paheSnap) {
                      if (paheSnap.connectionState == ConnectionState.waiting) {
                        return const GlassCard(
                            child: Text(
                                'Matching AnimePahe and loading episodes...'));
                      }

                      final data = paheSnap.data;
                      if (data == null ||
                          data.match == null ||
                          data.episodes.isEmpty) {
                        return GlassCard(
                          child: Row(
                            children: [
                              const Expanded(
                                  child: Text(
                                      'Could not load AnimePahe episodes for this title.')),
                              FilledButton.tonal(
                                onPressed: () => _refreshPahe(media),
                                child: const Text('Retry'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonal(
                                onPressed: () async {
                                  final manual =
                                      await _openManualMatchPicker(media);
                                  if (manual != null) {
                                    _refreshPahe(media, manual: manual);
                                  }
                                },
                                child: const Text('Manual Match'),
                              ),
                            ],
                          ),
                        );
                      }

                      final episodes = data.episodes;
                      return Column(
                        children: [
                          GlassCard(
                            child: Row(
                              children: [
                                const Icon(Icons.link),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('AnimePahe',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w800)),
                                      Text(
                                        _manualMatch == null
                                            ? 'Using automatic matching'
                                            : 'Using manual matching',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF9AA0B3)),
                                      ),
                                      Text(
                                        data.match!.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed: () async {
                                    final manual =
                                        await _openManualMatchPicker(media);
                                    if (manual != null) {
                                      _refreshPahe(media, manual: manual);
                                    }
                                  },
                                  child: const Text('Manual'),
                                ),
                                IconButton(
                                  onPressed: () => _refreshPahe(media),
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Text('Episodes',
                                  style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800)),
                              const Spacer(),
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  final settings =
                                      ref.read(appSettingsProvider);
                                  String? bulkQuality;
                                  String? bulkAudio;
                                  if (settings.chooseStreamEveryTime &&
                                      episodes.isNotEmpty) {
                                    final probeSources =
                                        await _sora.getSourcesForEpisode(
                                            episodes.first.playUrl);
                                    if (probeSources.isEmpty) return;
                                    final chosen =
                                        await _showSourcePicker(probeSources);
                                    if (chosen == null) return;
                                    bulkQuality = chosen.quality;
                                    bulkAudio = chosen.subOrDub;
                                  }
                                  for (final ep in episodes) {
                                    final local = await ref
                                        .read(
                                            downloadControllerProvider.notifier)
                                        .localManifestPath(media.id, ep.number);
                                    if (local != null) continue;
                                    final sources = await _sora
                                        .getSourcesForEpisode(ep.playUrl,
                                            anilistId: media.id,
                                            episodeNumber: ep.number);
                                    if (sources.isEmpty) continue;
                                    final selected = _pickSourceByPreference(
                                        sources, settings,
                                        preferredQuality: bulkQuality,
                                        preferredAudio: bulkAudio);
                                    await ref
                                        .read(
                                            downloadControllerProvider.notifier)
                                        .downloadHlsEpisode(
                                          mediaId: media.id,
                                          episode: ep.number,
                                          animeTitle: media.title.best,
                                          source: selected,
                                        );
                                  }
                                },
                                icon: const Icon(
                                    Icons.download_for_offline_outlined),
                                label: const Text('Download All'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ...episodes.map((ep) {
                            final p = progressStore.read(media.id, ep.number);
                            final pct = p?.percent ?? 0;
                            final streamMeta = media.streamingEpisodes
                                .where((se) =>
                                    se.guessedEpisodeNumber == ep.number)
                                .toList();
                            final thumb = streamMeta.isNotEmpty
                                ? (streamMeta.first.thumbnail ??
                                    media.cover.best)
                                : media.cover.best;
                            final episodeSubtitle = streamMeta.isNotEmpty &&
                                    streamMeta.first.title.trim().isNotEmpty
                                ? streamMeta.first.title
                                : '${media.title.best} - Episode ${ep.number}';
                            final d = downloads.item(media.id, ep.number);
                            final done = d?.status == 'done';

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: GlassCard(
                                padding: const EdgeInsets.all(10),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 84,
                                      height: 54,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        color: const Color(0x22111111),
                                        image: thumb == null
                                            ? null
                                            : DecorationImage(
                                                image: NetworkImage(thumb),
                                                fit: BoxFit.cover,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text('EP ${ep.number}',
                                              style: const TextStyle(
                                                  color: Color(0xFF8B5CF6),
                                                  fontWeight: FontWeight.w700)),
                                          const SizedBox(height: 2),
                                          Text(
                                            episodeSubtitle,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700),
                                          ),
                                          if (d != null && d.status != 'done')
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 4),
                                              child: Text(
                                                  '${d.status} ${(d.progress * 100).toStringAsFixed(0)}%'),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ProgressRing(percent: pct),
                                    const SizedBox(width: 8),
                                    Column(
                                      children: [
                                        IconButton.filledTonal(
                                          onPressed: () async {
                                            final local = await ref
                                                .read(downloadControllerProvider
                                                    .notifier)
                                                .localManifestPath(
                                                    media.id, ep.number);
                                            if (local != null) {
                                              if (!context.mounted) return;
                                              Navigator.of(context).push(
                                                MaterialPageRoute(
                                                  builder: (_) => PlayerScreen(
                                                    mediaId: media.id,
                                                    episodeNumber: ep.number,
                                                    episodeTitle:
                                                        '${media.title.best} - Episode ${ep.number}',
                                                    sourceUrl: local,
                                                    isLocal: true,
                                                  ),
                                                ),
                                              );
                                              return;
                                            }

                                            final sources = await _sora
                                                .getSourcesForEpisode(
                                                    ep.playUrl);
                                            if (sources.isEmpty) {
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                    content: Text(
                                                        'No sources found for episode.')),
                                              );
                                              return;
                                            }
                                            final settings =
                                                ref.read(appSettingsProvider);
                                            final selected =
                                                settings.chooseStreamEveryTime
                                                    ? await _showSourcePicker(
                                                        sources)
                                                    : _pickSourceByPreference(
                                                        sources, settings);
                                            if (selected == null) return;
                                            if (!context.mounted) return;
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) => PlayerScreen(
                                                  mediaId: media.id,
                                                  episodeNumber: ep.number,
                                                  episodeTitle:
                                                      '${media.title.best} - Episode ${ep.number}',
                                                  sourceUrl: selected.url,
                                                  headers: selected.headers,
                                                ),
                                              ),
                                            );
                                          },
                                          icon: const Icon(Icons.play_arrow),
                                        ),
                                        const SizedBox(height: 4),
                                        if (d?.status == 'downloading')
                                          IconButton.filledTonal(
                                            onPressed: () => ref
                                                .read(downloadControllerProvider
                                                    .notifier)
                                                .cancel(media.id, ep.number),
                                            icon: const Icon(Icons.close),
                                          )
                                        else if (done)
                                          IconButton.filledTonal(
                                            onPressed: () => ref
                                                .read(downloadControllerProvider
                                                    .notifier)
                                                .delete(media.id, ep.number),
                                            icon: const Icon(
                                                Icons.delete_outline),
                                          )
                                        else
                                          IconButton.filledTonal(
                                            onPressed: () async {
                                              final sources = await _sora
                                                  .getSourcesForEpisode(
                                                      ep.playUrl);
                                              if (sources.isEmpty) return;
                                              final settings =
                                                  ref.read(appSettingsProvider);
                                              final selected =
                                                  settings.chooseStreamEveryTime
                                                      ? await _showSourcePicker(
                                                          sources)
                                                      : _pickSourceByPreference(
                                                          sources, settings);
                                              if (selected == null) return;
                                              await ref
                                                  .read(
                                                      downloadControllerProvider
                                                          .notifier)
                                                  .downloadHlsEpisode(
                                                    mediaId: media.id,
                                                    episode: ep.number,
                                                    animeTitle:
                                                        media.title.best,
                                                    source: selected,
                                                  );
                                            },
                                            icon: const Icon(
                                                Icons.download_rounded),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  ),
                if (_tab == 1)
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(media.title.best,
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text(description.isEmpty
                            ? 'No description.'
                            : description),
                      ],
                    ),
                  ),
                if (_tab == 2)
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Status: ${media.status ?? 'N/A'}'),
                        Text('Score: ${media.averageScore ?? 'N/A'}'),
                        Text('Episodes: ${media.episodes ?? 'N/A'}'),
                        const SizedBox(height: 8),
                        FilledButton.tonalIcon(
                          onPressed: media.siteUrl == null
                              ? null
                              : () => Share.share(media.siteUrl!,
                                  subject: media.title.best),
                          icon: const Icon(Icons.share),
                          label: const Text('Share AniList'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.media});

  final AniListMedia media;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            height: 220,
            decoration: BoxDecoration(
              image: media.bannerImage != null
                  ? DecorationImage(
                      image: NetworkImage(media.bannerImage!),
                      fit: BoxFit.cover,
                    )
                  : null,
              color: const Color(0xAA0C1324),
            ),
          ),
        ),
        Container(
          height: 220,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x44000000), Color(0xCC050712)],
            ),
          ),
        ),
        Positioned.fill(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 110,
                height: 150,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  image: media.cover.best == null
                      ? null
                      : DecorationImage(
                          image: NetworkImage(media.cover.best!),
                          fit: BoxFit.cover),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  media.title.best,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF8B5CF6) : const Color(0x66141B2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : null)),
      ),
    );
  }
}

class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.percent});

  final double percent;

  @override
  Widget build(BuildContext context) {
    final value = percent.clamp(0, 1).toDouble();
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const CircularProgressIndicator(
            value: 1,
            strokeWidth: 5,
            valueColor: AlwaysStoppedAnimation(Color(0x334A556B)),
          ),
          CircularProgressIndicator(
            value: value,
            strokeWidth: 5,
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
          Center(
            child: Text('${(value * 100).round()}%',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _PaheData {
  const _PaheData({required this.match, required this.episodes});

  final SoraAnimeMatch? match;
  final List<SoraEpisode> episodes;
}
