#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
generate_sfx.py — 오대십국 전략 게임용 프로그래머틱 SFX 생성기
──────────────────────────────────────────────────────────────
8/16-bit 칩튠 + 전통 국악풍 사운드를 numpy 합성으로 생성하여
24 kHz / 16-bit mono WAV 파일로 assets/audio/ 에 저장한다.

의존성: numpy (필수), scipy (선택 — 사용 안 함, 순수 numpy 합성)
호환: Python 3.11, numpy 2.x (BSD/MIT 호환)

사용법:
    python generate_sfx.py            # 기본 출력 (assets/audio/)
    python generate_sfx.py --out DIR  # 출력 디렉터리 지정
    python generate_sfx.py --loud     # 마스터 게인 +6 dB 부스트

합성 원리 (각 효과음별):
- march         : 행군 북소리 — 70 Hz 정현파 + 140 Hz 하모닉 + 짧은 노이즈 버스트 (0.12s) 4회 반복
- sword_clash   : 금속 충격 — 2200 Hz 대역 통과 노이즈 0.08s + 880 Hz 감쇠 사인파 잔향
- arrow_volley  : 화살 일제 사격 — 0.6 s 백색 노이즈 + 고주수 와이(3500 Hz) 페이드
- spear_brace   : 창 부딪히는 짤깠 — 다중 짧은 임팩트 (4×0.06 s) + 220 Hz 공명
- siege_ram     : 성벽 충각 묵직한 타격 — 40 Hz 사인 + 노이즈 0.5 s 감쇠
- morale_break  : 패주 징 + 비명 — 880 Hz→660 Hz 글리산도 + 사이렌 변조
- decree_gong   : 궁중 징 — 120 Hz 펑더멘털 + 다중 인하모닉 + 긴 리버브 감쇠
- victory_fanfare : 승전 팡파르 — C4/E4/G4/C5 라르조 멜로디 (간지팡파르)
- defeat_funeral : 패전 비장 — E♭4/G4/A♭4 내림 단조 행진곡 느린 템포

모든 출력은 피크 노멀라이즈(<0.95) 후 16-bit PCM 으로 인코딩한다.
"""
from __future__ import annotations
import argparse
import os
import struct
import wave
import numpy as np
from pathlib import Path

# ----------------------------------------------------------------------
# 오디오 합성 헬퍼
# ----------------------------------------------------------------------
SR = 24000  # 24 kHz — 고전 전략 게임에 어울리는 약간 거친 질감

def _normalize(buf: np.ndarray, peak: float = 0.92) -> np.ndarray:
    """피크 노멀라이즈 (clip 방지)."""
    m = float(np.max(np.abs(buf))) if buf.size else 0.0
    if m < 1e-9:
        return buf
    return buf * (peak / m)

def _to_pcm16(buf: np.ndarray) -> np.ndarray:
    """float [-1,1] → int16 변환."""
    return np.clip(buf, -1.0, 1.0).__mul__(32767.0).astype(np.int16)

def _write_wav(path: Path, samples: np.ndarray) -> None:
    """mono 16-bit WAV 저장."""
    pcm = _to_pcm16(samples)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # 16-bit
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

def _adsr(n: int, a: float, d: float, s_level: float, r: float) -> np.ndarray:
    """단순 ADSR 엔벌로프 — a/d/r 은 초(s) 단위, s_level 은 sustain 진폭(0~1)."""
    a_n = max(1, int(a * SR))
    d_n = max(1, int(d * SR))
    r_n = max(1, int(r * SR))
    total = a_n + d_n + r_n
    if total > n:
        # 너무 길면 비율 축소
        scale = n / total
        a_n = max(1, int(a_n * scale))
        d_n = max(1, int(d_n * scale))
        r_n = max(1, n - a_n - d_n)
    attack = np.linspace(0.0, 1.0, a_n, dtype=np.float32)
    decay = np.linspace(1.0, s_level, d_n, dtype=np.float32)
    release = np.linspace(s_level, 0.0, r_n, dtype=np.float32)
    env = np.concatenate([attack, decay, release])
    if len(env) < n:
        env = np.concatenate([env, np.zeros(n - len(env), dtype=np.float32)])
    else:
        env = env[:n]
    return env.astype(np.float32)

def _sine(freq: float, dur: float, phase: float = 0.0) -> np.ndarray:
    n = int(dur * SR)
    t = np.arange(n, dtype=np.float32) / SR
    return np.sin(2.0 * np.pi * freq * t + phase).astype(np.float32)

def _square(freq: float, dur: float, duty: float = 0.5) -> np.ndarray:
    n = int(dur * SR)
    t = np.arange(n, dtype=np.float32) / SR
    sig = np.sign(np.sin(2.0 * np.pi * freq * t))
    # duty cycle 변환 (펄스파)
    if duty != 0.5:
        th = (duty - 0.5) * 2.0
        sig = np.where(np.sin(2.0 * np.pi * freq * t) > th, 1.0, -1.0).astype(np.float32)
    return sig

def _noise(n: int, color: str = "white") -> np.ndarray:
    """white / pink 노이즈. pink 는 1/f 근사."""
    rng = np.random.default_rng(seed=int(n) & 0xFFFF)
    if color == "white":
        return (rng.standard_normal(n) * 0.6).astype(np.float32)
    # pink: 누적 필터
    white = rng.standard_normal(n).astype(np.float32)
    b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
    a = [1.0, -2.494956002, 2.017265875, -0.522189400]
    # 단순 IIR (numpy 직접 구현)
    out = np.zeros_like(white)
    x1 = x2 = x3 = 0.0
    y1 = y2 = y3 = 0.0
    for i in range(n):
        x0 = white[i]
        y0 = (b[0]*x0 + b[1]*x1 + b[2]*x2 + b[3]*x3
              - a[1]*y1 - a[2]*y2 - a[3]*y3)
        out[i] = y0
        x1, x2, x3 = x0, x1, x2
        y1, y2, y3 = y0, y1, y2
    return (out * 0.5).astype(np.float32)

def _lowpass(buf: np.ndarray, cutoff_norm: float) -> np.ndarray:
    """1-pole 저역 통과 (cutoff_norm 은 0~1, SR 대비)."""
    rc = 1.0 / (2.0 * np.pi * max(1e-3, cutoff_norm))
    dt = 1.0 / SR
    alpha = dt / (rc + dt)
    y = np.zeros_like(buf)
    acc = 0.0
    for i in range(len(buf)):
        acc = acc + alpha * (buf[i] - acc)
        y[i] = acc
    return y

def _highpass(buf: np.ndarray, cutoff_norm: float) -> np.ndarray:
    """1-pole 고역 통과."""
    rc = 1.0 / (2.0 * np.pi * max(1e-3, cutoff_norm))
    dt = 1.0 / SR
    alpha = rc / (rc + dt)
    y = np.zeros_like(buf)
    prev_x = 0.0
    prev_y = 0.0
    for i in range(len(buf)):
        cur = alpha * (prev_y + buf[i] - prev_x)
        y[i] = cur
        prev_x = buf[i]
        prev_y = cur
    return y

def _mix(*chunks: np.ndarray) -> np.ndarray:
    """여러 1-D 신호를 가장 긴 길이에 맞춰 합산."""
    n = max(len(c) for c in chunks)
    out = np.zeros(n, dtype=np.float32)
    for c in chunks:
        if len(c) < n:
            c = np.concatenate([c, np.zeros(n - len(c), dtype=np.float32)])
        out += c
    return out

def _silence(dur: float) -> np.ndarray:
    n = max(0, int(dur * SR))
    return np.zeros(n, dtype=np.float32)

def _crossfade(a: np.ndarray, b: np.ndarray, fade: float = 0.02) -> np.ndarray:
    if len(a) == 0:
        return b
    if len(b) == 0:
        return a
    n = int(fade * SR)
    n = min(n, len(a), len(b))
    if n <= 0:
        return np.concatenate([a, b])
    out = a.copy()
    out[-n:] *= np.linspace(1.0, 0.0, n, dtype=np.float32)
    bb = b.copy()
    bb[:n] *= np.linspace(0.0, 1.0, n, dtype=np.float32)
    out = np.concatenate([out, bb[n:]])
    return out

# ----------------------------------------------------------------------
# 개별 SFX 합성
# ----------------------------------------------------------------------
def sfx_march(dur: float = 1.6) -> np.ndarray:
    """행군 북소리 — 0.4 s 간격으로 4회 타격 (70 Hz 본음 + 140 Hz 배음)."""
    out = np.zeros(0, dtype=np.float32)
    interval = 0.4
    for i in range(int(dur / interval)):
        beat_dur = 0.32
        # 본체: 70 Hz 정현파 + 140 Hz 배음 (가볍게)
        body = _sine(70.0, beat_dur) * 0.85 + _sine(140.0, beat_dur) * 0.35
        # 짧은 노이즈 임팩트 (드럼 스틱 타격감)
        impact = _noise(int(0.04 * SR), "white") * 0.7
        # 엔벌로프: 매우 짧은 attack, sustain, 빠른 release
        env = _adsr(len(body), 0.005, 0.05, 0.7, 0.25)
        beat = (body + np.concatenate([impact, np.zeros(len(body) - len(impact))])) * env
        out = _crossfade(out, beat, fade=0.02)
        # 다음 비트까지 침묵
        out = np.concatenate([out, _silence(interval - beat_dur)])
    return _normalize(out, peak=0.85)


def sfx_sword_clash(dur: float = 0.55) -> np.ndarray:
    """칼 부딪힘 — 고주파 노이즈 + 금속 공명 사인파."""
    n = int(dur * SR)
    # 고주파 금속 노이즈 (충격음)
    impact = _noise(n, "white")
    impact = _highpass(impact, cutoff_norm=0.25)  # 6 kHz 이상 강조
    impact *= np.exp(-np.linspace(0, 8, n, dtype=np.float32))  # 빠른 감쇠
    # 금속 공명: 2200 Hz + 3300 Hz + 4400 Hz 디케이 사인파
    ring = (_sine(2200.0, dur) * 0.6
            + _sine(3300.0, dur) * 0.4
            + _sine(4400.0, dur) * 0.3)
    ring *= np.exp(-np.linspace(0, 6, n, dtype=np.float32))
    out = impact * 0.9 + ring * 0.45
    return _normalize(out, peak=0.88)


def sfx_arrow_volley(dur: float = 0.9) -> np.ndarray:
    """화살 일제 사격 — 와이 노이즈 + 날카로운 와이 whine."""
    n = int(dur * SR)
    t = np.linspace(0, dur, n, dtype=np.float32)
    # 메인: 흰 노이즈를 살짝 펄스 변조하여 화살 여러 발이 날아가는 느낌
    noise = _noise(n, "white")
    # 진폭 변조: 화살 발사 리듬 (8회 빠른 펄스 후 감쇠)
    pulses = np.zeros(n, dtype=np.float32)
    pulse_dur = 0.08
    pulse_count = 6
    for i in range(pulse_count):
        start = int(i * 0.11 * SR)
        end = min(n, start + int(pulse_dur * SR))
        pulses[start:end] += np.exp(-np.linspace(0, 6, end - start, dtype=np.float32))
    # 화살 whine: 3500 → 4500 Hz 주파수 sweep
    freq = 3500.0 + 1000.0 * t / dur
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    whine = (np.sin(phase) * 0.3).astype(np.float32)
    whine *= np.exp(-np.linspace(0, 3, n, dtype=np.float32))
    out = noise * pulses * 0.9 + whine * 0.4
    return _normalize(out, peak=0.9)


def sfx_spear_brace(dur: float = 0.9) -> np.ndarray:
    """창벽 방진 — 4번의 짤깠 임팩트 + 저음 공명."""
    out = np.zeros(0, dtype=np.float32)
    times = [0.0, 0.18, 0.36, 0.55]
    for t0 in times:
        beat_dur = 0.16
        n = int(beat_dur * SR)
        # 짤깠음: 고주파 충격
        click = _noise(n, "white") * np.exp(-np.linspace(0, 16, n, dtype=np.float32))
        click = _highpass(click, cutoff_norm=0.18)
        # 저음 공명 220 Hz
        body = _sine(220.0, beat_dur) * np.exp(-np.linspace(0, 8, n, dtype=np.float32))
        beat = click * 0.8 + body * 0.5
        pad = _silence(t0)
        beat = np.concatenate([pad, beat]) if t0 > 0 else beat
        out = _crossfade(out, beat, fade=0.005)
    # 길이 보정 (음수 방어)
    cur_dur = len(out) / SR
    if dur > cur_dur:
        out = np.concatenate([out, _silence(dur - cur_dur)])
    return _normalize(out, peak=0.88)


def sfx_siege_ram(dur: float = 1.2) -> np.ndarray:
    """성벽 충각 묵직한 타격 — 저주 사인 + 노이즈 긴 감쇠."""
    n = int(dur * SR)
    t = np.linspace(0, dur, n, dtype=np.float32)
    # 본체: 50 Hz 사인 (묵직한 저음)
    body = _sine(50.0, dur) * np.exp(-np.linspace(0, 4, n, dtype=np.float32))
    # 충격 노이즈 (먼지/돌 파편)
    impact = _noise(n, "white") * np.exp(-np.linspace(0, 6, n, dtype=np.float32))
    impact = _lowpass(impact, cutoff_norm=0.15)
    # 잔향: 80 Hz + 120 Hz 느린 감쇠
    reverb = (_sine(80.0, dur) * 0.5 + _sine(120.0, dur) * 0.3) * np.exp(-np.linspace(0, 2.5, n, dtype=np.float32))
    out = body * 1.0 + impact * 0.8 + reverb * 0.4
    return _normalize(out, peak=0.92)


def sfx_morale_break(dur: float = 1.4) -> np.ndarray:
    """패주 징 + 비명 — 사이렌 글리산도 + 비명 같은 변조 사인."""
    n = int(dur * SR)
    t = np.linspace(0, dur, n, dtype=np.float32)
    # 사이렌: 660 Hz → 880 Hz → 660 Hz
    freq = 660.0 + 220.0 * np.sin(2.0 * np.pi * 4.0 * t)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    siren = (np.sin(phase) * 0.7).astype(np.float32)
    # 엔벌로프: 점점 강해지다 끝에서 감쇠
    env = np.minimum(t / 0.2, 1.0) * np.exp(-np.maximum(0, t - dur * 0.6) * 3.0)
    siren *= env.astype(np.float32)
    # 비명 같은 화이트 노이즈 변조 (panic screaming)
    noise = _noise(n, "white") * 0.25
    noise *= np.exp(-np.linspace(0, 5, n, dtype=np.float32))
    # 일부는 high-pass로 날카롭게
    scream = _highpass(noise, cutoff_norm=0.2) * 0.5
    out = siren * 0.85 + scream * 0.4
    return _normalize(out, peak=0.9)


def sfx_decree_gong(dur: float = 2.4) -> np.ndarray:
    """궁중 징 — 120 Hz 본음 + 다중 인하모닉 + 긴 리버브."""
    n = int(dur * SR)
    t = np.linspace(0, dur, n, dtype=np.float32)
    # 펑더멘털 + 인하모닉 (비율: 한국 징의 특징적인 부분음)
    harmonics = [
        (120.0, 1.0),
        (240.0, 0.55),
        (300.0, 0.40),  # 비배음 (중국/한국 징 특유의 울림)
        (480.0, 0.35),
        (720.0, 0.25),
        (1200.0, 0.18),
    ]
    out = np.zeros(n, dtype=np.float32)
    for freq, amp in harmonics:
        decay = np.exp(-np.linspace(0, 1.8 + (1200 - freq) * 0.001, n, dtype=np.float32))
        out += _sine(freq, dur) * amp * decay
    # 초기 임팩트 (망치 타격) 노이즈
    impact = _noise(int(0.05 * SR), "white") * np.exp(-np.linspace(0, 20, int(0.05 * SR), dtype=np.float32))
    out[: len(impact)] += impact * 0.6
    return _normalize(out, peak=0.88)


def sfx_victory_fanfare(dur: float = 3.6) -> np.ndarray:
    """승전 팡파르 — C4/E4/G4/C5 라르조 멜로디 (트럼펫/호른 풍)."""
    # 라르조 행진곡 템포: 120 BPM → 비트 0.5 s
    beat = 0.25  # 8분음표 기준
    # 음표 (주파수 Hz): C4=261.63, E4=329.63, G4=392.00, C5=523.25
    notes = [
        (261.63, 1),  # C4 1박
        (329.63, 1),  # E4
        (392.00, 1),  # G4
        (523.25, 2),  # C5 2박
        (392.00, 1),
        (523.25, 3),  # C5 3박 (마지막 길게)
        (329.63, 1),
        (392.00, 1),
        (523.25, 2),
        (392.00, 1),
        (329.63, 1),
        (261.63, 2),
    ]
    out = np.zeros(0, dtype=np.float32)
    for freq, n_beats in notes:
        note_dur = beat * n_beats
        n = int(note_dur * SR)
        # 트럼펫 풍: 사각파 + 약간의 sawtooth 배음
        body = _square(freq, note_dur, duty=0.5) * 0.45 + _sine(freq * 2.0, note_dur) * 0.15
        env = _adsr(n, 0.02, 0.08, 0.65, note_dur * 0.5)
        note = body * env
        out = _crossfade(out, note, fade=0.005)
    # 마지막에 짧은 징 한 번 (승전의 고동)
    tail_gong = sfx_decree_gong(dur=1.2) * 0.4
    out = np.concatenate([out, tail_gong])
    # 길이 보정
    cur_dur = len(out) / SR
    if dur > cur_dur:
        out = np.concatenate([out, _silence(dur - cur_dur)])
    return _normalize(out, peak=0.85)


def sfx_defeat_funeral(dur: float = 3.2) -> np.ndarray:
    """패전 비장 — E♭장 단조 행진곡 느린 템포 (Eb4/G4/Bb4 내림 패턴)."""
    # 느린 행진곡: 70 BPM → 비트 ≈ 0.857 s, 4분음표 = 0.857 s
    beat = 0.43  # 8분음표
    # 단조 행진: E♭4=311.13, G4=392.00, B♭4=466.16, E♭5=622.25
    notes = [
        (311.13, 2),  # Eb4
        (392.00, 1),  # G4
        (466.16, 1),  # Bb4
        (311.13, 2),  # Eb4
        (466.16, 1),
        (392.00, 1),
        (311.13, 3),  # 길게
        (392.00, 1),
        (311.13, 1),
        (233.08, 4),  # Eb3 (낮은 종결음)
    ]
    out = np.zeros(0, dtype=np.float32)
    for freq, n_beats in notes:
        note_dur = beat * n_beats
        n = int(note_dur * SR)
        # 비장한 클라리넷/오보에 풍: 부드러운 sawtooth + sine
        # sawtooth 근사: 사각파에 미분
        body = _square(freq, note_dur, duty=0.5) * 0.35 + _sine(freq, note_dur) * 0.45
        env = _adsr(n, 0.04, 0.12, 0.55, note_dur * 0.55)
        note = body * env
        out = _crossfade(out, note, fade=0.01)
    # 마지막 큰북 한 번 (장송의 비트)
    drum = sfx_siege_ram(dur=0.8) * 0.6
    out = np.concatenate([out, drum])
    cur_dur = len(out) / SR
    if dur > cur_dur:
        out = np.concatenate([out, _silence(dur - cur_dur)])
    return _normalize(out, peak=0.78)


# ----------------------------------------------------------------------
# 마스터 진입점
# ----------------------------------------------------------------------
CATALOG = {
    "sfx_march.wav":          ("march",          sfx_march,           1.6),
    "sfx_sword_clash.wav":    ("sword_clash",    sfx_sword_clash,     0.55),
    "sfx_arrow_volley.wav":   ("arrow_volley",   sfx_arrow_volley,    0.9),
    "sfx_spear_brace.wav":    ("spear_brace",    sfx_spear_brace,     0.9),
    "sfx_siege_ram.wav":      ("siege_ram",      sfx_siege_ram,       1.2),
    "sfx_morale_break.wav":   ("morale_break",   sfx_morale_break,    1.4),
    "sfx_decree_gong.wav":    ("decree_gong",    sfx_decree_gong,     2.4),
    "sfx_victory_fanfare.wav":("victory_fanfare",sfx_victory_fanfare, 3.6),
    "sfx_defeat_funeral.wav": ("defeat_funeral", sfx_defeat_funeral,  3.2),
}

# 보너스: 메뉴 이동/선택 효과음 (UI 쥬스용 — 보너스 산출물)
EXTRA = {
    "sfx_ui_select.wav":      ("ui_select",   lambda: _square(880.0, 0.04) * 0.3, 0.04),
    "sfx_ui_hover.wav":       ("ui_hover",    lambda: _sine(660.0, 0.03) * 0.2, 0.03),
    "sfx_turn_change.wav":    ("turn_change", lambda: _sine(523.25, 0.08) * 0.4 + _sine(659.25, 0.08) * 0.3, 0.16),
}

def main():
    parser = argparse.ArgumentParser(description="오대십국 전략 게임 SFX 생성기")
    parser.add_argument("--out", default="assets/audio", help="출력 디렉터리 (기본: assets/audio)")
    parser.add_argument("--loud", action="store_true", help="전체 게인 부스트 (+3 dB)")
    parser.add_argument("--with-extra", action="store_true", default=True, help="UI 보너스 SFX도 생성")
    args = parser.parse_args()

    out_dir = Path(args.out)
    if not out_dir.is_absolute():
        # 프로젝트 루트 기준 (스크립트 위치의 부모)
        root = Path(__file__).resolve().parent
        out_dir = root / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    boost = 1.41 if args.loud else 1.0  # +3 dB ≈ ×√2

    print(f"[generate_sfx] 출력 디렉터리: {out_dir}")
    print(f"[generate_sfx] 샘플레이트: {SR} Hz, 16-bit mono")

    items = list(CATALOG.items())
    if args.with_extra:
        items += list(EXTRA.items())

    total_bytes = 0
    for filename, (label, fn, default_dur) in items:
        # EXTRA 의 lambda 는 인자 없이 호출
        try:
            sig = fn(default_dur)
        except TypeError:
            sig = fn()
        sig = sig * boost
        sig = _normalize(sig, peak=0.9)
        path = out_dir / filename
        _write_wav(path, sig)
        size_kb = path.stat().st_size / 1024
        total_bytes += path.stat().st_size
        print(f"  ✓ {filename:28s}  {len(sig)/SR:5.2f}s  {size_kb:7.1f} KB")

    print(f"[generate_sfx] 완료 — {len(items)}개 파일, 총 {total_bytes/1024:.1f} KB")


if __name__ == "__main__":
    main()