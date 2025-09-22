#Requires -RunAsAdministrator
param (
  [switch]$s=$false,
  [switch]$h=$false,
  [string]$d="Release",
  [string]$c="main",
  [int]$j=[int]4
)

# Configuration - use environment variables if set, otherwise use defaults
$DEBUG_TYPE = if ($env:CMAKE_BUILD_TYPE) { $env:CMAKE_BUILD_TYPE } else { "Release" }
$NUM_JOBS   = if ($env:CMAKE_BUILD_PARALLEL_LEVEL) { [int]$env:CMAKE_BUILD_PARALLEL_LEVEL } else { 4 }
$OPENSIM_ROOT = Get-Location
$WORKSPACE_DIR = "$OPENSIM_ROOT\build\opensim-workspace"
$MOCO = "off"  # Default MOCO setting (disabled for compatibility)
$CORE_BRANCH = if ($c) { $c } else { "main" }

function Help {
    Write-Output "Setting up OpenSim with build type $DEBUG_TYPE, using $NUM_JOBS parallel jobs."
    Write-Output "Usage: setup_opensim_windows.ps1 [-s] [-h] [-d BuildType] [-c Branch] [-j Jobs]"
    Write-Output "  -s          : Disable MOCO (default: disabled)"
    Write-Output "  -h          : Show this help"
    Write-Output "  -d BuildType: Build type (Release, Debug, RelWithDebInfo, MinSizeRel)"
    Write-Output "  -c Branch   : OpenSim core branch to use (default: main)"
    Write-Output "  -j Jobs     : Number of parallel jobs (default: 4)"
    exit
}

# Get flag values if exist.
if ($h) { Help }
if ($s) {
    $MOCO = "off"
} else {
    $MOCO = "off"  # Force disable MOCO to avoid spdlog linking issues
}
if ($d -notin @("Release","Debug","RelWithDebInfo","MinSizeRel")) {
    Write-Error "Value for parameter -d not valid."
    Help
} else {
    $DEBUG_TYPE = $d
}
if ($j -lt [int]1) {
    Write-Error "Value for parameter -j not valid."
    Help
} else {
    $NUM_JOBS = $j
}

Write-Output "Setting up OpenSim with build type: $DEBUG_TYPE using $NUM_JOBS jobs"
Write-Output "DEBUG_TYPE: $DEBUG_TYPE"
Write-Output "NUM_JOBS: $NUM_JOBS"
Write-Output "MOCO: $MOCO"
Write-Output "CORE_BRANCH: $CORE_BRANCH"
Write-Output "WORKSPACE_DIR: $WORKSPACE_DIR"

# ------------------------------------------------------------------------------------
# Use ONLY default tools preinstalled on GitHub Windows runners (no Chocolatey).
# Validate required tools.
# ------------------------------------------------------------------------------------
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    throw "CMake not found in PATH. The GitHub runner image should include it (Tools: CMake 3.31.x)."
}

$vswherePath = Join-Path "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer" "vswhere.exe"
if (-not (Test-Path $vswherePath)) {
    throw "vswhere.exe not found. Visual Studio 2022 should be installed on the runner."
}

# Confirm VS 2022 with Desktop C++ is available
$vsInstall = & $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
if (-not $vsInstall) {
    throw "Visual Studio 2022 with C++ toolset not found. Ensure the runner has Native Desktop workload."
}

# Optional: ensure Python present if your build or scripts need it (no global install)
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Warning "Python launcher 'py' not found. The GitHub runner usually has multiple Pythons preinstalled."
}
# If you need numpy later, you could do: py -3.9 -m pip install --user numpy

# ------------------------------------------------------------------------------------
# Create workspace
# ------------------------------------------------------------------------------------
if (-not (Test-Path -Path $WORKSPACE_DIR)) {
    New-Item -ItemType Directory -Path $WORKSPACE_DIR -Force | Out-Null
}

Write-Output "Building OpenSim from scratch using preinstalled toolchain..."

# ------------------------------------------------------------------------------------
# Build dependencies (Superbuild)
# ------------------------------------------------------------------------------------
Write-Output "Building OpenSim dependencies..."

$DEPENDENCIES_BUILD_DIR   = "$WORKSPACE_DIR\opensim-dependencies-build"
$DEPENDENCIES_INSTALL_DIR = "$WORKSPACE_DIR\opensim-dependencies-install"

if (-not (Test-Path -Path $DEPENDENCIES_BUILD_DIR)) {
    New-Item -ItemType Directory -Path $DEPENDENCIES_BUILD_DIR -Force | Out-Null
}

Set-Location $DEPENDENCIES_BUILD_DIR

# If you prefer Ninja (preinstalled), uncomment the next two lines and remove -G"Visual Studio 17 2022" -A x64 below.
# $env:CMAKE_GENERATOR="Ninja"
# $generatorArgs = @()

$generatorArgs = @('-G','Visual Studio 17 2022','-A','x64')

cmake "$OPENSIM_ROOT\src\opensim-core\dependencies" `
    @generatorArgs `
    -DCMAKE_INSTALL_PREFIX="$DEPENDENCIES_INSTALL_DIR" `
    -DSUPERBUILD_ezc3d:BOOL=on `
    -DOPENSIM_WITH_CASADI:BOOL=$MOCO

cmake . -LAH
cmake --build . --config $DEBUG_TYPE -- /maxcpucount:$NUM_JOBS /p:CL_MPCount=1

# ------------------------------------------------------------------------------------
# Build OpenSim core
# ------------------------------------------------------------------------------------
Write-Output "Building OpenSim core..."

$OPENSIM_BUILD_DIR   = "$WORKSPACE_DIR\opensim-build"
$OPENSIM_INSTALL_DIR = "$WORKSPACE_DIR\opensim-install"

if (-not (Test-Path -Path $OPENSIM_BUILD_DIR)) {
    New-Item -ItemType Directory -Path $OPENSIM_BUILD_DIR -Force | Out-Null
}

Set-Location $OPENSIM_BUILD_DIR
$env:CXXFLAGS = "/W0 /utf-8 /bigobj"
$env:CL = "/MP1"

cmake "$OPENSIM_ROOT\src\opensim-core" `
    @generatorArgs `
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
