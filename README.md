# Kyomiru Flutter Rewrite

This folder is the Flutter replacement app for Kyomiru.

## Implemented now
- App shell with 5 tabs (Library, Discovery, Alerts, Downloads, Settings)
- AniList OAuth WebView login flow
  - token flow by default (no client secret required)
  - optional code flow if `ANILIST_CLIENT_SECRET` is provided
- AniList GraphQL client
  - viewer
  - current library entries
  - trending discovery
  - notifications
- Sora extension loader service
  - loads official AnimePahe Sora extension manifest URL

## Run
1. Install Flutter SDK on your machine.
2. From this folder:
   - `flutter pub get`
   - `flutter run`

Optional defines:
- `--dart-define=ANILIST_CLIENT_ID=36271`
- `--dart-define=ANILIST_REDIRECT_URI=kyomiru://auth`
- `--dart-define=ANILIST_CLIENT_SECRET=...` (only if you want code flow)

## Migration status
This is a real migration base, but not yet full parity with the Expo app.
Remaining high-effort parity items:
- full player parity (gestures, PiP behavior, skip-intro, resume edge cases)
- downloader parity (HLS local writer + queue + resume/cancel/delete)
- full details page and tracking UX parity
- full extension execution runtime parity

## Critical instruction
Do not delete the Expo app until Flutter parity testing passes on both Android and iOS.
