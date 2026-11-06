# Connections

## Speech recognition

Yandex SpeechKit uses asynchronous recognition with direct audio upload. Its settings include a Yandex Cloud folder ID, language, punctuation, and speaker labeling. The API key needs the service's speech-recognition permissions. The adapter requests disabled diagnostic data logging and preserves operation checkpoints for resumable polling.

ElevenLabs uses the direct `POST /v1/speech-to-text` endpoint and Scribe v2. The application sends the API key in `xi-api-key`, supports automatic, Russian, or English language selection, and can request diarization. It does not request enterprise-only zero-retention features automatically.

- [SpeechKit recognition](https://aistudio.yandex.ru/ru/docs/speechkit/stt-v3/api-ref/AsyncRecognizer/recognizeFile)
- [ElevenLabs transcription](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)

## Text models

Text processing identifies speaker names using explicit transcript evidence and optional meeting participants. It does not infer identities from voices or roster order. Model output is checked against quoted transcript turns before applying names. Manual names remain authoritative.

AI Studio requires a folder ID and a model name such as `yandexgpt/latest`. OpenRouter accepts a provider-qualified model ID. Ollama accepts a locally installed model name and defaults to `http://localhost:11434`. A remote Ollama server must use HTTPS. Arbitrary remote HTTP endpoints and credentials embedded in URLs are rejected.

Model availability depends on the configured service account. A default model name does not guarantee entitlement. Models that cannot return the required JSON response produce an error without substituting another provider.

- [AI Studio chat completions](https://aistudio.yandex.ru/en/docs/ai-studio/operations/generation/completions-basic)
- [OpenRouter API](https://openrouter.ai/docs/api_reference/overview)
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)

## Calendars

EventKit reads the calendars configured in macOS. The application requests calendar permission only after the calendar connection is enabled. It does not create or modify events. Calendar names are shown as a flat checklist. Calendar account synchronization remains controlled by macOS.

## Credentials

The default source is macOS Keychain. Enable the optional global aiw switch to resolve configured names from the inherited process environment or `aiw value NAME`. The default names are `YC_AI_STUDIO_KEY`, `ELEVENLABS_API_KEY`, and `OPENROUTER_API_KEY`. The SpeechKit and text-model AI Studio connections can use different names and separately stored manual keys.

Redirects are not followed for authenticated model requests. A failed request does not send credentials or meeting content to a different provider.
