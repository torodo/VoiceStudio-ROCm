# VoiceStudio — VoxCPM2 Engine

VoxCPM2 (OpenBMB) is the studio-quality option: native 48 kHz output,
zero-shot voice cloning, and — uniquely among VoiceStudio's engines —
**voice design**: creating a synthetic voice from a text description
("young female, warm tone, British accent") with no reference audio at all.

## When to pick it

- You want voice design without a reference clip.
- You want the highest output sample rate (48 kHz vs OmniVoice's 24 kHz).
- Your language is among its 30 supported languages: Arabic, Burmese,
  Chinese, Danish, Dutch, English, Finnish, French, German, Greek, Hebrew,
  Hindi, Indonesian, Italian, Japanese, Khmer, Korean, Lao, Malay,
  Norwegian, Polish, Portuguese, Russian, Spanish, Swahili, Swedish,
  Tagalog, Thai, Turkish, Vietnamese.

## Requirements

- Python ≥ 3.10, PyTorch ≥ 2.5.
- CUDA ≥ 12 recommended for full speed; MPS (Apple Silicon) and CPU also
  work. AMD GPUs run it through ROCm 7.x on Linux and WSL2 (see below).

## Setup

Install the package into VoiceStudio's Python environment:

```bash
pip install "voxcpm>=2.0.3"
```

That is a version **floor**, not a pin — an older install still works, but
the engine logs an upgrade hint at load time. Then select the engine via
**Model Catalogue** or `OMNIVOICE_TTS_BACKEND=voxcpm2`.

## Model selection

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMNIVOICE_VOXCPM_MODEL` | `openbmb/VoxCPM2` | HuggingFace checkpoint to load |

The first use downloads a multi-GB checkpoint from HuggingFace. A download
interrupted near the end used to abort the load outright
([#1224](https://github.com/debpalash/VoiceStudio/issues/1224)); the load is
now retried once with a fresh client. See
[downloading-models.md](../downloading-models.md).

## Behaviour notes

- **Voice design:** provide a description and no reference audio. VoiceStudio
  passes it in the native `(description)text` format; there is no separate
  `voice_description` argument in VoxCPM 2.0.3.
- **Cloning:** the reference clip is prepared before use (edge-silence trim
  and a cap at the first 30 seconds) so dead air in a raw clip doesn't
  condition the output; on any prep problem the raw clip is used as-is. When
  the cap cuts the clip, its whole-clip transcript no longer matches, so it is
  ignored and the capped clip clones as a plain reference.
- **Style instructions** (the Style field, API `instruct`, or a leading
  `(instruction)` in the text) use controllable cloning: the reference supplies
  timbre, without the saved transcript forcing continuation of its delivery.
- **Plain cloning** with a reference and transcript retains upstream continuation
  mode. A transcript without reference audio is ignored. These mappings follow
  the [VoxCPM 2.0.3 examples](https://github.com/OpenBMB/VoxCPM/blob/2.0.3/README.md#-voice-design)
  in both the managed sidecar and in-process adapter.
- VoxCPM2 emits mastered, studio-grade audio, so VoiceStudio **skips its
  shared mastering chain** (which is tuned for 24 kHz engines) — only benign
  loudness normalization applies.
- A trailing-silence guard trims long near-silent tails from generations,
  keeping a short natural tail.

## Known limits

- Slower than the lightweight CPU engines — see
  [benchmarks.md](../benchmarks.md) and [performance.md](../performance.md).
- Language coverage is 30 languages; for anything else use the default
  [OmniVoice](omnivoice.md) engine ([languages.md](../languages.md)).

## One-click install

Click **Install** in **Model Catalogue → VoxCPM2**. VoiceStudio
puts VoxCPM2 in its own Python environment under its data directory and runs
it there, in a separate process. It installs the CUDA build of PyTorch on an
NVIDIA GPU, the CPU build on other Windows and Linux machines, and the
regular build on Apple Silicon.

**AMD GPUs (ROCm 7.x, Linux and WSL2).** Set `OMNIVOICE_ROCM_FIND_LINKS` to
AMD's wheel page for the installed ROCm release, e.g.
`https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2.4/`, before installing.
VoiceStudio then installs AMD's ROCm build of VoxCPM2's PyTorch pair (in a
Python 3.12 environment when that is the only one AMD ships) plus a CPU
`torchcodec`; those wheels use the system ROCm, which is what reaches the GPU
through WSL2's ROCDXG bridge. Without the variable, or when AMD has no build of
the pinned version, it keeps installing the CPU build. The `rocm-wsl` Docker
profile sets the variable for you. An install made before the variable was set
keeps its CPU build: uninstall and install again. Measured on an RX 7800 XT
under WSL2: about 3× faster than the CPU, still slower than real time, because
each CPU↔GPU synchronisation costs more through the WSL bridge than on native
Linux.

Nothing it installs touches VoiceStudio itself or any other engine, and
**Uninstall** in the same row removes only that folder. An existing
`pip install voxcpm` setup keeps working as it is. The button is not offered
on Intel Macs, where no PyTorch build it needs exists. The model weights
download on first use.

## Troubleshooting

- Engine shows unavailable: the `voxcpm` package isn't installed — run the
  `pip install` above and restart VoiceStudio.
- Repeated first-download failures: check connectivity/HF access, then see
  [install/troubleshooting.md](../install/troubleshooting.md).

See also: [expressive-speech.md](../expressive-speech.md),
[disk usage](disk-usage.md).
