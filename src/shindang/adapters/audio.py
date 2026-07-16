"""mock WAV 생성과 실제 TTS 캐시 파일 조회 어댑터."""

from __future__ import annotations

import hashlib
import math
import struct
import wave
from io import BytesIO
from pathlib import Path

class AudioStore:
    def __init__(self, mode: str, cache_dir: Path) -> None:
        self.mode = mode
        self.cache_dir = cache_dir
        self._mock_wav: bytes | None = None

    def url_for(self, cache_key: str) -> str:
        digest = hashlib.sha256(cache_key.encode()).hexdigest()
        if self.mode == "openai":
            return f"/audio/real/{digest}.mp3"
        return f"/audio/mock/{digest[:16]}.wav"

    def mock_wav(self) -> bytes:
        if self._mock_wav is not None:
            return self._mock_wav
        sample_rate = 22050
        sample_count = int(sample_rate * 2.5)
        fade = int(sample_rate * 0.05)
        frames = bytearray()
        for index in range(sample_count):
            amplitude = 0.15
            if index < fade:
                amplitude *= index / fade
            elif index > sample_count - fade:
                amplitude *= (sample_count - index) / fade
            value = amplitude * math.sin(2 * math.pi * 660 * index / sample_rate)
            frames += struct.pack("<h", int(value * 32767))
        output = BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(frames)
        self._mock_wav = output.getvalue()
        return self._mock_wav

    def real_path(self, key_hash: str) -> Path:
        return self.cache_dir / f"{key_hash}.mp3"
