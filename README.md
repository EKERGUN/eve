# EVE — a voice front-end for Hermes Agent

EVE is a native macOS dock app that lets you talk to [Hermes Agent](https://github.com/NousResearch/hermes-agent)
hands-free. Click the glowing orb, say **"Eve"**, follow with a command, and EVE
speaks the agent's reply back through your speakers. Say **"Eve stop"** mid-reply
and she shuts up instantly.

<p align="center">
  <img src="docs/screenshot.png" width="360" alt="EVE window">
</p>

## Features

- **Wake word "Eve"** — continuous streaming recognition via macOS's on-device
  `SFSpeechRecognizer`. Sub-300 ms latency; ignores anything you say that
  doesn't start with the wake word.
- **Barge-in** — say "Eve" again while EVE is talking and playback halts
  mid-word; the new command is sent to Hermes the moment the recognizer
  finalizes the segment.
- **Stop phrases** — "Eve stop" / "Eve dur" / "Eve sus" / "Eve shut up" and
  friends make EVE go idle without bothering Hermes.
- **Hermes owns the brain** — every command goes through `hermes chat -Q -q`
  with `--resume <session>` so the voice stream shares skills, memory, and
  tool access with the rest of your Hermes setup.
- **Auto language picker for TTS** — replies containing Turkish diacritics get
  Microsoft Edge's `tr-TR-EmelNeural`; otherwise `en-US-AriaNeural` (defaults
  are overridable).
- **Dock-pinnable** — the second toggle (Hermes power) starts `hermes dashboard`
  + `hermes gateway start` and opens the web UI. One app, one icon, one
  click for the whole thing.

## Architecture

```
 ┌── Swift (EVE.app) ────────────────────────────────────────────────┐
 │   AVAudioEngine ─► SFSpeechRecognizer (streaming, on-device)      │
 │          │                                                        │
 │          ├── RMS level ─────► SiriOrb (SwiftUI Canvas)            │
 │          └── partial text ─► wake-word matcher                    │
 │                                  │                                │
 │                       ┌──────────┴──────────┐                     │
 │                   on "Eve"            silence > 1.2s              │
 │                       │                     │                     │
 │                       ▼                     ▼                     │
 │               WS {cmd: interrupt}   WS {cmd: process, text: ...}  │
 └─────────────────────────────────────────────┬─────────────────────┘
                                               │  ws://127.0.0.1:9121
 ┌── Python bridge (voice-bridge/bridge.py) ───▼─────────────────────┐
 │   on process:                                                     │
 │     hermes chat -Q -q <text> [--resume <id>] ─► reply             │
 │     Edge TTS ─► .mp3 ─► afplay                                    │
 │   on interrupt: voice_mode.stop_playback() + bump generation      │
 └───────────────────────────────────────────────────────────────────┘
```

### Why a Python bridge?

Because `hermes chat` is a Python CLI. We considered embedding Hermes in-process
but the subprocess approach is simpler, stays compatible with upstream Hermes
releases, and keeps the Swift side pure-UI.

### Why Apple Speech (not Whisper)?

Whisper is batch — it gives you a transcript only *after* you stop talking.
For a wake-word UX you want streaming partials so "Eve" is detected mid-utterance.
`SFSpeechRecognizer` streams partial results on-device with no network round-trip
and supports Turkish + English out of the box.

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

Drag `/Applications/EVE.app` onto the Dock to pin it. The first launch triggers
two one-time permission prompts: **Microphone** and **Speech Recognition** —
grant both.

## Usage

1. Click the orb once. The green dot in the top-right turns on; the orb shows
   `LISTENING`. Live recognizer text appears beneath the orb as you speak.
2. Say **"Eve, &lt;command&gt;"** — for example:
   - "Eve, what time is it?"
   - "Eve, Slack'teki son mesajı oku." (Turkish supported)
   - "Eve, check my Telegram for new messages."
3. Hermes replies; EVE speaks it.
4. Interrupt at any time: **"Eve stop"** (stop / dur / sus / shut up / quiet /
   yeter / etc.) → playback halts, she stays idle.
5. Click the orb again to turn voice off entirely.

## Configuration

### Changing the wake word (no rebuild required)

EVE creates `~/Library/Application Support/EVE/config.json` on first launch:

```json
{
  "wake_words": ["eve", "eva", "evie", "hey eve"],
  "stop_phrases": [
    "stop", "stop it", "be quiet", "shut up", "enough",
    "dur", "sus", "yeter"
  ],
  "locale": "en-US",
  "silence_finalize_seconds": 1.2
}
```

Edit it, then quit + relaunch `EVE.app`. For example, to use **"Jarvis"**:

```bash
cat > ~/Library/Application\ Support/EVE/config.json <<'JSON'
{
  "wake_words": ["jarvis", "jarvis?", "hey jarvis"],
  "locale": "en-US"
}
JSON
osascript -e 'tell application "EVE" to quit' && sleep 1 && open /Applications/EVE.app
```

- `wake_words` — list, case-insensitive, matched on word boundaries. Longer
  variants checked first (so "hey eve" beats "eve").
- `stop_phrases` — everything in here, when heard right after the wake word,
  silences EVE without hitting Hermes.
- `locale` — any `SFSpeechRecognizer` locale id. `tr-TR` for Turkish-only,
  `en-US` for English, `de-DE` for German, etc. Mixed-language usage works
  best with `en-US` because Apple's English model tolerates accents decently;
  set to `tr-TR` only if you speak almost entirely Turkish.
- `silence_finalize_seconds` — seconds of silence after wake that triggers
  "finalize + send to Hermes". Lower = snappier, higher = more tolerant of
  pauses mid-sentence.

### Environment variables (optional)

Set before launching `EVE.app`, or bake into a LaunchAgent:

| Variable | Default | Purpose |
|----------|---------|---------|
| `HERMES_VOICE_TIMEOUT` | `180` | Max seconds to wait for `hermes chat` reply |
| `HERMES_TR_VOICE` | `tr-TR-EmelNeural` | Edge TTS voice for Turkish replies |

Everything else (TTS provider, STT providers for the fallback path, model,
keys) lives in `~/.hermes/config.yaml` — managed by the Hermes CLI, not by EVE.

## Project layout

```
eve/
├── Package.swift                          # SwiftPM executable
├── Sources/HermesToggle/
│   ├── HermesToggleApp.swift              # @main, requests mic+speech perms
│   ├── ToggleView.swift                   # window UI
│   ├── SiriOrb.swift                      # morphing orb (SwiftUI Canvas)
│   ├── IconSwapper.swift                  # live dock-icon ON/OFF swap
│   ├── HermesController.swift             # dashboard + gateway toggle
│   ├── VoiceBridge.swift                  # WS client + bridge-process lifecycle
│   └── SpeechRecognizer.swift             # SFSpeechRecognizer + wake-word matcher
├── voice-bridge/
│   └── bridge.py                          # Python WS server → hermes chat → TTS
├── build.sh                               # SwiftPM build + .app bundling + icon
├── entitlements.plist                     # mic + speech recognition entitlements
└── README.md
```

## Wake-word variants

The Swift matcher accepts these (case-insensitive, word-boundaried) to tolerate
Whisper/SFSpeechRecognizer near-misses: `eve`, `eva`, `evie`, `evy`, `hey eve`,
`hey eva`. If your speech pattern produces a different mis-hear consistently,
edit `SpeechRecognizer.findWake`.

## Stop phrases

English: `stop`, `stop it`, `stop talking`, `be quiet`, `quiet`, `shut up`,
`silence`, `shush`, `hush`, `enough`, `that's enough`.

Turkish: `dur`, `sus`, `kes`, `kes sesini`, `sessiz ol`, `yeter`, `tamam dur`.

Add more in `SpeechRecognizer._stopPhrases`.

## Troubleshooting

**EVE hears me but never replies.**
Check `~/Library/Logs/HermesToggle/voice.log`. If you see `{"cmd":"interrupt"}`
but no `{"cmd":"process"}`, the silence finalizer isn't firing — try restarting
the app or raise `silenceFinalizeSeconds` in `SpeechRecognizer.swift`.

**TTS plays only the first word.**
`afplay` doesn't decode Ogg Opus cleanly. The bridge already prefers the
sibling `.mp3` in `~/.hermes/audio_cache`. If both exist, you should be fine;
if only `.ogg` exists, `ffplay` is the fallback — make sure
`brew install ffmpeg`.

**Microphone permission keeps re-prompting.**
Ad-hoc signed apps get re-prompted after each rebuild because the signature
hash changes. Once you stop rebuilding, the grant sticks. For truly permanent
grants, sign with your Apple Developer ID.

**"hermes chat timed out after 180s".**
A tool-calling loop is probably stuck. Either kill the background chat
(`pkill -f "hermes chat"`) and retry, or cap tool loops per voice turn by
editing `call_hermes_chat` in `bridge.py` to pass `--max-turns 3`.

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — Nous Research —
  all agentic capability, memory, skills, and model routing.
- Apple's `SFSpeechRecognizer` — the streaming STT backbone.
- Microsoft Edge TTS (via `edge-tts` Python package) — neural voices.
- `faster-whisper` — earlier revisions used Whisper for STT; kept as fallback.

## License

MIT. See `LICENSE`.
