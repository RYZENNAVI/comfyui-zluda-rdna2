# Troubleshooting

Look up what you are seeing. For most problems `scripts\Check-Environment.ps1` points straight at the cause.

Version numbers below refer to [lshqqytiger/ZLUDA](https://github.com/lshqqytiger/ZLUDA), the fork ComfyUI-Zluda installs. Other projects share the name and the numbering, so check which one you have with `zluda.exe --version` before matching anything against a version here.

## Error lookup

| Symptom | What is actually wrong | Fix |
|---|---|---|
| Exit code `0xC0000135`<br>(STATUS_DLL_NOT_FOUND) | The `amdhip64_N.dll` that ZLUDA wants is missing. ZLUDA's `nvcuda.dll` **hardcodes the major version** in its import table | Match them up: ZLUDA 3.9.5 needs HIP 6.x (`amdhip64_6.dll`), ZLUDA 3.9.6 needs HIP 7.x (`amdhip64_7.dll`) |
| Exit code `0xC0000139`<br>(STATUS_ENTRYPOINT_NOT_FOUND) | The DLL was found, but it does not export what was asked for | Still a version mix. Check whether a different version of `amdhip64*.dll` is being loaded first from PATH |
| `WinError 126: the specified module could not be found`<br>(on `import torch`) | Python 3.8+ **no longer searches PATH** for extension-module DLL dependencies | The DLLs must go directly into `venv\Lib\site-packages\torch\lib`. Editing PATH does nothing at all |
| `AttributeError: module 'comfy_kitchen' has no attribute 'int8_attention_is_available'` | That function does not exist under ZLUDA | `scripts\Patch-ComfyUI.ps1` |
| Access violation during convolution, or the process dies silently | Not cuDNN, despite what older guides say. Look at the attention rows below first | Read "cuDNN is not the problem it is said to be" |
| A fix you made to `comfy\zluda.py` has no effect | `comfyui.bat` regenerates that file on every launch | Edit `comfy\customzluda\zluda-default.py` instead |
| torch imports, but any CUDA call fails after replacing DLLs | `cublasLt64_11.dll` was overwritten with the ZLUDA `cublasLt.dll` | Only four DLLs get replaced. Reinstall torch to restore it |
| Access violation while loading a large model | The safetensors mmap path faults under memory pressure | Add `--disable-mmap` to the launch arguments |
| Out-of-memory part-way through a generation | Async offload or pinned memory | Launch with `--disable-async-offload --disable-pinned-memory` |
| The first generation hangs for ten minutes or more | Expected. ZLUDA is JIT-compiling kernels | Wait. They are cached in `%LOCALAPPDATA%\ZLUDA\ComputeCache` and later runs are fast |
| The screen goes black and recovers, event 4101 "display driver stopped responding", sometimes a hard hang | Something called SDPA with the mem-efficient backend left enabled | Disable that backend, the way `zluda-default.py` does. See "The mem-efficient attention backend resets the display driver" below |
| `FATAL: kernel ... is for sm80-sm100, but was built for sm37`, repeated endlessly | Same thing: the mem-efficient CUTLASS kernel | Same as above |
| `no kernel image is available for execution`<br>or `hipErrorNoBinaryForGpu`, **on gfx1031** | Official rocBLAS ships no gfx1031 kernels at all | `scripts\Install-Kernels.ps1` |
| The same error **on gfx1030** | Unexpected: this architecture ships with kernels, so the HIP install is stripped or broken | Reinstall the HIP SDK. Do not go looking for kernel packs; this card does not need them |
| HIP is installed but behaves as if it is not | Several versions installed with the wrong PATH order, or a user-scope environment variable shadowing the machine scope | See "Several HIP versions side by side" below |

## The awkward details

### The launcher overwrites your patch

`comfyui.bat` runs this twice during startup, before and after its git update:

```
copy comfy\customzluda\zluda-default.py comfy\zluda.py /y
```

`comfy\model_management.py` imports `comfy.zluda`, so that regenerated copy is the module that actually runs. Anything you edit in `comfy\zluda.py` survives until the next launch and no longer.

Note that `comfy\customzluda\zluda.py` is a third file. It is not the default, and it treats cuDNN differently: it reads `TORCH_BACKENDS_CUDNN_ENABLED` and **defaults to enabled**. If you switch to it, set that variable to `0`.

`zluda-default.py` also turns off `flash_sdp` and `mem_efficient_sdp` and forces `math_sdp` on. **Leave that alone.** The `mem_efficient_sdp(False)` line is the one holding your display driver up; see the attention section below.

### cuDNN is not the problem it is said to be

Guides for RDNA2 under ZLUDA, including an earlier version of this one, say that RDNA2 has no cuDNN engine and that convolutions crash unless cuDNN is disabled. Measured on both architectures, that does not hold:

| | gfx1030 (RX 6950 XT) | gfx1031 (RX 6700 XT) |
|---|---|---|
| `cudnn.is_available()` | True, version 9.1.0 | True, version 9.1.0 |
| 20x conv 320->320 at 128x128, cuDNN **on** | fine, 0.019s each | fine, 0.0147s each |

One operation per process, machine otherwise idle, both times. The driver resets that got blamed on cuDNN came from attention.

This is not an architecture difference, so do not go looking for one. The claim appears to be a leftover from older drivers or older ZLUDA builds.

`zluda-default.py` disables cuDNN anyway, so that is how ComfyUI runs whatever you conclude here. Leave it; the setting costs nothing. What actually needs guarding is `enable_mem_efficient_sdp(False)` in the same block.

Note that `torch\lib` keeps NVIDIA's own `cudnn64_9.dll` and friends. The ZLUDA `cudnn.dll` is not copied over them, the same way `cublasLt.dll` is not.

### The mem-efficient attention backend resets the display driver

A single `torch.nn.functional.scaled_dot_product_attention` call on a default `torch` configuration resets the display driver. The reset shows up as event 4101: a black screen that recovers, or a hang that needs the power button.

The cause is visible on stdout, tens of thousands of times over:

```
FATAL: kernel `fmha_cutlassF_f16_aligned_64x64_rf_sm80` is for sm80-sm100, but was built for sm37
```

`fmha_cutlassF` is the CUTLASS kernel behind the **mem-efficient** SDPA backend. The SM version it was built for does not match what it is asked to run on, and the flood of failures takes the driver with it.

Two things narrow this down further. First, the flash backend is never involved: torch rules it out before dispatch. Second, the math backend is pure torch operations and touches no CUTLASS kernel. You can confirm both on your own machine without calling SDPA at all, which means without risking the driver:

```python
import torch
from torch.backends.cuda import SDPAParams, can_use_flash_attention, can_use_efficient_attention
q = torch.randn(1, 8, 256, 64, device="cuda", dtype=torch.float16)
p = SDPAParams(q, q, q, None, 0.0, False, False)
print(torch.cuda.get_device_capability(0))      # (8, 8)
print(can_use_flash_attention(p, False))        # False - never selected
print(can_use_efficient_attention(p, False))    # True  - this is the broken one
```

So the rule is narrow: **disable the mem-efficient backend and SDPA is fine.** That is exactly what `zluda-default.py` already does for you:

```python
torch.backends.cuda.enable_flash_sdp(False)
torch.backends.cuda.enable_math_sdp(True)
torch.backends.cuda.enable_mem_efficient_sdp(False)
```

A normally launched ComfyUI is therefore safe. What is not safe is any script that imports torch directly and calls SDPA without repeating those lines, which includes a naively written self-test.

Measured one operation per process, machine otherwise idle:

| Operation | Result |
|---|---|
| `matmul` 1024x1024 fp16, and 256x256 | fine |
| `conv2d` 320->320 at 128x128, cuDNN off, 20x | fine |
| `conv2d` 320->320 at 128x128, **cuDNN on**, 20x | fine, 0.019s per call |
| `SDPA` 1x8x256x64, **mem-efficient disabled** | fine |
| **`SDPA` 1x8x256x64, default backends** | **driver reset** |
| **`SDPA` 1x8x4096x64, default backends** | **driver reset** |

Sequence length makes no difference, so this is not a kernel running past the `TdrDelay` timeout, which is 2 seconds by default: the small case finishes in milliseconds and still takes the driver down. Raising `TdrDelay` does not help.

The first SDPA call on the math backend can take minutes while ZLUDA JIT-compiles it. That is the normal first-run compile, not a hang.

**How bad the reset is depends on the architecture.** On gfx1031 the driver recovers on its own: the screen blinks, the event log says "successfully recovered", and the session carries on. On gfx1030 two of three resets hung hard enough to need the power button. Same trigger, same kernel error, worse consequences here.

#### Measuring this yourself, without fooling yourself

The table above took three wrong conclusions and three forced reboots to produce. The mistakes are easy to repeat:

- **One operation per process.** A process that runs several operations and then resets the driver tells you nothing about which one did it.
- **Establish a baseline first.** Run the operations you do not suspect, on their own, and confirm they are clean. If they are not, you are chasing something else.
- **Wait at least ten seconds before reading the event log.** Event 4101 is written about a second after the reset, so a query that fires immediately reports "clean" and sends you off building a theory on a false negative. Print the start and end time of each probe and line them up against the 4101 timestamps; the reset lands a second after the process ends.
- **Leave the machine alone while testing.** Viewing an image or playing a video is enough GPU work to confound the result.
- **The exit path is not the variable.** `os._exit` skipping CUDA context teardown looks like an obvious suspect and is not one: a clean exit resets the driver just the same, and a force-kill does not reset it when no SDPA was involved. Do not spend a round on it.

A reset recovers on its own more often than not, but two of the three here hung hard enough to need the power button. Save your work first.

### Kernels: the one place the two architectures differ

gfx1030 is on the official AMD ROCm support list and stock rocBLAS ships its kernels: a clean ROCm 6.4 install has 88 gfx1030 files in `bin\rocblas\library`. Nothing to do, and `Install-Kernels.ps1` refuses to run without `-Force`. Rewriting a shipped, working rocBLAS buys nothing and can only break it.

gfx1031 is not on that list, and official rocBLAS ships **no kernels for it at all**, so the first matmul dies with `no kernel image is available`. `scripts\Install-Kernels.ps1` fills the gap, two ways:

|  | Borrow (default) | Download |
|---|---|---|
| Network needed | no | yes |
| Third-party binaries | none | yes (upstream is GPL-3.0) |
| Works | yes, gfx1030 and gfx1031 are ISA-compatible | yes |
| Performance | tuning parameters were chosen for gfx1030 | compiled for actual gfx1031 |

Start with Borrow to get a working setup, switch to Download if it feels slow. Download mode replaces the rocBLAS library outright and keeps the original as `library.bak` next to it.

#### Why `.dat` needs an equal-length replacement

Borrow mode renames gfx1030 kernels to gfx1031. `.dat` files are rocBLAS binary manifests with hardcoded offsets, and `gfx1030` and `gfx1031` happen to be the same 7 bytes long, so the only safe edit is **overwriting those 7 bytes in place**. A text-mode replacement, or a rename to anything of a different length, corrupts the structure, and rocBLAS then fails to load with no useful diagnostic.

`.hsaco` and `.co` files are compiled code objects. Same ISA, so the contents are fine as they are and only the filename changes.

The naming is not consistent either: most files are `..._gfx1030.xxx`, but `Kernels.so-000-gfx1030.hsaco` uses a hyphen. Matching on `_gfx1030` alone silently skips it, along with every `.co` file.

### HIP SDK installed, but `bin` has no `amdhip64.dll`

The installer sometimes skips the core runtime, leaving `bin` without the one DLL that matters.

Take it from the driver package:

```
C:\Windows\System32\DriverStore\FileRepository\amdocl.inf_amd64_*\
```

Several versions live there, and you **must pick the one matching your installed display driver**. The wrong version crashes just the same.

### Several HIP versions side by side

Three things have to line up, and any one of them being wrong breaks everything:

1. **PATH order** - the `bin` directory of the version you want has to come first.
2. **`HIP_PATH`** - note that a **user-scope variable overrides the machine scope**. The installer writes the machine scope, so a user-scope value you set by hand silently wins. This one is easy to miss.
3. **The ZLUDA major version** - see the error table above.

`Check-Environment.ps1` checks all three.

### Which DLLs go into torch\lib

Copy these four from the `zluda` directory, renaming as shown:

| Source | Destination in `venv\Lib\site-packages\torch\lib` |
|---|---|
| `cublas.dll` | `cublas64_11.dll` |
| `cusparse.dll` | `cusparse64_11.dll` |
| `cufft.dll` | `cufft64_10.dll` |
| `nvrtc.dll` | `nvrtc64_112_0.dll` |

Two things are deliberately **not** copied:

- **`cublasLt.dll`**. torch keeps its own `cublasLt64_11.dll`, which is a few hundred MB against ZLUDA's ~180 KB. Copying every DLL in the directory, which looks like the obvious thing to do, breaks torch.
- **`nvcuda.dll`**. `zluda.exe` injects it with Detours at launch; it does not belong in `torch\lib`.

To verify, compare hashes: each destination file should hash identically to its source.

### Killing a stuck self-test

Under ZLUDA, python regularly refuses to exit after GPU work, spinning on CUDA context teardown. `os._exit()` does not help, because what is stuck is the `zluda.exe` layer underneath.

`Test-Setup.ps1` handles this by printing a sentinel line when the work is done and tearing down the whole process tree once it appears, rather than waiting for the process to end on its own.

## Still stuck

Run these two and include their output in an issue:

```powershell
.\scripts\Check-Environment.ps1
.\scripts\Test-Setup.ps1
```
