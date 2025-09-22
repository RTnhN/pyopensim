#Requires -RunAsAdministrator
param (
  [switch]$s = $false,
  [switch]$h = $false,
  [string]$d = "Release",
  [string]$c = "main",
  [int]$j = [int]4,
  # New: allow Choco as a fallback only (default: off)
  [switch]$allowChoco = $false
)

# -------- Config (override via env vars if desired) --------
$DEBUG_TYPE   = if ($env:CMAKE_BUILD_TYPE) { $env:CMAKE_BUILD_TYPE } else { "Release" }
$NUM_JOBS     = if ($env:CMAKE_BUILD_PARALLEL_LEVEL) { [int]$env:CMAKE_BUILD_PARALLEL_LEVEL } else { 4 }
$OPENSIM_ROOT = Get-Location
$WORKSPACE_DIR = "$OPENSIM_ROOT\build\opensim-workspace"
$MOCO = "off"  # forced off (matches your original intent)

# Pin tool versions for reproducibility (override via env if needed)
$CMAKE_PYPI_VERSION = if ($env:CMAKE_PYPI_VERSION) { $env:CMAKE_PYPI_VERSION } else { "3.29.6" }
$NINJA_PYPI_VERSION = if ($env:NINJA_PYPI_VERSION) { $env:NINJA_PYPI_VERSION } else { "1.11.1.1" }
$CMAKE_CHOCO_VERSION = if ($env:CMAKE_CHOCO_VERSION) { $env:CMAKE_CHOCO_VERSION } else { "3.23.3" }

function Help {
    Write-Output "Setting up OpenSim with build type $DEBUG_TYPE, using $NUM_JOBS parallel jobs."
    Write-Output "Usage: setup_opensim_windows.ps1 [-s] [-h] [-d BuildType] [-c Branch] [-j Jobs] [--allowChoco]"
    Write-Output "  -s             : Disable MOCO (default: enabled) (currently forced OFF for compatibility)"
    Write-Output "  -h             : Show this help"
    Write-Output "  -d BuildType   : Build type (Release, Debug, RelWithDebInfo, MinSizeRel)"
    Write-Output "  -c Branch      : OpenSim core branch to use (default: main)"
    Write-Output "  -j Jobs        : Number of parallel jobs (default: 4)"
    Write-Output "  --allowChoco   : Allow Chocolatey fallback (quiet, no-progress). Default: off"
    exit
}

# Args → config
if ($h) { Help }
if ($s) { $MOCO = "off" } else { $MOCO = "off" } # keep forced OFF
if ($d -notin @("Release","Debug","RelWithDebInfo","MinSizeRel")) { Write-Error "Value for -d not valid."; Help } else { $DEBUG_TYPE = $d }
if ($c) { $CORE_BRANCH = $c }
if ($j -lt [int]1) { Write-Error "Value for -j not valid."; Help } else { $NUM_JOBS = $j }

Write-Output "Setting up OpenSim with build type: $DEBUG_TYPE using $NUM_JOBS jobs"
Write-Output "DEBUG_TYPE: $DEBUG_TYPE"
Write-Output "NUM_JOBS: $NUM_JOBS"
Write-Output "MOCO: $MOCO"
Write-Output "CORE_BRANCH: $CORE_BRANCH"
Write-Output "WORKSPACE_DIR: $WORKSPACE_DIR"
Write-Output "CMake (PyPI): $CMAKE_PYPI_VERSION | Ninja (PyPI): $NINJA_PYPI_VERSION | CMake (Choco fallback): $CMAKE_CHOCO_VERSION"
Write-Output "allowChoco: $allowChoco"

# -------- Helpers --------
function Command-Exists($name) {
  try { $null = Get-Command $name -ErrorAction Stop; return $true } catch { return $false }
}

function Ensure-Choco {
  if (-not (Command-Exists "choco")) {
    Write-Output "Chocolatey not found. Installing (quiet)..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  }
  # quiet progress
  $env:ChocolateyNoProgress = 'true'
}

function Ensure-Python {
  if (-not (Command-Exists "py") -and -not (Command-Exists "python")) {
    if ($allowChoco) {
      Ensure-Choco
      choco install python3 -y --no-progress
    } else {
      throw "Python not found and Chocolatey fallback disabled. Install Python first or pass --allowChoco."
    }
  }
}

function Pip {
  if (Command-Exists "py") { & py -m pip @args }
  elseif (Command-Exists "python") { & python -m pip @args }
  else { throw "Python launcher not found for pip." }
}

# -------- Workspace --------
if (-not (Test-Path -Path $WORKSPACE_DIR)) {
  New-Item -ItemType Directory -Path $WORKSPACE_DIR -Force | Out-Null
}

Write-Output "Building OpenSim from scratch..."
Write-Output "Installing build tools and dependencies (minimize Chocolatey)..."

# 1) Prefer PyPI for CMake + Ninja (quiet, reproducible)
Ensure-Python
Pip install --upgrade pip > $null 2>&1
Pip install "cmake==$CMAKE_PYPI_VERSION" "ninja==$NINJA_PYPI_VERSION"

# Verify cmake/ninja present, else optionally fallback to choco (quiet)
if (-not (Command-Exists "cmake")) {
  if ($allowChoco) {
    Write-Output "cmake not found after PyPI install; falling back to Chocolatey..."
    Ensure-Choco
    choco install cmake.install --version $CMAKE_CHOCO_VERSION --installargs '"ADD_CMAKE_TO_PATH=System"' -y --force --no-progress
  } else {
    throw "cmake not found and Chocolatey fallback disabled."
  }
}
if (-not (Command-Exists "ninja")) {
  # Note: Ninja is optional for your VS generator path, but check anyway.
  Write-Output "ninja not found; build will use Visual Studio generator."
}

# 2) Visual Studio Build Tools: install only if missing (skip on GitHub runners that already have MSVC)
$msvcFound = $false
try {
  $clPath = (Get-Command cl.exe -ErrorAction Stop).Source
  if ($clPath) { $msvcFound = $true }
} catch {}
if (-not $msvcFound) {
  Write-Output "MSVC not detected; ensuring Visual Studio Build Tools..."
  if ($allowChoco) {
    Ensure-Choco
    # Community + native desktop workload (quiet, no progress)
    choco install visualstudio2022community -y --no-progress
    choco install visualstudio2022-workload-nativedesktop -y --no-progress
    choco install visualstudio2022buildtools -y --no-progress
  } else {
    Write-Output "Skipping Visual Studio installation because --allowChoco is not set. Ensure MSVC is available."
  }
}

# 3) Other dependencies (try to avoid unless needed)
# You had: jdk8, swig(4.1.1), nsis, numpy
# Keep pip numpy (quiet), and only use choco for others if missing & allowed.
Pip install "numpy" > $null 2>&1

function Ensure-Tool-OrChoco($cmd, $chocoPkg, $version = $null) {
  if (Command-Exists $cmd) { return }
  if ($allowChoco) {
    Ensure-Choco
    if ($null -ne $version) {
      choco install $chocoPkg -y --no-progress --version $version
    } else {
      choco install $chocoPkg -y --no-progress
    }
  } else {
    Write-Output "Skipping install of $cmd ($chocoPkg); not present and --allowChoco not set."
  }
}

# Java (jdk8), SWIG, NSIS
Ensure-Tool-OrChoco "javac" "jdk8"
Ensure-Tool-OrChoco "swig" "swig" "4.1.1"
Ensure-Tool-OrChoco "makensis" "nsis"

# (Optional) refreshenv only if choco was used
if ($allowChoco -and (Command-Exists "choco")) {
  $env:ChocolateyInstall = Convert-Path "$((Get-Command choco).Path)\..\.."
  Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1" -ErrorAction SilentlyContinue
  refreshenv
}

Write-Output "Building OpenSim dependencies..."

# -------- Dependencies superbuild --------
$DEPENDENCIES_BUILD_DIR = "$WORKSPACE_DIR\opensim-dependencies-build"
$DEPENDENCIES_INSTALL_DIR = "$WORKSPACE_DIR\opensim-dependencies-install"

if (-not (Test-Path -Path $DEPENDENCIES_BUILD_DIR)) {
  New-Item -ItemType Directory -Path $DEPENDENCIES_BUILD_DIR -Force | Out-Null
}
Set-Location $DEPENDENCIES_BUILD_DIR

cmake "$OPENSIM_ROOT\src\opensim-core\dependencies" `
  -G"Visual Studio 17 2022" -A x64 `
  -DCMAKE_INSTALL_PREFIX="$DEPENDENCIES_INSTALL_DIR" `
  -DSUPERBUILD_ezc3d:BOOL=on `
  -DOPENSIM_WITH_CASADI:BOOL=$MOCO

cmake . -LAH
cmake --build . --config $DEBUG_TYPE -- /maxcpucount:$NUM_JOBS /p:CL_MPCount=1

Write-Output "Building OpenSim core..."

# -------- OpenSim core --------
$OPENSIM_BUILD_DIR = "$WORKSPACE_DIR\opensim-build"
$OPENSIM_INSTALL_DIR = "$WORKSPACE_DIR\opensim-install"

if (-not (Test-Path -Path $OPENSIM_BUILD_DIR)) {
  New-Item -ItemType Directory -Path $OPENSIM_BUILD_DIR -Force | Out-Null
}
Set-Location $OPENSIM_BUILD_DIR
$env:CXXFLAGS = "/W0 /utf-8 /bigobj"
$env:CL = "/MP1"

cmake "$OPENSIM_ROOT\src\opensim-core" `
  -G"Visual Studio 17 2022" -A x64 `
  -DCMAKE_INSTALL_PREFIX="$OPENSIM_INSTALL_DIR" `
  -DOPENSIM_DEPENDENCIES_DIR="$DEPENDENCIES_INSTALL_DIR" `
  -DBUILD_JAVA_WRAPPING=OFF `
  -DBUILD_PYTHON_WRAPPING=OFF `
  -DBUILD_TESTING=OFF `
  -DOPENSIM_C3D_PARSER=ezc3d `
  -DOPENSIM_WITH_CASADI:BOOL=$MOCO `
  -DOPENSIM_INSTALL_UNIX_FHS=OFF

cmake . -LAH
cmake --build . --config $DEBUG_TYPE -- /maxcpucount:$NUM_JOBS /p:CL_MPCount=1
cmake --install .

Write-Output "OpenSim setup complete. Libraries installed in: $OPENSIM_INSTALL_DIR"
