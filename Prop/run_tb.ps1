param(
  [string]$RepoDir = $PSScriptRoot,
  [string]$BuildRoot = "C:\hdl\prop_build",
  [string]$MsysRoot = "C:\msys64",
  [switch]$KeepObjDir,

  # Actual simulation clock (overrides tb_vcnpu_integrated.sv CLK_PERIOD)
  [Nullable[double]]$SimClkMhz = $null,

  # Optional performance-reporting overrides (passed as Verilator -G params)
  [Nullable[double]]$PerfTargetClkMhz = $null,
  [Nullable[double]]$PerfIoCapGbps = $null,
  [Nullable[double]]$PerfIoEff = $null,
  [Nullable[double]]$PerfIoBytesPerPatch = $null,
  [Nullable[int]]$PerfPatchSide = $null,

  [string]$RefMemh,
  [string]$PatchMemh
)

$ErrorActionPreference = 'Stop'

$src = Join-Path $RepoDir "Prop"
if (-not (Test-Path $src)) {
  # If user runs from within Prop already
  $src = $RepoDir
}
if (-not (Test-Path (Join-Path $src "tb_vcnpu_integrated.sv"))) {
  throw "Cannot find tb_vcnpu_integrated.sv under '$src'. Run this script from the repo root or Prop folder."
}

$bash = Join-Path $MsysRoot "usr\bin\bash.exe"
$envExe = Join-Path $MsysRoot "usr\bin\env.exe"
if (-not (Test-Path $bash)) { throw "MSYS2 bash not found at $bash" }
if (-not (Test-Path $envExe)) { throw "MSYS2 env.exe not found at $envExe" }

$dstSrc = Join-Path $BuildRoot "src"
$simDir = Join-Path $BuildRoot "sim"
New-Item -ItemType Directory -Force -Path $dstSrc | Out-Null
New-Item -ItemType Directory -Force -Path $simDir | Out-Null

# Optional: stage memh files into sim dir (no spaces) and pass plusargs
$simPlusArgs = @()
if ($RefMemh) {
  $refPath = (Resolve-Path $RefMemh).Path
  $refDst = Join-Path $simDir "ref.memh"
  Copy-Item -Force $refPath $refDst
  $simPlusArgs += "+ref_memh=ref.memh"
}
if ($PatchMemh) {
  $patchPath = (Resolve-Path $PatchMemh).Path
  $patchDst = Join-Path $simDir "patch.memh"
  Copy-Item -Force $patchPath $patchDst
  $simPlusArgs += "+patch_memh=patch.memh"
}
$simPlusArgsStr = ($simPlusArgs -join ' ')

Write-Host "[1/3] Mirroring RTL into no-spaces build dir..."
# Exclude large docs; keep RTL/tb
robocopy "$src" "$dstSrc" /MIR /XF "*.pdf" "*.md" | Out-Null

Write-Host "[2/3] Generating Windows-path filelist..."
& $envExe MSYSTEM=UCRT64 CHERE_INVOKING=1 $bash -lc @'
set -euo pipefail
cd /c/hdl/prop_build/sim
SRC=/c/hdl/prop_build/src
# Exclusions:
# - MODULE_INTERFACES.v has a duplicate global_controller module
# - tb_transforms.sv is a separate unit TB (and can trip Verilator parsing)
find "$SRC" -maxdepth 1 \( -name \*.sv -o -name \*.v \) \
  ! -name MODULE_INTERFACES.v \
  ! -name tb_transforms.sv \
  -print | while IFS= read -r f; do cygpath -m "$f"; done > filelist_win.f
'@

Write-Host "[3/3] Building + running tb_vcnpu_integrated..."
$keep = if ($KeepObjDir) { "" } else { "rm -rf obj_dir" }

# Build optional Verilator -G overrides for TB parameters
$gFlags = @()
if ($null -ne $SimClkMhz) {
  if ($SimClkMhz -le 0) { throw "-SimClkMhz must be > 0" }
  $clkPeriodNs = 1000.0 / $SimClkMhz
  $gFlags += "-GCLK_PERIOD=$clkPeriodNs"
}
if ($null -ne $PerfTargetClkMhz) { $gFlags += "-GPERF_TARGET_CLK_MHZ=$PerfTargetClkMhz" }
if ($null -ne $PerfIoCapGbps) { $gFlags += "-GPERF_REAL_IO_GBPS_OVERRIDE=$PerfIoCapGbps" }
if ($null -ne $PerfIoEff) { $gFlags += "-GPERF_REAL_IO_EFF=$PerfIoEff" }
if ($null -ne $PerfIoBytesPerPatch) { $gFlags += "-GPERF_REAL_IO_BYTES_PER_PATCH_OVERRIDE=$PerfIoBytesPerPatch" }
if ($null -ne $PerfPatchSide) { $gFlags += "-GPERF_PATCH_SIDE=$PerfPatchSide" }
$gFlagsStr = ($gFlags -join ' ')

if ($gFlagsStr) {
  Write-Host "[info] Verilator TB overrides: $gFlagsStr"
}
if ($simPlusArgsStr) {
  Write-Host "[info] Simulator plusargs: $simPlusArgsStr"
}

& $envExe MSYSTEM=UCRT64 CHERE_INVOKING=1 $bash -lc @"
set -euo pipefail
cd /c/hdl/prop_build/sim
$keep
rm -f build.log run.log
verilator --binary -sv --timing --output-split 0 -Wall -Wno-fatal \
  -Wno-DECLFILENAME -Wno-UNUSED -Wno-WIDTH -Wno-CASEINCOMPLETE \
  $gFlagsStr \
  --top-module tb_vcnpu_integrated -f filelist_win.f > build.log 2>&1
./obj_dir/Vtb_vcnpu_integrated $simPlusArgsStr 2>&1 | tee run.log
"@

Write-Host "\n=== Tail(run.log) ==="
Get-Content (Join-Path $simDir "run.log") -Tail 40

Write-Host "\n=== Head(run.log) ==="
Get-Content (Join-Path $simDir "run.log") -Head 60

Write-Host "\n=== Key TB lines (load/config) ==="
$runLogPath = (Join-Path $simDir "run.log")
Select-String -Path $runLogPath -Pattern "^\[TB\]|\[Suite\]|VCNPU Integrated System Test" -ErrorAction SilentlyContinue |
  Select-Object -First 60 |
  ForEach-Object { $_.Line }

# Basic PASS/FAIL indicator
$tail = Get-Content (Join-Path $simDir "run.log") -Tail 200
if ($tail -match "Status:\s+PASSED") {
  Write-Host "\nRESULT: PASSED" -ForegroundColor Green
  exit 0
}

Write-Host "\nRESULT: (did not find PASSED marker)" -ForegroundColor Yellow
exit 1
