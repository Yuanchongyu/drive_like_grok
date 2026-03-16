[![English](https://img.shields.io/badge/English-Current-green)](./README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-README-blue)](./README.md)

# Drive like Grok

Turn a natural-language trip request into an ordered route and open navigation automatically. The app currently supports two modes:

- Standard route planning: say something like "Pick up my kid from school, then go to the nearest McDonald's, then go home"
- Gemini Live realtime voice: interruptible conversation, realtime transcription, tool calling, and direct jump to Google Maps

## Features

- **Voice input**: tap the mic, speak, then end; the app plans the route and opens navigation
- **Gemini Live realtime voice**: stable standard Live is the default mode and can call `plan_route` directly
- **Realtime transcripts**: the UI shows what Gemini heard from you and what Gemini is currently saying
- **Live connection testing**: test Gemini REST and Live WebSocket separately from Settings
- **Experimental affective dialog**: optional preview feature; if it fails, the app falls back to standard Live automatically
- **Natural-language parsing**: Gemini extracts ordered waypoints such as `school -> McDonald's -> home`
- **Nearest-place resolution**: with a Google Places API key, phrases like "nearest McDonald's" resolve to a specific place
- **Multi-stop routing**: current location is used as origin and waypoints are passed to Google Maps in order

## Tech Stack

- **iOS**: SwiftUI, AVFoundation, Speech, CoreLocation
- **AI**: Gemini API, Gemini Live API
- **Maps**: Google Maps app or web URL handoff
- **Optional backend**: Flask (for development or proxy-based setups)

## Before You Run

### Option A: Call APIs directly on device

- Each user enters their own API keys inside the app:
  - **Gemini API Key** (required), from [Google AI Studio](https://aistudio.google.com/app/apikey)
  - **Places API Key** (optional), for resolving "nearest" destinations into concrete places
- Keys are stored only in the local Keychain and are not uploaded
- If no Gemini key is set, the app will prompt the user to open Settings first
- Live uses **standard Gemini Live** by default for stability; **Affective Dialog** is available as an experimental toggle

### Option B: Use your own backend (development/debug)

1. Start the backend:

```bash
cd backend
pip install -r requirements.txt
export GEMINI_API_KEY="your Gemini API key"
# optional:
# export GOOGLE_PLACES_API_KEY="your Google Cloud API key"
python server.py
```

2. Leave the Gemini API key empty in the app, and it will use `planServiceBaseURL` from `ContentView.swift`
3. Change `planServiceBaseURL` to your Mac's LAN IP, for example `http://10.0.0.108:5002`

See [`backend/README.md`](./backend/README.md) for more details.

### iOS permissions

`Info.plist` already includes the required permissions for:

- Location
- Local network (only needed for Option B)
- Microphone
- Speech recognition

## Live Usage Notes

### Default behavior

- The main "Talk" button uses **standard Live** by default
- After the user finishes speaking, the model should prioritize calling `plan_route`
- When Google Maps opens, the app ends the current Live session and returns to an idle state when you come back

### What you can do in Settings

- Test **Gemini REST**
- Test **Live WebSocket**
- Toggle **Experimental: Affective Dialog**
- Configure `Places API Key`

### Current Live design choices

- `Affective Dialog` is disabled by default because `v1alpha + enableAffectiveDialog` can be unstable in some iOS direct-connect environments
- If the experimental feature fails, the app falls back to standard Live automatically
- To reduce echo / self-interruption, the app currently uses:
  - `voiceChat` audio session mode
  - local uplink gating while model audio is playing
  - local turn ending after about 3 seconds of silence

### Recommended phrases

Examples that are more likely to trigger navigation cleanly:

- `Navigate to my office, then go to the airport`
- `Plan a route: first pick up my kid from school, then go to the nearest McDonald's`
- `Take me to SFU for sunset, then find the nearest McDonald's and open the map`

## Project Structure

```text
drive_like_grok/
├── README.md
├── README.en.md
├── drive_like_grok.xcodeproj
├── drive_like_grok/
│   ├── ContentView.swift
│   ├── ApiKeySettingsView.swift
│   ├── ApiKeyStore.swift
│   ├── GeminiLiveService.swift
│   ├── GoogleMapsOpener.swift
│   ├── LiveMicCapture.swift
│   ├── LiveSessionManager.swift
│   ├── LiveWebSocketNW.swift
│   ├── LocationProvider.swift
│   ├── OnDeviceTripPlanningService.swift
│   ├── TripPlanningService.swift
│   ├── VoiceFeedbackHelper.swift
│   ├── VoiceInputHelper.swift
│   └── Info.plist
└── backend/
    ├── README.md
    ├── requirements.txt
    └── server.py
```

## Backend Environment Variables

| Variable | Required | Description |
| --- | --- | --- |
| `GEMINI_API_KEY` | Yes | Gemini API key |
| `GOOGLE_PLACES_API_KEY` or `PLACES_API_KEY` | No | Resolves "nearest/nearby" requests to specific places |
| `PORT` | No | Defaults to `5002` |
| `GEMINI_MODEL` | No | Defaults to `gemini-2.5-flash` |

## App Store Notes

- Option A is the easiest model for App Store distribution: every user brings their own Gemini / Places API key
- No backend deployment is required if you are comfortable with device-side API usage
- If you want to hide keys entirely, keep a lightweight backend proxy instead

## Possible Next Steps

- CarPlay support
- More map providers
- Further Live playback smoothing and startup latency tuning
- Better long-query confirmation and multi-turn route clarification

## License

MIT
