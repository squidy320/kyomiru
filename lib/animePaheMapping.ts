import * as SecureStore from 'expo-secure-store';

const STORAGE_KEY = 'animepahe_manual_mappings_v1';

export type AnimePaheManualMapping = {
  anilistId?: number;
  titleKey?: string;
  sessionId: string;
  animePaheTitle?: string;
  updatedAt: number;
};

type MappingStore = {
  byAniListId: Record<string, AnimePaheManualMapping>;
  byTitle: Record<string, AnimePaheManualMapping>;
};

export function normalizeAnimeTitleKey(input: string): string {
  return String(input || '')
    .toLowerCase()
    .trim()
    .replace(/[^\w\s]/g, '')
    .replace(/\s+/g, ' ');
}

async function readStore(): Promise<MappingStore> {
  try {
    const raw = await SecureStore.getItemAsync(STORAGE_KEY);
    if (!raw) {
      return { byAniListId: {}, byTitle: {} };
    }
    const parsed = JSON.parse(raw) as Partial<MappingStore>;
    return {
      byAniListId: parsed?.byAniListId && typeof parsed.byAniListId === 'object' ? parsed.byAniListId : {},
      byTitle: parsed?.byTitle && typeof parsed.byTitle === 'object' ? parsed.byTitle : {},
    };
  } catch {
    return { byAniListId: {}, byTitle: {} };
  }
}

async function writeStore(store: MappingStore): Promise<void> {
  await SecureStore.setItemAsync(STORAGE_KEY, JSON.stringify(store));
}

export async function getAnimePaheManualMapping(
  anilistId: number | null | undefined,
  title: string
): Promise<AnimePaheManualMapping | null> {
  const store = await readStore();
  if (Number.isFinite(anilistId) && (anilistId as number) > 0) {
    const key = String(anilistId);
    if (store.byAniListId[key]?.sessionId) {
      return store.byAniListId[key];
    }
  }
  const titleKey = normalizeAnimeTitleKey(title);
  if (titleKey && store.byTitle[titleKey]?.sessionId) {
    return store.byTitle[titleKey];
  }
  return null;
}

export async function setAnimePaheManualMapping(params: {
  anilistId?: number | null;
  title: string;
  sessionId: string;
  animePaheTitle?: string;
}): Promise<void> {
  const sessionId = String(params.sessionId || '').trim();
  if (!sessionId) return;

  const store = await readStore();
  const titleKey = normalizeAnimeTitleKey(params.title);
  const value: AnimePaheManualMapping = {
    anilistId: Number.isFinite(params.anilistId) ? Number(params.anilistId) : undefined,
    titleKey: titleKey || undefined,
    sessionId,
    animePaheTitle: params.animePaheTitle,
    updatedAt: Date.now(),
  };

  if (Number.isFinite(params.anilistId) && (params.anilistId as number) > 0) {
    store.byAniListId[String(params.anilistId)] = value;
  }
  if (titleKey) {
    store.byTitle[titleKey] = value;
  }
  await writeStore(store);
}

export async function clearAnimePaheManualMapping(
  anilistId: number | null | undefined,
  title: string
): Promise<void> {
  const store = await readStore();
  if (Number.isFinite(anilistId) && (anilistId as number) > 0) {
    delete store.byAniListId[String(anilistId)];
  }
  const titleKey = normalizeAnimeTitleKey(title);
  if (titleKey) {
    delete store.byTitle[titleKey];
  }
  await writeStore(store);
}

export async function getAllAnimePaheManualMappings(): Promise<MappingStore> {
  return readStore();
}
