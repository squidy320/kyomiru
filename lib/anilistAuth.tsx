import React, { createContext, useContext, useState, useEffect, ReactNode, useRef } from 'react';
import * as WebBrowser from 'expo-web-browser';
import * as SecureStore from 'expo-secure-store';
import { Alert, Platform } from 'react-native';
import Constants from 'expo-constants';
import * as Linking from 'expo-linking';
import { getAllAnimePaheManualMappings } from '@/lib/animePaheMapping';

// Required for Expo AuthSession
WebBrowser.maybeCompleteAuthSession();

type AniListAuthContextType = {
  accessToken: string | null;
  login: () => Promise<void>;
  logout: () => void;
  clearAllAuthData: () => Promise<void>;
};

const AniListAuthContext = createContext<AniListAuthContextType | undefined>(undefined);

// AniList OAuth client ID for this app.
// Use your own app ID via EXPO_PUBLIC_ANILIST_CLIENT_ID when possible.
const ANILIST_CLIENT_ID = String(process.env.EXPO_PUBLIC_ANILIST_CLIENT_ID ?? '36271').trim();

const ANILIST_AUTH_ENDPOINT = 'https://anilist.co/api/v2/oauth/authorize';
const ANILIST_TOKEN_ENDPOINT = 'https://anilist.co/api/v2/oauth/token';
const ANILIST_CLIENT_SECRET = String(process.env.EXPO_PUBLIC_ANILIST_CLIENT_SECRET ?? '').trim();

type ProviderProps = {
  children: ReactNode;
};

export function AniListAuthProvider({ children }: ProviderProps) {
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const loginInFlightRef = useRef(false);

  useEffect(() => {
    // Load saved token on startup
    (async () => {
      try {
        const saved = await SecureStore.getItemAsync('anilist_token');
        if (saved) {
          setAccessToken(saved);
        }
      } catch (e) {
        console.error('Failed to load AniList token', e);
      }
    })();
  }, []);

  const parseParamsFromUrl = (url: string) => {
    const out = new URLSearchParams();
    const queryIndex = url.indexOf('?');
    const hashIndex = url.indexOf('#');
    const query =
      queryIndex >= 0 ? url.slice(queryIndex + 1, hashIndex >= 0 ? hashIndex : undefined) : '';
    const hash = hashIndex >= 0 ? url.slice(hashIndex + 1) : '';
    const apply = (part: string) => {
      if (!part) return;
      const params = new URLSearchParams(part);
      params.forEach((v, k) => {
        if (v != null && v !== '') out.set(k, v);
      });
    };
    apply(query);
    apply(hash);
    return out;
  };

  const exchangeCodeForToken = async (code: string, redirectUri: string) => {
    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: ANILIST_CLIENT_ID,
      client_secret: ANILIST_CLIENT_SECRET,
      redirect_uri: redirectUri,
      code,
    }).toString();
    const response = await fetch(ANILIST_TOKEN_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body,
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message =
        String(payload?.message ?? payload?.error_description ?? payload?.error ?? '').trim() ||
        `HTTP ${response.status}`;
      throw new Error(message);
    }
    const token = String(payload?.access_token ?? '').trim();
    if (!token) throw new Error('No access token returned from AniList token endpoint.');
    return token;
  };

  const login = async () => {
    if (loginInFlightRef.current) return;
    loginInFlightRef.current = true;
    try {
      // If already signed in, treat this as "switch account":
      // wipe local auth state before opening AniList auth again.
      if (accessToken) {
        setAccessToken(null);
        await SecureStore.deleteItemAsync('anilist_token').catch(() => {});
      }

      const executionEnvironment = String((Constants as any)?.executionEnvironment ?? '').toLowerCase();
      const isExpoGo = executionEnvironment === 'storeclient';
      const useCodeFlow = !!ANILIST_CLIENT_SECRET;
      const redirectCandidates = ['kyomiru://auth'];
      const tryLoginWithRedirect = async (redirectUri: string) => {
        let callbackUrl: string | null = null;
        let resolveCallback:
          | ((value: { type: 'success'; url: string }) => void)
          | null = null;
        const callbackPromise = new Promise<{ type: 'success'; url: string }>((resolve) => {
          resolveCallback = resolve;
        });
        const linkingSub = Linking.addEventListener('url', ({ url }) => {
          if (typeof url === 'string' && url.length > 0 && url.startsWith(redirectUri)) {
            callbackUrl = url;
            resolveCallback?.({ type: 'success', url });
          }
        });
        const state = Math.random().toString(36).slice(2);

        const authParams = new URLSearchParams();
        authParams.set('client_id', ANILIST_CLIENT_ID);
        authParams.set('response_type', useCodeFlow ? 'code' : 'token');
        authParams.set('state', state);
        authParams.set('redirect_uri', redirectUri);
        const authUrl = `${ANILIST_AUTH_ENDPOINT}?${authParams.toString()}`;
        try {
          const timeoutPromise = new Promise<{ type: 'timeout' }>((resolve) =>
            setTimeout(() => resolve({ type: 'timeout' }), 45000)
          );
          let result: any;
          try {
            // Prefer AuthSession on both platforms so we can resolve cancel/dismiss cleanly.
            result = await Promise.race([
              WebBrowser.openAuthSessionAsync(authUrl, redirectUri, {
                preferEphemeralSession: false,
              } as any),
              callbackPromise,
              timeoutPromise,
            ]);
          } catch {
            // Android fallback if custom-tab auth session is unavailable on device ROM/browser.
            if (Platform.OS !== 'android') throw new Error('Auth session failed');
            await Linking.openURL(authUrl);
            result = await Promise.race([callbackPromise, timeoutPromise]);
          }

          if (!callbackUrl) {
            await new Promise((resolve) => setTimeout(resolve, 700));
          }
          if ((result?.type === 'dismiss' || result?.type === 'cancel') && callbackUrl) {
            result = { type: 'success', url: callbackUrl } as any;
          }
          if (result?.type === 'timeout' && callbackUrl) {
            result = { type: 'success', url: callbackUrl } as any;
          }

          if (result.type !== 'success' || !result.url) {
            if (result.type === 'cancel' || result.type === 'dismiss') {
              return { ok: false as const, canceled: true as const };
            }
            if (result.type === 'timeout') {
              return {
                ok: false as const,
                canceled: false as const,
                error:
                  'AniList login timed out before callback. Try again or confirm redirect URI is registered.',
              };
            }
            return {
              ok: false as const,
              canceled: false as const,
              error: 'Login did not complete. Please try again.',
            };
          }

          const params = parseParamsFromUrl(result.url);
          const returnedState = params.get('state');
          if (returnedState && returnedState !== state) {
            return {
              ok: false as const,
              canceled: false as const,
              error: 'Login state mismatch. Please try again.',
            };
          }
          const errorCode = String(params.get('error') ?? '').trim();
          const errorMessage = String(params.get('message') ?? params.get('error_description') ?? '').trim();
          if (errorCode) {
            return {
              ok: false as const,
              canceled: false as const,
              errorCode,
              error: errorMessage || errorCode || 'Login failed.',
            };
          }
          if (!useCodeFlow) {
            const token = String(params.get('access_token') ?? '').trim();
            if (!token) {
              return {
                ok: false as const,
                canceled: false as const,
                error:
                  isExpoGo
                    ? `No access token was returned in Expo Go. Confirm AniList redirect URI is exactly ${redirectUri}.`
                    : `No access token was returned. Confirm AniList redirect URI is exactly ${redirectUri}.`,
              };
            }
            return { ok: true as const, token };
          }

          const code = String(params.get('code') ?? '').trim();
          if (!code) {
            return {
              ok: false as const,
              canceled: false as const,
              error:
                isExpoGo
                  ? `No OAuth code was returned in Expo Go. Confirm AniList redirect URI is exactly ${redirectUri}.`
                  : `No OAuth code was returned. Confirm AniList redirect URI is exactly ${redirectUri}.`,
            };
          }
          try {
            const token = await exchangeCodeForToken(code, redirectUri);
            return { ok: true as const, token };
          } catch (exchangeError: any) {
            return {
              ok: false as const,
              canceled: false as const,
              errorCode: 'token_exchange_failed',
              error: `Token exchange failed: ${String(exchangeError?.message ?? exchangeError)}`,
            };
          }
        } finally {
          linkingSub.remove();
        }
      };

      let lastError = 'Login failed. Please verify AniList OAuth app settings.';
      let canceled = false;
      for (const redirectUri of redirectCandidates) {
        const attempt = await tryLoginWithRedirect(redirectUri);
        if (attempt.ok) {
          setAccessToken(attempt.token);
          try {
            await SecureStore.setItemAsync('anilist_token', attempt.token);
          } catch (e) {
            console.error('Failed to save AniList token', e);
          }
          return;
        }
        if (attempt.canceled) {
          canceled = true;
          break;
        }
        lastError = attempt.error;
        if (
          attempt.errorCode &&
          attempt.errorCode.toLowerCase() !== 'unsupported_grant_type'
        ) {
          // For non-grant errors, don't keep retrying with another redirect.
          break;
        }
      }
      if (!canceled) Alert.alert('AniList Login', lastError);
    } catch (e) {
      console.error(e);
      Alert.alert('AniList Login', 'Unexpected login error. Please try again.');
    } finally {
      loginInFlightRef.current = false;
    }
  };

  const clearAllAuthData = async () => {
    setAccessToken(null);

    let mappingIds: string[] = [];
    try {
      const mappings = await getAllAnimePaheManualMappings();
      const ids = new Set<string>();
      const addId = (id: unknown) => {
        const parsed = Number(id);
        if (Number.isFinite(parsed) && parsed > 0) ids.add(String(parsed));
      };
      Object.values(mappings.byAniListId ?? {}).forEach((m) => addId(m?.anilistId));
      Object.values(mappings.byTitle ?? {}).forEach((m) => addId(m?.anilistId));
      mappingIds = Array.from(ids);
    } catch {}

    const keysToDelete = ['anilist_token', 'animepahe_manual_mappings_v1'];
    keysToDelete.push(...mappingIds.map((aid) => `anilist_custom_lists:${aid}`));
    await Promise.all(keysToDelete.map((key) => SecureStore.deleteItemAsync(key).catch(() => {})));
  };

  const logout = () => {
    setAccessToken(null);
    SecureStore.deleteItemAsync('anilist_token').catch(() => {});
  };

  return (
    <AniListAuthContext.Provider value={{ accessToken, login, logout, clearAllAuthData }}>
      {children}
    </AniListAuthContext.Provider>
  );
}

export function useAniListAuth() {
  const ctx = useContext(AniListAuthContext);
  if (!ctx) {
    throw new Error('useAniListAuth must be used within AniListAuthProvider');
  }
  return ctx;
}



