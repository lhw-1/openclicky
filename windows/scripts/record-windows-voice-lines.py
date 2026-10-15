#!/usr/bin/env python3
"""Records the Windows versions of the tour lines that name keys, as <line>-windows.mp3.

The Mac recordings say "hold the fn key" and "control and option"; a Windows PC has neither. The
app says these four lines the Windows way (RecordedVoice.WindowsSentence) with this PC's voice
unless a Windows recording sits next to the Mac one, which this script makes in the same voice as
every other recorded line (OpenAI speech, marin; see macos/OpenClicky/scripts/record-voice-lines.py).
The dictation line names the default key (left Ctrl); a person who picked another key hears the
sentence from this PC's voice instead. Keep the texts in step with RecordedVoice.WindowsSentence.

    OPENAI_API_KEY=... windows/scripts/record-windows-voice-lines.py
    OPENAI_API_KEY=... windows/scripts/record-windows-voice-lines.py tour-dictate
"""

import json
import os
import pathlib
import sys
import urllib.request

LINES = {
    "tour-dictate": "Hold left control, say a sentence, then let go. Your words land wherever your cursor is.",
    "tour-talk": "Your turn. Hold control and the Windows key, and ask me about anything on your screen.",
    "tour-act": "Now give me a task. Hold control and the Windows key, and tell me what to do.",
    "settings-tour-shortcuts": "Shortcuts shows every key at a glance. Hold control and the Windows key to talk to me.",
}

INSTRUCTIONS = "Warm, friendly and unhurried, like showing a parent around a new app. Clear and calm."

OUTPUT_FOLDER = pathlib.Path(__file__).resolve().parent.parent / "src" / "OpenClicky.Windows" / "Assets" / "RecordedVoice"


def record(name: str, text: str, api_key: str) -> None:
    body = json.dumps({
        "model": "gpt-4o-mini-tts",
        "voice": "marin",
        "input": text,
        "instructions": INSTRUCTIONS,
        "response_format": "mp3",
    }).encode()
    request = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        audio = response.read()
    (OUTPUT_FOLDER / f"{name}-windows.mp3").write_bytes(audio)
    print(f"{name}-windows.mp3  {len(audio) // 1024} KB")


def main() -> None:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        sys.exit("OPENAI_API_KEY is not set")
    chosen = sys.argv[1:] or list(LINES)
    for name in chosen:
        if name not in LINES:
            sys.exit(f"unknown line {name}; one of {', '.join(LINES)}")
        record(name, LINES[name], api_key)


if __name__ == "__main__":
    main()
