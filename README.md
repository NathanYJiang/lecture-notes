# Lecture Notes

Menu bar app: Record → Stop → on-device transcript → AI notes you can paste anywhere (or, once Google sign-in is set up, a new Google Doc in a Drive folder you pick).

Needs macOS 26+ (uses Apple's on-device `SpeechAnalyzer`).

## Build & run

```bash
./build.sh            # builds build/LectureNotes.app
./build.sh --install  # also copies to /Applications and launches it
./package.sh          # builds build/LectureNotes-<version>.dmg (drag-to-Applications installer)
```

Design check without clicking around: `swift build && .build/debug/LectureNotes --snapshot /some/dir` renders each pane to PNG. The offscreen renderer can't draw native text fields and pickers, so those show as yellow placeholders.

Run `scripts/make-dev-cert.sh` once so local builds keep the same signing identity. Without it, builds are ad-hoc signed and macOS re-asks for mic and Keychain access after every rebuild.

First run: macOS asks for the mic when you first record. The on-device speech model downloads in the background at launch; if you record before it's ready, audio is still captured and the transcript is made from the audio after Stop. "Mic + system audio" also needs Screen & System Audio Recording permission (System Settings → Privacy & Security), and the app may need a relaunch after granting it.

Recordings, transcripts, and `notes.md` are saved under `~/Library/Application Support/LectureNotes/Recordings/<timestamp>/`. If any step fails, hit **Retry**. It reuses the saved transcript.

## Saving to Google Docs

- **Without Google sign-in** (the default until a client ID is set up): when notes are ready, hit **Copy notes** and paste into Google Docs, Notion, Apple Notes, anywhere. Headings, bullets, bold and italics come through. Notes are also saved as `notes.md` and `notes.html` on your Mac.
- **With Google sign-in** (once `google-client-id.txt` exists, see below): one click to sign in, and each lecture becomes a Doc in your chosen Drive folder automatically.

## Testing onboarding

`scripts/reset-new-user.sh` makes this Mac look like a fresh install. It moves recordings to the Desktop, then clears settings, the saved AI key, Google sign-in, and mic permission. It asks before doing anything.

## Shipping to other people

1. Join the Apple Developer Program ($99/yr) and create a **Developer ID Application** certificate.
2. Run `xcrun notarytool store-credentials notary --apple-id you@x.com --team-id TEAMID` once.
3. Run `SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary ./package.sh`. This signs with the hardened runtime, notarizes, and staples, so the DMG opens with no Gatekeeper warning.

Google sign-in is built but turned off until you do the one-time setup below; until then the app shows "Coming soon" and uses copy & paste. Once set up, users just click **Sign in with Google**. The app uses the `drive.file` scope, so it can only see files and folders it creates. That's a non-sensitive scope, so Google requires no paid security review, only a quick brand verification before you publish.

## One-time Google setup (developer only, ~5 min)

Do this once. Every user then signs in with one click.

1. Go to https://console.cloud.google.com and create a project (e.g. "Lecture Notes").
2. **APIs & Services → Library**: enable **Google Drive API**.
3. **Google Auth Platform → Branding**: set the app name, support email, and logo. **Audience**: choose External. While testing, add yourself as a test user.
4. **Data Access**: add the scope `https://www.googleapis.com/auth/drive.file`.
5. **Clients → Create client**: set the type to **iOS** and the bundle ID to `com.nathanjiang.LectureNotes`. Copy the client ID.
6. Run `echo "<client id>" > google-client-id.txt` in this folder, then `./build.sh --install`. The file is gitignored, and build.sh bakes the ID into the app.

Apps in "Testing" lose their refresh tokens every 7 days, and only test users can sign in. When you're ready, use **Audience → Publish app** and submit brand verification. This is a few days of review, and `drive.file` needs no security assessment.

## AI providers

Default is **Gemini (free)**, using the `gemini-flash-latest` alias so it always gets Google's newest free Flash model. Overloads and dropped connections are retried with backoff. If the model is still overloaded or has been retired, the app asks Google which Flash models your key can use and tries the newest ones, then `gemini-flash-lite-latest`. You can pick another provider in settings and bring your own key:

| Provider | Notes |
|---|---|
| Claude | Default `claude-opus-5-5`, about $0.10 per hour-long lecture. `claude-haiku-5-5` costs a fraction of a cent. Get a key at https://console.anthropic.com/settings/keys |
| Gemini (default) | Free, no card. Get a key at https://aistudio.google.com/apikey. Free-tier prompts may be used by Google for training |
| OpenRouter | Has free models (the `:free` suffix). Check https://openrouter.ai/models?q=free for current names |
| DeepSeek / OpenAI | Cheap and paid |
| Ollama | Local and free, no key. Run `ollama pull qwen3:8b`. Raise its context length (`OLLAMA_CONTEXT_LENGTH=32768`) so a full lecture fits |
| Custom | Any OpenAI-compatible `/chat/completions` endpoint |

You can edit the model names, since free model lineups change often.

## Topic & key terms

Type hints like `merge sort, divide and conquer, O(n log n)` in the Record tab, before or during a lecture. They do two things:
- They become custom vocabulary for the on-device speech recognizer, so it's more likely to hear "merge sort" instead of "merch sort".
- They go to the AI as context, so it can correct terms the recognizer still gets wrong.
