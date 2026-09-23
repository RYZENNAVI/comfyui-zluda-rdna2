# comfyui-zluda-rdna2

Get ComfyUI running under ZLUDA on Windows on a desktop RDNA2 Radeon, gfx1030 and gfx1031 alike.

Everything here was measured on an **RX 6950 XT** (gfx1030) and an **RX 6700 XT** (gfx1031). Those two are the only cards this has run on. The rest of the desktop RDNA2 line - RX 6900 XT, 6800 XT and 6800 on gfx1030, RX 6750 XT and 6700 on gfx1031 - is the same silicon as one of them and should behave identically, but that is extrapolation, not a tested claim. The scripts accept those cards; reports from them are welcome.

This replaces two earlier projects, [comfyui-zluda-gfx1030](https://github.com/RYZENNAVI/comfyui-zluda-gfx1030) and [comfyui-zluda-gfx1031](https://github.com/RYZENNAVI/comfyui-zluda-gfx1031). Both were verified against real hardware, and once the findings were compared, almost everything turned out to be shared.

## The main difference between the two architectures

**Kernels.** gfx1030 (Navi 21) is on the official AMD ROCm support list, so stock rocBLAS already ships its kernels - a clean ROCm 6.4 install has 88 of them. gfx1031 (Navi 22) is not, and official rocBLAS ships none at all, so the first matmul dies with `no kernel image is available` until they are installed.

`install.ps1` detects which card you have and runs three steps or four accordingly. If you followed a guide written for the other architecture and started hunting for kernel packs on a 6950 XT, stop: that is not your problem.

Everything else below applies to both.

## What actually breaks, and why the error never says so

1. **ZLUDA and HIP major versions must match exactly.** ZLUDA's `nvcuda.dll` hardcodes `amdhip64_6.dll` or `amdhip64_7.dll` in its import table. A mismatch gives you a bare `0xC0000135` and nothing else to go on.
2. **Python 3.8+ no longer searches PATH** for extension-module DLL dependencies. The ZLUDA DLLs have to sit in `venv\Lib\site-packages\torch\lib` under the names torch asks for. Editing PATH does nothing. Note that `cublasLt64_11.dll` is **not** one of them: copying every DLL in the ZLUDA directory, which looks like the obvious move, breaks torch.
3. **The mem-efficient attention backend resets the display driver.** Its CUTLASS kernel is built for an SM version that does not match, so one SDPA call floods `FATAL: kernel ... is for sm80-sm100, but was built for sm37` and takes the driver down. ComfyUI disables that backend for you; the danger is in scripts that call SDPA without doing the same. Measured on both architectures, with one difference: gfx1031 recovers by itself, while on gfx1030 two of three resets needed the power button.
4. **The launcher overwrites the file you just patched.** `comfyui.bat` copies `comfy\customzluda\zluda-default.py` over `comfy\zluda.py` on every launch, and `comfy\model_management.py` imports `comfy.zluda`. Edit the default, not the copy.

**cuDNN is not on this list**, although guides for RDNA2 under ZLUDA - including earlier versions of these two projects - say convolutions crash unless it is disabled. Measured on both cards, `cudnn.is_available()` returns true and convolutions run fine with it enabled. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Usage

This adapts an existing [ComfyUI-Zluda](https://github.com/patientx/ComfyUI-Zluda) install rather than creating one, so set that up first. Full requirements are below.

```powershell
git clone https://github.com/RYZENNAVI/comfyui-zluda-rdna2
cd comfyui-zluda-rdna2
.\install.ps1
```

Run as Administrator on gfx1031 when HIP lives under `Program Files`; the scripts check whether they can write and say so if not. Reopen your terminal afterwards, then launch ComfyUI as usual.

### Individual steps

```powershell
.\scripts\Check-Environment.ps1    # read-only diagnostics; run this first whenever something breaks
.\scripts\Install-Kernels.ps1      # gfx1031 only; refuses to run on gfx1030 without -Force
.\scripts\Patch-ComfyUI.ps1        # patch ComfyUI and copy the ZLUDA DLLs into torch\lib
.\scripts\Test-Setup.ps1           # run matmul, conv2d and SDPA on the GPU
```

`Test-Setup.ps1` refuses to start while ComfyUI is running, so the two do not fight over VRAM. Pass `-Force` to override.

## Requirements

- Windows 10/11
- A desktop RDNA2 Radeon. Mobile RDNA2 (RX 6800M, RX 6850M XT) is untested and the scripts will say so rather than pretend; reports welcome.
- A working [ComfyUI-Zluda](https://github.com/patientx/ComfyUI-Zluda) install
- **ZLUDA from [lshqqytiger/ZLUDA](https://github.com/lshqqytiger/ZLUDA)**, which is what ComfyUI-Zluda downloads for you. This matters: several projects are called ZLUDA and their version numbers overlap. The upstream [vosen/ZLUDA](https://github.com/vosen/ZLUDA) is a different codebase and is not what any of this was measured against.
- HIP SDK for Windows, matching your ZLUDA version: ZLUDA 3.9.5 goes with HIP 6.x, 3.9.6 with HIP 7.x
- [7-Zip](https://www.7-zip.org/) for `Install-Kernels.ps1 -Mode Download` - upstream packs are `.7z`, which the bundled Windows tools cannot extract

### Configurations known to work

| | gfx1030 | gfx1031 |
|---|---|---|
| Card | RX 6950 XT | RX 6700 XT |
| Display driver | 32.0.21043.19003 | 32.0.21043.19003 |
| HIP SDK | 6.4 | 6.2 (6.4 and 5.7 also installed) |
| ZLUDA | lshqqytiger 3.9.5, nightly, rocm6 build | lshqqytiger 3.9.5 |
| Python | 3.11.9 | 3.11.9 |
| torch | 2.7.0+cu118 | 2.7.0+cu118 |

Launch flags. `Patch-ComfyUI.ps1` adds `--disable-async-offload --disable-pinned-memory` for you, and both machines ran with them. The rest was the operator's own choice: `--use-quad-cross-attention --reserve-vram 0.9` on both, and `--disable-mmap` on the gfx1031 machine, which needed it to load large models.

To see which ZLUDA you have, run `zluda.exe --version` in the `zluda` directory of your ComfyUI install; `Check-Environment.ps1` prints it too. ComfyUI-Zluda offers a stable and a nightly build, and a rocm5 and a rocm6 variant; the variant has to match your HIP major version, and the `rocm6` builds are the ones that import `amdhip64_6.dll`. The gfx1030 column above was a nightly rocm6 build. Whether the gfx1031 machine ran a nightly was not recorded, so it is left unsaid rather than guessed.

## When something breaks

Run `.\scripts\Check-Environment.ps1` first, then look the error up in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**, which maps each error code and symptom to its real cause.

## Third-party kernels

`Install-Kernels.ps1 -Mode Download` fetches from these at install time:

- [likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU](https://github.com/likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU)
- [brknsoul/ROCmLibs](https://github.com/brknsoul/ROCmLibs)

**This repository redistributes none of those binaries.** They are GPL-3.0, and redistributing them would carry the corresponding obligations. The scripts only help you download them from upstream; whether to install them is your call. The scripts in this repository are MIT.
