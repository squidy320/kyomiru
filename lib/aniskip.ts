export type AniSkipWindowType = 'op' | 'ed' | 'mixed-op' | 'mixed-ed' | 'recap' | 'unknown';

export type AniSkipWindow = {
  type: AniSkipWindowType;
  start: number;
  end: number;
};

const ANISKIP_API = 'https://api.aniskip.com/v2';

function toNumber(value: unknown): number | null {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

export async function fetchAniSkipWindows(
  malId: number,
  episodeNumber: number
): Promise<AniSkipWindow[]> {
  if (!Number.isFinite(malId) || malId <= 0 || !Number.isFinite(episodeNumber) || episodeNumber <= 0) {
    return [];
  }

  try {
    const url = `${ANISKIP_API}/skip-times/${Math.trunc(malId)}/${Math.trunc(episodeNumber)}?types[]=op&types[]=ed`;
    const res = await fetch(url, {
      headers: {
        Accept: 'application/json',
      },
    });
    if (!res.ok) return [];
    const json = (await res.json()) as {
      results?: Array<{
        skip_type?: string;
        interval?: {
          start_time?: number;
          end_time?: number;
        };
      }>;
    };

    const windows = (json?.results ?? [])
      .map((r) => {
        const start = toNumber(r?.interval?.start_time);
        const end = toNumber(r?.interval?.end_time);
        if (start == null || end == null || end <= start) return null;
        const rawType = String(r?.skip_type ?? '').toLowerCase();
        const type: AniSkipWindowType =
          rawType === 'op' || rawType === 'ed' || rawType === 'mixed-op' || rawType === 'mixed-ed' || rawType === 'recap'
            ? rawType
            : 'unknown';
        return { type, start, end };
      })
      .filter((w): w is AniSkipWindow => !!w);

    return windows;
  } catch {
    return [];
  }
}
