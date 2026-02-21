const ANILIST_URL = 'https://graphql.anilist.co';
const ANILIST_MIN_INTERVAL_MS = 350;
const ANILIST_MAX_RETRIES = 3;

let anilistRequestChain: Promise<void> = Promise.resolve();
let lastAniListRequestAt = 0;

type GraphQLErrorBody = {
  errors?: { message?: string }[];
  data?: any;
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function parseRetryAfterMs(retryAfter: string | null): number | null {
  if (!retryAfter) return null;
  const asNumber = Number.parseFloat(retryAfter);
  if (Number.isFinite(asNumber) && asNumber >= 0) {
    return Math.round(asNumber * 1000);
  }
  return null;
}

async function runQueuedAniListRequest<T>(runner: () => Promise<T>): Promise<T> {
  const run = anilistRequestChain.then(runner, runner);
  anilistRequestChain = run.then(
    () => undefined,
    () => undefined
  );
  return run;
}

async function anilistRequest<T>(
  query: string,
  variables: Record<string, any>,
  accessToken?: string
): Promise<T> {
  return runQueuedAniListRequest(async () => {
    for (let attempt = 0; attempt <= ANILIST_MAX_RETRIES; attempt++) {
      const elapsed = Date.now() - lastAniListRequestAt;
      if (elapsed < ANILIST_MIN_INTERVAL_MS) {
        await sleep(ANILIST_MIN_INTERVAL_MS - elapsed);
      }
      lastAniListRequestAt = Date.now();

      const res = await fetch(ANILIST_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
        },
        body: JSON.stringify({ query, variables }),
      });

      if (res.status === 429 && attempt < ANILIST_MAX_RETRIES) {
        const retryAfterMs = parseRetryAfterMs(res.headers.get('Retry-After'));
        const backoffMs =
          retryAfterMs ?? Math.round(700 * Math.pow(2, attempt) + Math.random() * 250);
        await sleep(backoffMs);
        continue;
      }

      const raw = await res.text();
      let body: GraphQLErrorBody = {};
      try {
        body = JSON.parse(raw);
      } catch {}

      if (!res.ok) {
        const msg = body?.errors?.[0]?.message || raw || `AniList HTTP ${res.status}`;
        throw new Error(msg);
      }
      if (body?.errors?.length) {
        throw new Error(body.errors[0]?.message || 'AniList GraphQL error');
      }
      return (body?.data ?? {}) as T;
    }

    throw new Error('AniList request failed after retry attempts');
  });
}

export type AniListAnime = {
  id: number;
  title: {
    romaji?: string | null;
    english?: string | null;
    native?: string | null;
  };
  averageScore?: number | null;
  status?: string | null;
  nextAiringEpisode?: {
    episode?: number | null;
  } | null;
  coverImage: {
    large: string;
    extraLarge?: string | null;
  };
  episodes?: number | null;
};

export type AniListMediaDetail = {
  id: number;
  title: {
    romaji?: string | null;
    english?: string | null;
    native?: string | null;
  };
  episodes: number | null;
  status?: string | null;
  bannerImage?: string | null;
};

export type AniListRelation = {
  relationType: string;
  node: {
    id: number;
    title: {
      romaji?: string | null;
      english?: string | null;
      native?: string | null;
    };
    coverImage?: {
      large?: string | null;
    } | null;
    format?: string | null;
    status?: string | null;
    season?: string | null;
    seasonYear?: number | null;
    episodes?: number | null;
    source?: string | null;
    averageScore?: number | null;
  };
};

export type AniListAnimeMetadata = {
  id: number;
  idMal?: number | null;
  bannerImage?: string | null;
  description?: string | null;
  format?: string | null;
  status?: string | null;
  source?: string | null;
  season?: string | null;
  seasonYear?: number | null;
  episodes?: number | null;
  duration?: number | null;
  averageScore?: number | null;
  meanScore?: number | null;
  popularity?: number | null;
  favourites?: number | null;
  genres?: string[] | null;
  studios?: string[] | null;
  startDate?: {
    year?: number | null;
    month?: number | null;
    day?: number | null;
  } | null;
  endDate?: {
    year?: number | null;
    month?: number | null;
    day?: number | null;
  } | null;
  relations?: AniListRelation[] | null;
};

export type AniListEpisodeTitleMap = Record<number, string>;
export type AniListEpisodeMetaMap = Record<
  number,
  {
    title?: string;
    thumbnail?: string;
    introStartSec?: number;
    introEndSec?: number;
  }
>;

export type AniListMediaStatus =
  | 'CURRENT'
  | 'PLANNING'
  | 'COMPLETED'
  | 'DROPPED'
  | 'PAUSED'
  | 'REPEATING';

export type AniListMediaListEntry = {
  id: number;
  progress: number;
  status: AniListMediaStatus;
  score?: number | null;
  customLists?: string[] | null;
  updatedAt?: number | null;
  media?: AniListAnime;
};

type SearchResponse = {
  data: {
    Page: {
      media: AniListAnime[];
    };
  };
};

export async function searchAnime(query: string): Promise<AniListAnime[]> {
  const graphqlQuery = `
    query ($search: String) {
      Page(perPage: 30) {
        media(search: $search, type: ANIME, sort: POPULARITY_DESC) {
          id
          title {
            romaji
            english
            native
          }
          averageScore
          coverImage {
            large
            extraLarge
          }
        }
      }
    }
  `;

  const res = await fetch(ANILIST_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      query: graphqlQuery,
      variables: { search: query },
    }),
  });

  if (!res.ok) {
    throw new Error('AniList search failed');
  }

  const json = (await res.json()) as SearchResponse;
  return json.data.Page.media;
}

type MediaDetailResponse = {
  data: {
    Media: AniListMediaDetail | null;
  };
};

export async function fetchAnimeById(anilistId: number): Promise<AniListMediaDetail | null> {
  const query = `
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        id
        title {
          romaji
          english
          native
        }
        episodes
        status
        bannerImage
      }
    }
  `;
  const res = await fetch(ANILIST_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({ query, variables: { id: anilistId } }),
  });
  if (!res.ok) return null;
  const json = (await res.json()) as MediaDetailResponse;
  return json.data.Media ?? null;
}

type MediaMetadataResponse = {
  data: {
    Media: AniListAnimeMetadata | null;
  };
};

export async function fetchAnimeMetadataById(anilistId: number): Promise<AniListAnimeMetadata | null> {
  const query = `
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        id
        idMal
        bannerImage
        description(asHtml: false)
        format
        status
        source(version: 2)
        season
        seasonYear
        episodes
        duration
        averageScore
        meanScore
        popularity
        favourites
        genres
        startDate { year month day }
        endDate { year month day }
        studios(isMain: true) {
          nodes {
            name
          }
        }
        relations {
          edges {
            relationType(version: 2)
            node {
              id
              title { romaji english native }
              coverImage { large }
              format
              status
              season
              seasonYear
              episodes
              source(version: 2)
              averageScore
            }
          }
        }
      }
    }
  `;

  try {
    const res = await fetch(ANILIST_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({ query, variables: { id: anilistId } }),
    });
    if (!res.ok) return null;
    const json = (await res.json()) as MediaMetadataResponse & {
      data?: {
        Media?: (AniListAnimeMetadata & {
          studios?: { nodes?: { name?: string | null }[] } | null;
          relations?: { edges?: AniListRelation[] } | null;
        }) | null;
      };
    };
    const media = json?.data?.Media ?? null;
    if (!media) return null;

    const studioNames = (media.studios?.nodes ?? [])
      .map((s) => String(s?.name ?? '').trim())
      .filter(Boolean);
    const relationEdges = media.relations?.edges ?? [];

    return {
      ...media,
      studios: studioNames,
      relations: relationEdges,
    };
  } catch {
    return null;
  }
}

type StreamingEpisodesResponse = {
  data: {
    Media: {
      streamingEpisodes: {
        title?: string | null;
        thumbnail?: string | null;
        url?: string | null;
        site?: string | null;
      }[];
    } | null;
  };
};

function parseEpisodeNumberFromTitle(title: string): number | null {
  const s = String(title || '').trim();
  if (!s) return null;

  const patterns = [
    /\bepisode\s*(\d+)\b/i,
    /\bep\.?\s*(\d+)\b/i,
    /\b#\s*(\d+)\b/i,
    /\b(\d+)\b/,
  ];
  for (const p of patterns) {
    const m = s.match(p);
    if (!m) continue;
    const n = Number.parseInt(m[1], 10);
    if (Number.isFinite(n) && n > 0 && n < 10000) return n;
  }
  return null;
}

function parseEpisodeNumberFromUrl(url: string): number | null {
  const s = String(url || '').trim();
  if (!s) return null;
  const patterns = [
    /[?&]ep(?:isode)?=(\d+)/i,
    /[?&]episode=(\d+)/i,
    /\/episode[-_/]?(\d+)/i,
    /[-_/](\d+)(?:\D|$)/i,
  ];
  for (const p of patterns) {
    const m = s.match(p);
    if (!m) continue;
    const n = Number.parseInt(m[1], 10);
    if (Number.isFinite(n) && n > 0 && n < 10000) return n;
  }
  return null;
}

export async function fetchAniListEpisodeMeta(
  anilistId: number
): Promise<AniListEpisodeMetaMap> {
  if (!Number.isFinite(anilistId) || anilistId <= 0) return {};
  const query = `
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        streamingEpisodes {
          title
          thumbnail
          url
          site
        }
      }
    }
  `;
  const res = await fetch(ANILIST_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({ query, variables: { id: anilistId } }),
  });
  if (!res.ok) return {};
  const json = (await res.json()) as StreamingEpisodesResponse;
  const items = Array.isArray(json?.data?.Media?.streamingEpisodes)
    ? json.data.Media.streamingEpisodes
    : [];

  const map: AniListEpisodeMetaMap = {};
  for (const item of items) {
    const rawTitle = String(item?.title ?? '').trim();
    const rawThumb = String(item?.thumbnail ?? '').trim();
    const rawUrl = String(item?.url ?? '').trim();
    const byTitle = parseEpisodeNumberFromTitle(rawTitle);
    const byUrl = parseEpisodeNumberFromUrl(rawUrl);
    const n = byTitle ?? byUrl;
    if (!n) continue;

    const prev = map[n] ?? {};
    map[n] = {
      title: prev.title || rawTitle || undefined,
      thumbnail: prev.thumbnail || rawThumb || undefined,
    };
  }
  return map;
}

const introRangeCache = new Map<string, { startSec: number; endSec: number }>();
const introRangeMissCache = new Map<string, number>();

export async function fetchAniListEpisodeIntroRange(
  anilistId: number,
  episodeNumber: number,
  episodeLengthSec?: number
): Promise<{ startSec: number; endSec: number } | null> {
  const aid = Number(anilistId);
  const ep = Math.max(1, Math.trunc(Number(episodeNumber) || 1));
  if (!Number.isFinite(aid) || aid <= 0) return null;
  const lengthHint = Math.max(0, Math.trunc(Number(episodeLengthSec) || 0));
  const cacheKey = `${aid}:${ep}`;
  if (introRangeCache.has(cacheKey)) return introRangeCache.get(cacheKey) ?? null;
  const lastMissAt = introRangeMissCache.get(cacheKey) ?? 0;
  if (Date.now() - lastMissAt < 2 * 60 * 1000) return null;

  try {
    const metadata = await fetchAnimeMetadataById(aid);
    const malId = Number(metadata?.idMal ?? 0);
    if (!Number.isFinite(malId) || malId <= 0) {
      introRangeMissCache.set(cacheKey, Date.now());
      return null;
    }
    const tryLengths = Array.from(
      new Set([lengthHint, 1440, 1500, 1320, 1800].filter((v) => Number.isFinite(v) && v > 0))
    );
    for (const len of tryLengths) {
      const url = `https://api.aniskip.com/v2/skip-times/${malId}/${ep}?types[]=op&types[]=mixed-op&episodeLength=${len}`;
      const res = await fetch(url, {
        headers: { Accept: 'application/json' },
      });
      if (!res.ok) continue;
      const json = (await res.json()) as any;
      const results = Array.isArray(json?.results) ? json.results : [];
      const opening = results.find((r: any) => {
        const t = String(r?.skipType ?? '').toLowerCase();
        return t === 'op' || t === 'mixed-op';
      });
      const start = Number(opening?.interval?.startTime ?? NaN);
      const end = Number(opening?.interval?.endTime ?? NaN);
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue;
      const value = {
        startSec: Math.max(0, start),
        endSec: Math.max(start, end),
      };
      introRangeCache.set(cacheKey, value);
      introRangeMissCache.delete(cacheKey);
      return value;
    }
    introRangeMissCache.set(cacheKey, Date.now());
    return null;
  } catch {
    introRangeMissCache.set(cacheKey, Date.now());
    return null;
  }
}

export async function fetchAniListEpisodeTitles(
  anilistId: number
): Promise<AniListEpisodeTitleMap> {
  const map: AniListEpisodeTitleMap = {};
  const meta = await fetchAniListEpisodeMeta(anilistId);
  for (const [num, item] of Object.entries(meta)) {
    const n = Number.parseInt(num, 10);
    if (!n || !item?.title) continue;
    map[n] = item.title;
  }
  return map;
}

type UpdateProgressArgs = {
  mediaId: number;
  progress: number;
  accessToken: string;
  status?: AniListMediaStatus;
};

export async function updateAniListProgress({
  mediaId,
  progress,
  accessToken,
  status,
}: UpdateProgressArgs) {
  if (!Number.isFinite(mediaId) || mediaId <= 0) {
    throw new Error('Invalid AniList media id');
  }
  const mutation = `
    mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) {
      SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status) {
        id
        progress
        status
      }
    }
  `;

  const data = await anilistRequest<{ SaveMediaListEntry: any }>(
    mutation,
    { mediaId, progress, status },
    accessToken
  );
  return { data };
}

type SetStatusArgs = {
  mediaId: number;
  status: AniListMediaStatus;
  accessToken: string;
};

export async function setAniListStatus({ mediaId, status, accessToken }: SetStatusArgs) {
  if (!Number.isFinite(mediaId) || mediaId <= 0) {
    throw new Error('Invalid AniList media id');
  }
  const mutation = `
    mutation ($mediaId: Int, $status: MediaListStatus) {
      SaveMediaListEntry(mediaId: $mediaId, status: $status) {
        id
        progress
        status
        score
        customLists(asArray: true)
      }
    }
  `;

  const data = await anilistRequest<{ SaveMediaListEntry: any }>(
    mutation,
    { mediaId, status },
    accessToken
  );
  return { data };
}

type SetScoreArgs = {
  mediaId: number;
  score: number; // 0..10 decimal
  accessToken: string;
};

export async function setAniListScore({ mediaId, score, accessToken }: SetScoreArgs) {
  if (!Number.isFinite(mediaId) || mediaId <= 0) {
    throw new Error('Invalid AniList media id');
  }
  const safe = Math.max(0, Math.min(10, score));

  const mutation = `
    mutation ($mediaId: Int, $score: Float) {
      SaveMediaListEntry(mediaId: $mediaId, score: $score) {
        id
        progress
        status
        score
        customLists(asArray: true)
      }
    }
  `;

  const data = await anilistRequest<{ SaveMediaListEntry: any }>(
    mutation,
    { mediaId, score: safe },
    accessToken
  );
  return { data };
}

type SetCustomListsArgs = {
  mediaId: number;
  customLists: string[];
  accessToken: string;
};

export async function setAniListCustomLists({
  mediaId,
  customLists,
  accessToken,
}: SetCustomListsArgs) {
  if (!Number.isFinite(mediaId) || mediaId <= 0) {
    throw new Error('Invalid AniList media id');
  }
  const mutation = `
    mutation ($mediaId: Int, $customLists: [String]) {
      SaveMediaListEntry(mediaId: $mediaId, customLists: $customLists) {
        id
        progress
        status
        score
        customLists(asArray: true)
      }
    }
  `;

  const data = await anilistRequest<{ SaveMediaListEntry: any }>(
    mutation,
    { mediaId, customLists },
    accessToken
  );
  return { data };
}

export async function deleteAniListEntry(entryId: number, accessToken: string) {
  const mutation = `
    mutation ($id: Int) {
      DeleteMediaListEntry(id: $id) {
        deleted
      }
    }
  `;

  const data = await anilistRequest<{ DeleteMediaListEntry: { deleted: boolean } }>(
    mutation,
    { id: entryId },
    accessToken
  );
  return { data };
}

type TrackingInfoResponse = {
  data: {
    Media: {
      id: number;
      episodes: number | null;
      mediaListEntry: AniListMediaListEntry | null;
    } | null;
  };
};

export async function fetchAniListTrackingInfo(
  mediaId: number,
  accessToken: string
): Promise<{ episodes: number | null; entry: AniListMediaListEntry | null }> {
  if (!Number.isFinite(mediaId) || mediaId <= 0) {
    return { episodes: null, entry: null };
  }
  const query = `
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        id
        episodes
        mediaListEntry {
          id
          progress
          status
          score
          customLists(asArray: true)
        }
      }
    }
  `;

  const data = await anilistRequest<TrackingInfoResponse['data']>(
    query,
    { id: mediaId },
    accessToken
  );
  return {
    episodes: data?.Media?.episodes ?? null,
    entry: data?.Media?.mediaListEntry ?? null,
  };
}

export async function fetchAniListCustomLists(accessToken: string): Promise<string[]> {
  const viewerQuery = `
    query {
      Viewer {
        id
      }
    }
  `;
  const viewerData = await anilistRequest<{ Viewer: { id: number } }>(
    viewerQuery,
    {},
    accessToken
  );
  const userId = viewerData?.Viewer?.id;
  if (!userId) return [];

  const listsQuery = `
    query ($userId: Int) {
      anime: MediaListCollection(userId: $userId, type: ANIME) {
        lists {
          name
          isCustomList
        }
      }
    }
  `;
  const data = await anilistRequest<{ anime: { lists: { name: string; isCustomList: boolean }[] } }>(
    listsQuery,
    { userId },
    accessToken
  );
  const lists = data?.anime?.lists ?? [];
  return lists.filter((l) => l.isCustomList).map((l) => l.name).filter(Boolean);
}

export type AniListProfile = {
  id: number;
  name: string;
  bannerImage?: string | null;
  avatar?: {
    large?: string | null;
    medium?: string | null;
  } | null;
};

type ViewerAndListsResponse = {
  data: {
    Viewer: AniListProfile;
    trending: {
      media: AniListAnime[];
    };
    releasing: {
      media: AniListAnime[];
    };
  };
};

type MediaListsResponse = {
  data: {
    anime: {
      lists: {
        name: string;
        entries: AniListMediaListEntry[];
      }[];
    };
    trending: {
      media: AniListAnime[];
    };
    releasing: {
      media: AniListAnime[];
    };
  };
};

export type HomeAniListData = {
  profile: AniListProfile;
  watching: AniListMediaListEntry[];
  planning: AniListMediaListEntry[];
  trending: AniListAnime[];
  releasing: AniListAnime[];
};

export type AniListLibrarySection = {
  name: string;
  entries: AniListMediaListEntry[];
};

export type AniListLibraryData = {
  profile: AniListProfile;
  sections: AniListLibrarySection[];
};

export type DiscoveryAniListData = {
  trending: AniListAnime[];
  releasing: AniListAnime[];
  popular: AniListAnime[];
  topRated: AniListAnime[];
};

export type AniListNotification = {
  id: number;
  type: string;
  createdAt: number;
  isRead?: boolean | null;
  context?: string | null;
  episode?: number | null;
  media?: {
    id: number;
    title: {
      romaji?: string | null;
      english?: string | null;
      native?: string | null;
    };
    coverImage?: {
      large?: string | null;
    } | null;
  } | null;
  user?: {
    id: number;
    name: string;
    avatar?: {
      large?: string | null;
    } | null;
  } | null;
};

export type AniListNotificationsData = {
  unreadCount: number;
  notifications: AniListNotification[];
  hasNextPage: boolean;
};

export async function fetchAniListNotifications(
  accessToken: string,
  page = 1,
  perPage = 30
): Promise<AniListNotificationsData> {
  const query = `
    query ($page: Int, $perPage: Int) {
      Viewer {
        unreadNotificationCount
      }
      Page(page: $page, perPage: $perPage) {
        pageInfo {
          hasNextPage
        }
        notifications {
          ... on AiringNotification {
            id
            type
            createdAt
            episode
            contexts
            media {
              id
              title { romaji english native }
              coverImage { large }
            }
          }
          ... on FollowingNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ActivityMessageNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ActivityMentionNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ActivityReplyNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ActivityReplySubscribedNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ActivityLikeNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ActivityReplyLikeNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ThreadCommentMentionNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ThreadCommentReplyNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ThreadCommentSubscribedNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ThreadCommentLikeNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on ThreadLikeNotification {
            id
            type
            createdAt
            context
            user {
              id
              name
              avatar { large }
            }
          }
          ... on RelatedMediaAdditionNotification {
            id
            type
            createdAt
            context
            media {
              id
              title { romaji english native }
              coverImage { large }
            }
          }
          ... on MediaDataChangeNotification {
            id
            type
            createdAt
            context
            media {
              id
              title { romaji english native }
              coverImage { large }
            }
          }
          ... on MediaMergeNotification {
            id
            type
            createdAt
            context
            media {
              id
              title { romaji english native }
              coverImage { large }
            }
          }
          ... on MediaDeletionNotification {
            id
            type
            createdAt
            context
          }
        }
      }
    }
  `;

  const data = await anilistRequest<{
    Viewer?: { unreadNotificationCount?: number | null } | null;
    Page?: {
      pageInfo?: { hasNextPage?: boolean | null } | null;
      notifications?: AniListNotification[] | null;
    } | null;
  }>(query, { page, perPage }, accessToken);

  return {
    unreadCount: Number(data?.Viewer?.unreadNotificationCount ?? 0),
    notifications: Array.isArray(data?.Page?.notifications) ? data.Page!.notifications! : [],
    hasNextPage: !!data?.Page?.pageInfo?.hasNextPage,
  };
}

export async function fetchHomeAniListData(accessToken: string): Promise<HomeAniListData> {
  // First query: get Viewer (user) only
  const viewerQuery = `
    query {
      Viewer {
        id
        name
        bannerImage
        avatar {
          large
          medium
        }
      }
    }
  `;

  const viewerRes = await fetch(ANILIST_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ query: viewerQuery }),
  });

  if (!viewerRes.ok) {
    const text = await viewerRes.text();
    console.warn('AniList viewer failed', viewerRes.status, text);
    return {
      profile: {
        id: 0,
        name: 'Guest',
        avatar: null,
      },
      watching: [],
      planning: [],
      trending: [],
      releasing: [],
    };
  }

  const viewerJson = (await viewerRes.json()) as { data: { Viewer: AniListProfile } };
  const profile = viewerJson.data.Viewer;

  // Second query: lists + trending + releasing, using Viewer id
  const listsQuery = `
    query ($userId: Int) {
      anime: MediaListCollection(userId: $userId, type: ANIME) {
        lists {
          name
          entries {
            id
            progress
            status
            media {
              id
              title {
                romaji
                english
                native
              }
              status
              nextAiringEpisode {
                episode
              }
              averageScore
              coverImage {
                large
                extraLarge
              }
              episodes
            }
          }
        }
      }
      trending: Page(perPage: 10) {
        media(type: ANIME, sort: TRENDING_DESC) {
          id
          title {
            romaji
            english
            native
          }
          averageScore
          coverImage {
            large
            extraLarge
          }
          episodes
        }
      }
      releasing: Page(perPage: 10) {
        media(type: ANIME, status: RELEASING, sort: POPULARITY_DESC) {
          id
          title {
            romaji
            english
            native
          }
          averageScore
          coverImage {
            large
            extraLarge
          }
          episodes
        }
      }
    }
  `;

  const res = await fetch(ANILIST_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ query: listsQuery, variables: { userId: profile.id } }),
  });

  if (!res.ok) {
    const text = await res.text();
    console.warn('AniList home data failed', res.status, text);
    // Fallback: return empty lists so the home screen still works
    return {
      profile: {
        id: 0,
        name: 'Guest',
        avatar: null,
      },
      watching: [],
      planning: [],
      trending: [],
      releasing: [],
    };
  }

  const json = (await res.json()) as MediaListsResponse;

  const lists = json.data.anime?.lists ?? [];
  const watching = lists.find((l) => l.name === 'Watching')?.entries ?? [];
  const planning = lists.find((l) => l.name === 'Planning')?.entries ?? [];

  return {
    profile,
    watching,
    planning,
    trending: json.data.trending.media,
    releasing: json.data.releasing.media,
  };
}

export async function fetchAniListLibraryData(accessToken: string): Promise<AniListLibraryData> {
  const viewer = await fetchAniListViewerProfile(accessToken);
  if (!viewer?.id) {
    return {
      profile: { id: 0, name: 'Guest', avatar: null, bannerImage: null },
      sections: [],
    };
  }

  const query = `
    query ($userId: Int) {
      anime: MediaListCollection(userId: $userId, type: ANIME) {
        lists {
          name
          entries {
            id
            progress
            status
            score
            updatedAt
            customLists(asArray: true)
            media {
              id
              title {
                romaji
                english
                native
              }
              status
              nextAiringEpisode {
                episode
              }
              averageScore
              coverImage {
                large
                extraLarge
              }
              episodes
            }
          }
        }
      }
    }
  `;

  const data = await anilistRequest<{ anime: { lists: AniListLibrarySection[] } }>(
    query,
    { userId: viewer.id },
    accessToken
  );
  const sections = (data?.anime?.lists ?? []).filter((s) => Array.isArray(s.entries) && s.entries.length > 0);
  return {
    profile: viewer,
    sections,
  };
}

export async function fetchDiscoveryAniListData(): Promise<DiscoveryAniListData> {
  const query = `
    query {
      trending: Page(perPage: 20) {
        media(type: ANIME, sort: TRENDING_DESC) {
          id
          title { romaji english native }
          averageScore
          coverImage { large extraLarge }
          episodes
        }
      }
      releasing: Page(perPage: 20) {
        media(type: ANIME, status: RELEASING, sort: POPULARITY_DESC) {
          id
          title { romaji english native }
          averageScore
          coverImage { large extraLarge }
          episodes
        }
      }
      popular: Page(perPage: 20) {
        media(type: ANIME, sort: POPULARITY_DESC) {
          id
          title { romaji english native }
          averageScore
          coverImage { large extraLarge }
          episodes
        }
      }
      topRated: Page(perPage: 20) {
        media(type: ANIME, sort: SCORE_DESC) {
          id
          title { romaji english native }
          averageScore
          coverImage { large extraLarge }
          episodes
        }
      }
    }
  `;

  const data = await anilistRequest<{
    trending: { media: AniListAnime[] };
    releasing: { media: AniListAnime[] };
    popular: { media: AniListAnime[] };
    topRated: { media: AniListAnime[] };
  }>(query, {});

  return {
    trending: data?.trending?.media ?? [],
    releasing: data?.releasing?.media ?? [],
    popular: data?.popular?.media ?? [],
    topRated: data?.topRated?.media ?? [],
  };
}

export async function fetchAniListViewerProfile(accessToken: string): Promise<AniListProfile | null> {
  const query = `
    query {
      Viewer {
        id
        name
        bannerImage
        avatar {
          large
          medium
        }
      }
    }
  `;
  try {
    const data = await anilistRequest<{ Viewer: AniListProfile }>(query, {}, accessToken);
    return data?.Viewer ?? null;
  } catch {
    return null;
  }
}
