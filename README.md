# comfyui-zluda-gfx1030

Get ComfyUI running on an **RX 6950 XT / 6900 XT / 6800 XT / 6800** (Navi 21, gfx1030) under ZLUDA on Windows.

## What is special about this GPU

Nothing about the kernels, and that is the point.

gfx1030 is on the official AMD ROCm support list, so stock rocBLAS already ships its kernels: a clean ROCm 6.4 install has 88 gfx1030 files in `bin\rocblas\library`. If you followed a guide written for an unsupported card and started hunting for kernel packs, stop. That is not your problem.

What actually breaks on this card is the ZLUDA plumbing, and every failure comes with a misleading error message:

1. **ZLUDA and HIP major versions must match exactly.** ZLUDA's `nvcuda.dll` hardcodes `amdhip64_6.dll` or `amdhip64_7.dll` in its import table. A mismatch gives you a bare `0xC0000135` and nothing else to go on.
2. **Python 3.8+ no longer searches PATH** for extension-module DLL dependencies. The ZLUDA DLLs have to sit in `venv\Lib\site-packages\torch\lib` under the names torch asks for. Editing PATH does nothing.
3. **ComfyUI-Zluda disables cuDNN on every ZLUDA setup**, on the grounds that RDNA2 has no working engine. Measured on an RX 6950 XT, convolutions actually survive cuDNN being left on, so this may cost you nothing here - but the launcher decides, not you, and the scripts keep it consistent.
4. **The mem-efficient attention backend resets the display driver.** Its CUTLASS kernel is built for an SM version that does not match, so a single SDPA call floods `FATAL: kernel ... is for sm80-sm100, but was built for sm37` and takes the driver down. ComfyUI-Zluda disables that backend for you; the danger is in scripts that call `torch.nn.functional.scaled_dot_product_attention` without doing the same.
5. **The launcher overwrites the file you just patched.** `comfyui.bat` copies `comfy\customzluda\zluda-default.py` over `comfy\zluda.py` on every launch, and `comfy\model_management.py` imports `comfy.zluda`. Edit the default, not the copy.

## Usage

```powershell
git clone https://github.com/RYZENNAVI/comfyui-zluda-gfx1030
cd comfyui-zluda-gfx1030
.\install.ps1
```

Reopen your terminal afterwards, then launch ComfyUI as usual.

### Individual steps

```powershell
.\scripts\Check-Environment.ps1    # read-only diagnostics; run this first whenever something breaks
.\scripts\Patch-ComfyUI.ps1        # patch ComfyUI and copy the ZLUDA DLLs into torch\lib
.\scripts\Test-Setup.ps1           # run matmul, conv2d and SDPA on the GPU
```

`Test-Setup.ps1` refuses to start while ComfyUI is running, so the two do not fight over VRAM. Pass `-Force` to override.

## Requirements

- Windows 10/11
- An RX 6950 XT / 6900 XT / 6800 XT / 6800. RX 6800M and 6850M XT are Navi 22, not this project.
- A working [ComfyUI-Zluda](https://github.com/patientx/ComfyUI-Zluda) install
- HIP SDK for Windows, matching your ZLUDA version: ZLUDA 3.9.5 goes with HIP 6.x, 3.9.6 with HIP 7.x

### A configuration known to work

Verified on an RX 6950 XT:

| | |
|---|---|
| Display driver | 32.0.21043.19003 |
| HIP SDK | 6.4 (`amdhip64_6.dll`) |
| ZLUDA | 3.9.5 |
| Python | 3.11.9 |
| torch | 2.7.0+cu118 |
| Launch flags | `--use-quad-cross-attention --reserve-vram 0.9 --disable-async-offload --disable-pinned-memory` |

## When something breaks

Run `.\scripts\Check-Environment.ps1` first, then look the error up in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**, which maps each error code and symptom to its real cause.

## Related

[comfyui-zluda-gfx1031](https://github.com/RYZENNAVI/comfyui-zluda-gfx1031) covers the RX 6700 / 6700 XT / 6750 XT. Those cards are not officially supported, so that project also has to solve where the rocBLAS kernels come from. The ZLUDA-layer problems are shared.

The scripts in this repository are MIT licensed and redistribute no third-party binaries.
