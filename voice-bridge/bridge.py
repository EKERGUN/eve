#!/usr/bin/env python3
"""Hermes Voice Bridge — mic → STT → hermes chat → TTS, driven over WS.

Usage:
    bridge.py                       # WebSocket server on 127.0.0.1:9121
    bridge.py --once                # single-turn smoke test, no WS
    bridge.py --port 9121 --silence-duration 1.5

Events emitted (server → client, JSON line per WS message):
    {"event":"state","value":"idle|listening|transcribing|thinking|speaking|error"}
    {"event":"level","rms":0.0..1.0}
    {"event":"transcript","text":"..."}
    {"event":"reply","text":"..."}
    {"event":"error","message":"..."}

Commands (client → server):
    {"cmd":"start"}       # begin the listen→respond loop
    {"cmd":"stop"}        # stop looping after current turn
    {"cmd":"interrupt"}   # abort current TTS playback
    {"cmd":"quit"}        # shut down the bridge
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

HERMES_ROOT = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
HERMES_AGENT = HERMES_ROOT / "hermes-agent"
HERMES_BIN_CANDIDATES = [
    Path.home() / ".local" / "bin" / "hermes",
    Path("/usr/local/bin/hermes"),
    Path("/opt/homebrew/bin/hermes"),
]

# Voice bridge delegates agentic work to Hermes. Only STT (Whisper) and TTS
# (Edge) run locally; the reply comes from `hermes chat`.
WHISPER_MODEL = os.environ.get("HERMES_VOICE_WHISPER", "small")
HERMES_CHAT_TIMEOUT = int(os.environ.get("HERMES_VOICE_TIMEOUT", "180"))

# Turkish letters used to pick the TTS voice
_TR_CHARS = set("çğıöşüÇĞİÖŞÜ")

def _ensure_hermes_agent_layout() -> None:
    """Verify the configured Hermes Agent path exists and looks valid before
    we splice it onto sys.path. A bad HERMES_HOME otherwise produces a
    cryptic ModuleNotFoundError, and sys.path.insert on a non-existent or
    user-writable directory is a code-injection footgun.
    """
    if not HERMES_AGENT.is_dir():
        sys.stderr.write(
            f"FATAL: hermes-agent not found at {HERMES_AGENT}\n"
            f"Set HERMES_HOME to the directory containing hermes-agent/.\n"
        )
        sys.exit(2)
    if not (HERMES_AGENT / "tools").is_dir():
        sys.stderr.write(
            f"FATAL: {HERMES_AGENT} is missing the tools/ subdirectory; "
            f"this does not look like a hermes-agent install.\n"
        )
        sys.exit(2)


_ensure_hermes_agent_layout()
sys.path.insert(0, str(HERMES_AGENT))

from tools import voice_mode  # noqa: E402
from tools import transcription_tools  # noqa: E402
from tools import tts_tool  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("voice-bridge")

SESSION_STATE_FILE = HERMES_ROOT / "voice_bridge_session.json"
SESSION_ID_RE = re.compile(r"^session_id:\s*(\S+)\s*$", re.MULTILINE)


def find_hermes_bin() -> str:
    for p in HERMES_BIN_CANDIDATES:
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    found = shutil.which("hermes")
    if found:
        return found
    raise RuntimeError("hermes binary not found")


def load_voice_session_id() -> Optional[str]:
    try:
        data = json.loads(SESSION_STATE_FILE.read_text())
        return data.get("session_id")
    except Exception:
        return None


def save_voice_session_id(session_id: str) -> None:
    try:
        SESSION_STATE_FILE.write_text(json.dumps({"session_id": session_id}))
    except Exception as e:
        log.warning("failed to persist session id: %s", e)


VOICE_STYLE_PREAMBLE = (
    "[Voice mode. Reply in 1-3 short spoken sentences, no markdown, no lists, "
    "no URLs, no code, no headings. Maximum 50 words.] "
)


def call_hermes_chat(text: str, session_id: Optional[str]) -> tuple[str, Optional[str]]:
    """Delegate to Hermes agent for the reply. Returns (reply_text, session_id).

    First turn: spawns `hermes chat -Q -q <text>` which creates a new session
    and prints `session_id: <id>\\n<reply>`. Subsequent turns resume the same
    session via `--resume <id>`, giving Hermes full memory + tool access.

    The user text is prepended with a short voice-style instruction so
    replies stay speakable — keeps EVE from reading out long URL-laden
    paragraphs through the speakers.
    """
    hermes = find_hermes_bin()
    # No explicit --max-turns cap: rely on the 180s subprocess timeout to
    # prevent runaway loops instead. This avoids the "max iterations (N)"
    # warnings on complex tool-using queries.
    # --accept-hooks auto-approves shell-script hooks (terminal, web tools)
    # since there's no TTY for an interactive prompt in voice mode.
    cmd = [hermes, "chat", "-Q", "-q", VOICE_STYLE_PREAMBLE + text,
           "--accept-hooks"]
    if session_id:
        cmd += ["--resume", session_id]
    log.info("hermes chat (resume=%s)", session_id or "-")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=HERMES_CHAT_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"hermes chat timed out after {HERMES_CHAT_TIMEOUT}s")
    if proc.returncode != 0:
        raise RuntimeError(f"hermes chat failed ({proc.returncode}): {proc.stderr.strip()[:400]}")

    out = proc.stdout
    m = SESSION_ID_RE.search(out)
    new_sid = m.group(1) if m else session_id
    reply = SESSION_ID_RE.sub("", out).strip()
    if not reply:
        reply = "(empty reply)"
    return reply, new_sid


def looks_turkish(text: str) -> bool:
    return any(c in _TR_CHARS for c in text)


class VoiceLoop:
    """Drives the listen→transcribe→chat→speak loop. Threadsafe-ish."""

    def __init__(self, emit, silence_duration: float = 1.5, silence_threshold: int = 200):
        self.emit = emit  # callable(event_dict) — pushes to WS
        self.silence_duration = silence_duration
        self.silence_threshold = silence_threshold
        self._running = False
        self._stop_requested = False
        self._level_thread: Optional[threading.Thread] = None
        self._recorder = None
        self._level_stop = threading.Event()
        # Hermes-side session id — persisted across bridge lifetimes so voice
        # can resume where you last left off.
        self._session_id = load_voice_session_id()
        # Track the current TTS/hermes background thread for barge-in.
        self._speak_thread: Optional[threading.Thread] = None
        # `_speak_generation` is bumped on each new request so in-flight
        # workers can detect they've been superseded. The counter is read
        # from worker threads while interrupt()/process() write it from the
        # WS handler thread, so all access goes through `_gen_lock`.
        # A Python `int +=` is read-modify-write at the bytecode level —
        # without the lock concurrent bumps could be lost.
        self._gen_lock = threading.Lock()
        self._speak_generation = 0

    def _emit(self, **kw):
        try:
            self.emit(kw)
        except Exception as e:
            log.debug("emit failed: %s", e)

    def _bump_generation(self) -> int:
        with self._gen_lock:
            self._speak_generation += 1
            return self._speak_generation

    def _is_current(self, gen: int) -> bool:
        with self._gen_lock:
            return gen == self._speak_generation

    def _level_pump(self, recorder):
        """Poll recorder.current_rms and emit ~30 Hz."""
        self._level_stop.clear()
        while not self._level_stop.is_set() and recorder.is_recording:
            rms = getattr(recorder, "current_rms", 0) or 0
            # Normalize int16 RMS (0..32767) with a soft curve that feels lively.
            norm = min(1.0, (rms / 4000.0))
            self._emit(event="level", rms=round(norm, 3))
            time.sleep(0.033)
        self._emit(event="level", rms=0.0)

    def start(self):
        log.info("VoiceLoop.start called — Swift owns the mic now; bridge is command-driven")
        self._running = True
        self._emit(event="state", value="listening")

    def stop(self):
        self._stop_requested = True
        self._running = False
        self.interrupt()

    def interrupt(self):
        """Barge-in from Swift: stop any active TTS + mark current reply as superseded."""
        self._bump_generation()
        try:
            voice_mode.stop_playback()
        except Exception as e:
            log.warning("stop_playback failed: %s", e)

    def process(self, text: str):
        """Handle a final command coming from Swift's speech recognizer."""
        if not text or not text.strip():
            return
        log.info("process: %r", text[:120])
        # Bump generation first — any in-flight reply from a prior command is abandoned.
        gen = self._bump_generation()
        # Also stop any current playback so the new request starts clean.
        try:
            voice_mode.stop_playback()
        except Exception:
            pass

        def _worker(user_text: str, my_gen: int):
            try:
                self._emit(event="state", value="thinking")
                reply, new_sid = call_hermes_chat(user_text, self._session_id)
                if not self._is_current(my_gen):
                    return
                if new_sid and new_sid != self._session_id:
                    self._session_id = new_sid
                    save_voice_session_id(new_sid)
                self._emit(event="reply", text=reply)
                self._emit(event="state", value="speaking")
                self._speak(reply, my_gen)
            except Exception as e:
                log.exception("reply worker crashed")
                self._emit(event="error", message=f"hermes: {e}")
            finally:
                if self._is_current(my_gen):
                    self._emit(event="state", value="listening")

        t = threading.Thread(target=_worker, args=(text, gen), daemon=True)
        self._speak_thread = t
        t.start()

    def _speak(self, reply: str, my_gen: int) -> None:
        """Generate TTS + play, checking for barge-in between stages."""
        override_voice = None
        if looks_turkish(reply):
            override_voice = os.environ.get("HERMES_TR_VOICE", "tr-TR-EmelNeural")

        def _do_tts() -> str:
            if override_voice:
                import hermes_cli.config as _hc
                orig_load = _hc.load_config
                def _patched_load():
                    cfg = orig_load()
                    tts = dict(cfg.get("tts") or {})
                    edge = dict(tts.get("edge") or {})
                    edge["voice"] = override_voice
                    tts["edge"] = edge
                    cfg["tts"] = tts
                    return cfg
                _hc.load_config = _patched_load
                try:
                    return tts_tool.text_to_speech_tool(reply)
                finally:
                    _hc.load_config = orig_load
            return tts_tool.text_to_speech_tool(reply)

        res_json = _do_tts()
        if not self._is_current(my_gen):
            return  # barge-in already happened

        res = json.loads(res_json) if isinstance(res_json, str) else res_json
        audio_path = (res or {}).get("file_path")
        if audio_path and audio_path.endswith(".ogg"):
            mp3_sibling = audio_path[:-4] + ".mp3"
            if Path(mp3_sibling).is_file():
                audio_path = mp3_sibling
        if audio_path and Path(audio_path).is_file():
            played = voice_mode.play_audio_file(audio_path)
            if not played and shutil.which("ffplay"):
                subprocess.run(["ffplay", "-nodisp", "-autoexit",
                                "-loglevel", "quiet", audio_path],
                               check=False)
        else:
            self._emit(event="error", message=f"TTS produced no file: {res}")


# -------------------- WebSocket server --------------------


async def ws_server(host: str, port: int, silence_duration: float, silence_threshold: int):
    import websockets

    clients: set = set()
    emit_queue: asyncio.Queue = asyncio.Queue()
    loop = asyncio.get_running_loop()

    def emit(evt: dict):
        try:
            loop.call_soon_threadsafe(emit_queue.put_nowait, evt)
        except RuntimeError:
            pass

    voice = VoiceLoop(emit=emit,
                      silence_duration=silence_duration,
                      silence_threshold=silence_threshold)

    async def broadcaster():
        while True:
            evt = await emit_queue.get()
            if not clients:
                continue
            msg = json.dumps(evt)
            dead = []
            for ws in list(clients):
                try:
                    await ws.send(msg)
                except Exception:
                    dead.append(ws)
            for d in dead:
                clients.discard(d)

    async def handler(ws):
        log.info("client connected: %s", ws.remote_address)
        clients.add(ws)
        try:
            await ws.send(json.dumps({"event": "state", "value": "idle"}))
            async for raw in ws:
                log.info("ws recv: %r", raw)
                try:
                    msg = json.loads(raw)
                except Exception as e:
                    log.warning("bad json: %s", e)
                    continue
                cmd = msg.get("cmd")
                log.info("cmd=%s", cmd)
                if cmd == "start":
                    voice.start()
                elif cmd == "stop":
                    voice.stop()
                elif cmd == "interrupt":
                    voice.interrupt()
                elif cmd == "process":
                    text = msg.get("text", "")
                    voice.process(text)
                elif cmd == "quit":
                    voice.stop()
                    asyncio.get_event_loop().stop()
        except Exception as e:
            log.exception("handler error: %s", e)
        finally:
            log.info("client disconnected")
            clients.discard(ws)

    log.info("voice bridge listening on ws://%s:%d", host, port)
    async with websockets.serve(handler, host, port, ping_interval=None):
        await broadcaster()


# -------------------- One-shot smoke test --------------------


def run_once(silence_duration: float, silence_threshold: int):
    def pretty(evt):
        print(json.dumps(evt), flush=True)

    loop = VoiceLoop(emit=pretty,
                     silence_duration=silence_duration,
                     silence_threshold=silence_threshold)
    print("Speak now. Silence will stop the recording.", file=sys.stderr)
    loop.start()
    while loop._running:
        time.sleep(0.1)


# -------------------- main --------------------


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9121)
    ap.add_argument("--silence-duration", type=float, default=1.5)
    ap.add_argument("--silence-threshold", type=int, default=200)
    ap.add_argument("--once", action="store_true", help="single-turn smoke test, no WS")
    args = ap.parse_args()

    # Ensure audio env is sane — emits hint if not.
    env = voice_mode.detect_audio_environment()
    log.info("audio env: %s", env)

    if args.once:
        run_once(args.silence_duration, args.silence_threshold)
        return

    asyncio.run(ws_server(args.host, args.port,
                          args.silence_duration, args.silence_threshold))


if __name__ == "__main__":
    main()
