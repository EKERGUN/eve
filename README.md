# EVE — a voice front-end for Hermes Agent

EVE is a native macOS dock app that lets you talk to [Hermes Agent](https://github.com/NousResearch/hermes-agent)
hands-free. Click the glowing orb, say **"Eve"** followed by a request, and EVE
speaks the agent's reply back through your speakers. Keep the conversation
going without repeating "Eve" for every turn.

<p align="center">
  <img src="docs/screenshot.png" width="360" alt="EVE window">
</p>

## Features

- **Wake word "Eve"** — continuous streaming recognition via macOS's on-device
  `SFSpeechRecognizer`. Sub-300 ms latency; ignores anything you say that
  doesn't start with the wake word. Apple's language model is biased toward
  the wake word at the request level (`contextualStrings`) so short names like
  "Eve" are reliably caught.
- **Continuous conversation mode** — once "Eve" has been heard, subsequent
  utterances don't need the wake word. EVE stays in conversation until you
  say a stop phrase ("stop", "be quiet", "dur", "sus", etc.) or stay silent
  for 2 minutes.
- **Configurable wake word, stop phrases, and locale** at runtime via a JSON
  file — swap "Eve" for "Jarvis", "Computer", or anything else without
  rebuilding.
- **Hermes owns the brain** — every command goes through `hermes chat` with
  `--resume <session>`, so the voice stream shares skills, memory, and tool
  access with the rest of your Hermes setup. Unlimited tool iterations per
  turn (180 s hard timeout as the only guard-rail).
- **Auto language picker for TTS** — replies containing Turkish diacritics get
  Microsoft Edge's `tr-TR-EmelNeural`; otherwise `en-US-AriaNeural` (defaults
  are overridable).
- **Echo guard** — while EVE is thinking or speaking, wake detection is
  suppressed so her own voice bleeding through the mic can't fake-wake her.
- **Dock-pinnable** — a second toggle in the window starts `hermes dashboard`
  + `hermes gateway start` and opens the web UI. One app, one icon, one
  click for the whole thing.

## Architecture

```
 ┌── Swift (EVE.app) ────────────────────────────────────────────────┐
 │   AVAudioEngine ─► SFSpeechRecognizer (streaming, on-device)      │
 │          │                                                        │
 │          ├── RMS level ─────► SiriOrb (SwiftUI Canvas)            │
 │          └── partial text ─► wake-word matcher + cursor           │
 │                                  │                                │
 │                       ┌──────────┴───────────┐                    │
 │                   wake "Eve"         silence > N sec              │
 │                       │                      │                    │
 │                       ▼                      ▼                    │
 │                WS {cmd: interrupt}    WS {cmd: process, text}     │
 └─────────────────────────────────────────────┬─────────────────────┘
                                               │  ws://127.0.0.1:9121
 ┌── Python bridge (voice-bridge/bridge.py) ───▼─────────────────────┐
 │   on process:                                                     │
 │     hermes chat -Q -q <text> [--resume <id>]  ─► reply            │
 │     Edge TTS ─► .mp3 ─► afplay (ffplay fallback for ogg)          │
 │   on interrupt: voice_mode.stop_playback() + bump generation      │
 └───────────────────────────────────────────────────────────────────┘
```

### Why a Python bridge?

Because `hermes chat` is a Python CLI. Embedding Hermes in-process was
considered but the subprocess path stays compatible with upstream Hermes
releases without patching it, and keeps the Swift side purely UI + mic.

### Why Apple Speech (not Whisper)?

Whisper is batch — it gives you a transcript only *after* you stop talking.
For a wake-word UX you want streaming partials so "Eve" is detected
mid-utterance. `SFSpeechRecognizer` streams partial results on-device with no
network round-trip and supports 50+ languages including English + Turkish.

## Prerequisites

- macOS 13 (Ventura) or newer — on-device recognition requires modern macOS.
- Apple Silicon or Intel Mac. Tested on M4 Mac mini, 16 GB.
- Xcode command-line tools (`xcode-select --install`).
- `ffmpeg` (`brew install ffmpeg`).

### Hermes Agent (the brain)

EVE is only a voice front-end. The agentic work — answering, using skills,
browsing, reading Telegram, etc. — happens inside Hermes Agent, which you
install and configure yourself:

```bash
# 1. Install Hermes
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.zshrc

# 2. Run the setup wizard — pick a provider, log in, write config.yaml.
hermes setup
# or manually:
hermes model          # pick provider + model
hermes login <provider>

# 3. Make TTS work locally for free (Microsoft Edge neural voices, no key).
hermes config set tts.provider edge

# 4. Sanity check
hermes chat -Q -q "Say ok and nothing else."
```

**EVE never touches your API keys.** It shells out to your local `hermes`
binary, which reads `~/.hermes/.env` and `~/.hermes/config.yaml`. Whatever
provider and credentials you set up for Hermes become the provider EVE
speaks to. Your `~/.hermes/` directory stays entirely on your machine.

## Build

```bash
git clone https://github.com/EKERGUN/eve.git
cd eve
./build.sh
cp -R EVE.app /Applications/
open /Applications/EVE.app
```

Drag `/Applications/EVE.app` onto the Dock to pin it. The first launch
triggers two one-time permission prompts: **Microphone** and **Speech
Recognition** — grant both.

## Usage

1. Click the orb once. The green dot in the top-right turns on; status shows
   `LISTENING`. Live recognizer text appears under the orb as you speak.
2. Say **"Eve, &lt;command&gt;"** — for example:
   - "Eve, what time is it?"
   - "Eve, check my Telegram for new messages."
   - "Eve, Slack'teki son mesajı oku." (Turkish supported)
3. Hermes replies; EVE speaks it. Status updates to `THINKING` → `SPEAKING`.
4. **Keep talking without "Eve"** — while status shows `LISTENING · CHAT`
   (continuous conversation mode), your next utterance goes straight to
   Hermes. Say:
   - "Tell me a joke."
   - "What's the capital of Japan?"
5. **Exit the conversation** by saying any stop phrase (`stop`, `be quiet`,
   `shut up`, `enough`, `dur`, `sus`, `yeter`, …). Wake word required again
   to start the next conversation.
6. Click the orb again to turn voice off entirely.

## Configuration

### `~/Library/Application Support/EVE/config.json`

EVE writes a starter config on first launch. Edit it, quit + relaunch the
app — no rebuild needed.

```json
{
  "wake_words": ["eve", "eva", "evie", "hey eve"],
  "stop_phrases": [
    "stop", "stop it", "be quiet", "shut up", "enough",
    "dur", "sus", "yeter"
  ],
  "locale": "en-US",
  "wake_locale": "en-US",
  "silence_finalize_seconds": 3.0
}
```

| Key | Purpose |
|-----|---------|
| `wake_words` | List, case-insensitive, word-boundaried. Longer variants checked first (so `"hey eve"` beats `"eve"`). |
| `stop_phrases` | Matched after normalizing (adjacent duplicates collapsed, so `"stop stop stop"` still matches). |
| `locale` | `SFSpeechRecognizer` locale for command transcription (`en-US`, `tr-TR`, `de-DE`, etc.). |
| `wake_locale` | Optional — separate locale for wake-word detection only. Useful if your accent makes the command locale mis-hear the wake word (e.g. `locale: en-US`, `wake_locale: tr-TR`). Defaults to `locale`. |
| `silence_finalize_seconds` | Silence after speech before the utterance is sent to Hermes. Default 3.0. Lower = snappier, higher = more tolerant of pauses. |

Example: switch to **"Jarvis"**:

```bash
cat > ~/Library/Application\ Support/EVE/config.json <<'JSON'
{
  "wake_words": ["jarvis", "hey jarvis"],
  "locale": "en-US",
  "silence_finalize_seconds": 3.0
}
JSON
osascript -e 'tell application "EVE" to quit' && sleep 1 && open /Applications/EVE.app
```

### Environment variables (optional)

Set before launching `EVE.app`, or bake into a LaunchAgent:

| Variable | Default | Purpose |
|----------|---------|---------|
| `HERMES_VOICE_TIMEOUT` | `180` | Max seconds to wait for a `hermes chat` reply |
| `HERMES_TR_VOICE` | `tr-TR-EmelNeural` | Edge TTS voice for Turkish replies |

Everything else (TTS provider, STT providers for the fallback path, model,
keys) lives in `~/.hermes/config.yaml` — managed by the Hermes CLI, not by
EVE.

## Project layout

```
eve/
├── Package.swift                          # SwiftPM executable
├── Sources/HermesToggle/
│   ├── HermesToggleApp.swift              # @main, requests mic + speech perms
│   ├── ToggleView.swift                   # window UI
│   ├── SiriOrb.swift                      # morphing orb (SwiftUI Canvas)
│   ├── IconSwapper.swift                  # live dock-icon ON/OFF swap
│   ├── HermesController.swift             # dashboard + gateway power toggle
│   ├── VoiceBridge.swift                  # WS client + bridge-process lifecycle
│   └── SpeechRecognizer.swift             # SFSpeechRecognizer + wake/stop matcher
├── voice-bridge/
│   └── bridge.py                          # Python WS server → hermes chat → TTS
├── build.sh                               # SwiftPM build + .app bundling + icon
├── entitlements.plist                     # mic + speech recognition entitlements
└── README.md
```

## Known limitations

- **No acoustic barge-in.** When EVE is speaking, her own voice bleeds into
  the mic through the speakers, which would cause her to fake-wake herself.
  The current guard is to suppress wake detection while she's talking, which
  means you **can't** interrupt her by saying "Eve stop" mid-reply. To cut
  her off, click the orb or wait for her to finish. A real fix requires a
  full `AVAudioEngine` graph with an output node + voice processing for
  hardware echo cancellation — planned for a later revision. Headphones
  sidestep the problem entirely today.
- **Ad-hoc signature re-prompts for permissions** whenever you rebuild. See
  Troubleshooting.
- **Cold first turn** — `hermes chat` spawns a fresh Python interpreter per
  turn, so the first turn after launch can take 10-15 s. Follow-up turns
  typically land in 3-6 s.

## Troubleshooting

**EVE hears me but never replies.**
Tail the Swift log and the bridge log side by side:

```bash
tail -F ~/Library/Logs/HermesToggle/swift.log
tail -F ~/Library/Logs/HermesToggle/voice.log
```

If partials stream but no `FIRE command` line appears, the wake word isn't
matching — check what Apple transcribed and add that spelling to
`wake_words` in your config. If `FIRE command` fires but the bridge log
shows no `{"cmd":"process"}`, the WebSocket is broken — quit and relaunch.

**Wake word rarely catches.**
Apple's English model can mis-hear short non-English names. Options:
1. Add the common mis-hears (e.g. `"if"`, `"you"`) to `wake_words` — but
   avoid words so common they fire on every English sentence.
2. Add a `wake_locale` distinct from `locale` (e.g. `wake_locale: tr-TR`
   if your accent is closer to Turkish) — EVE will run a second
   recognizer in parallel whose only job is wake detection.
3. Pick a wake word Apple catches reliably: "Jarvis", "Aria", "Ava",
   "Computer", "Nova".

**TTS plays only the first word.**
`afplay` doesn't decode Ogg Opus cleanly on macOS. The bridge already
prefers the sibling `.mp3` in `~/.hermes/audio_cache`; if both exist you're
fine. If only `.ogg` exists, `ffplay` is the fallback — make sure
`brew install ffmpeg`.

**Microphone / Speech Recognition permission keeps re-prompting.**
Ad-hoc signed apps get re-prompted after each rebuild because the signature
hash changes. Once you stop rebuilding, the grant sticks. For truly
permanent grants, sign with your Apple Developer ID.

**"hermes chat timed out after 180s".**
Hermes got stuck in a tool loop. Kill it (`pkill -f "hermes chat"`) and
retry, or set `HERMES_VOICE_TIMEOUT=60` in the environment to fail faster.

**EVE answers her own voice.**
Shouldn't happen with the current guard, but if it does, the "echo guard"
isn't engaging. Check `swift.log` for `suppressWake` state transitions
around TTS start. Until full AEC lands, a quick workaround is using
headphones or a directional mic.

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — Nous Research
  — all agentic capability, memory, skills, and model routing.
- Apple's `SFSpeechRecognizer` — the streaming STT backbone.
- Microsoft Edge TTS (via the `edge-tts` Python package) — neural voices.

## License

MIT. See `LICENSE`.
