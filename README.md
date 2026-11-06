# Bad Meeting

Bad Meeting is a native macOS application for recording meetings, transcribing speech, identifying speakers from transcript evidence, and showing calendar reminders.

Requires macOS 14.2 or later. The initial downloadable build targets Apple Silicon. The source uses Apple frameworks and has no third-party package dependencies.

## Connections

- Speech recognition: Yandex SpeechKit (AI Studio), followed by direct ElevenLabs Scribe v2.
- Text processing: Yandex AI Studio, OpenRouter, and Ollama.
- Calendars: calendars available to macOS through EventKit. Add accounts in macOS first, then enable calendar access and select calendars in the application.

Each provider retains its own settings. Keys entered in the application are saved to macOS Keychain. An optional global aiw switch is available in Advanced; aiw is disabled by default and is not needed to build or run the application. In that mode, each connection uses a configurable key name and shows only a masked resolved value.

Selecting a hosted provider sends the recording or transcript to that provider when processing is requested. Automatic speaker naming uses the selected text provider after transcription. Ollama connects to a local installation by default. The application does not fall back to another provider.

## Build and test

Install Xcode or the Apple Command Line Tools with Swift 6 or later.

```sh
desktop/macos/scripts/test.sh
desktop/macos/scripts/build-app.sh
```

The application is written to `desktop/macos/dist/Bad Meeting.app`. Local updates replace that bundle. Signing defaults to ad hoc. To use a signing identity already installed on the build machine, set `BAD_MEETING_SIGNING_IDENTITY`. `BAD_MEETING_SDK` can select a compatible installed SDK.

An ad-hoc signed download is not notarized by Apple. Source builds and the release archive contain the same application code. Microphone, application audio, and calendar access are granted through macOS permissions.

## Data

Recordings are stored locally under `~/Library/Application Support/BadMeeting`. Each recording has a JSON manifest and audio segments. Calendar snapshots and selected calendars remain local. New manually entered keys are never written to preferences or recording files.

## Development

Feature branches start from `dev`. Completed changes are integrated into `dev`; `main` contains releases. Versions use `X.Y.Z`. Related editions and platform clients share `X.Y`; their build number `Z` can advance independently.

See [connections](docs/connections.md), [architecture](docs/architecture.md), and the [MIT license](LICENSE).
