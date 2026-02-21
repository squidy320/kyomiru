declare module '@/services/ExtensionEngine.js' {
  export type SoraExtension = {
    id?: string;
    name?: string;
    search?: string | ((query: string) => Promise<any[]> | any[]);
    getSources?: string | ((episodeId: string, meta?: any) => Promise<any[]> | any[]);
    // allow other fields
    [key: string]: any;
  };

  export function loadExtension(extJson: SoraExtension | SoraExtension[]): void;
  export function search(query: string, moduleId?: string): Promise<any[]>;
  export function fetchEpisodesForAnime(animeId: string, meta?: any): Promise<any[]>;
  export function fetchSourcesForEpisode(episodeId: string, meta?: any): Promise<any[]>;
  export function listExtensions(): Array<{id:string; name:string}>;

  const _default: {
    loadExtension: typeof loadExtension;
    search: typeof search;
    fetchEpisodesForAnime: typeof fetchEpisodesForAnime;
    fetchSourcesForEpisode: typeof fetchSourcesForEpisode;
    listExtensions: typeof listExtensions;
  };
  export default _default;
}
