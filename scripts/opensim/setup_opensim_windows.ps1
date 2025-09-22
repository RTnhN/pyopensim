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

# ------------------------------------------------------------------------------------
# PY310 support: Resolve Python 3.10 include/lib/exe and prep CMake args
# (Does NOT enable Python wrapping; only makes python310.lib discoverable.)
# ------------------------------------------------------------------------------------
$cmakePythonArgs = @()
$PY_OK = $false

try {
    # Prefer the launcher to target 3.10 explicitly
    $pyExe = (Get-Command "py" -ErrorAction SilentlyContinue)
    if ($pyExe) {
        $py310Path = & py -3.10 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $py310Path) {
            $PY_OK = $true
            $py310Include = & py -3.10 -c "import sysconfig; print(sysconfig.get_paths()['include'])"
            $py310LibDir  = & py -3.10 -c "import sysconfig; import os; print(sysconfig.get_config_var('LIBDIR') or os.path.join(sys.base_prefix,'libs'))"
            $py310LibName = & py -3.10 -c "import sysconfig; print(sysconfig.get_config_var('LIBRARY') or 'python310.lib')"
            if (-not $py310LibName) { $py310LibName = "python310.lib" }

            $py310Lib = Join-Path $py310LibDir $py310LibName
            if (-not (Test-Path $py310Lib)) {
                # Fallback: common Windows layout e.g. C:\hostedtoolcache\windows\Python\3.10.x\x64\libs\python310.lib
                $candidate = Join-Path (Join-Path (Split-Path -Parent $py310Path) "libs") "python310.lib"
                if (Test-Path $candidate) { $py310Lib = $candidate }
            }

            if (-not (Test-Path $py310Lib)) {
                Write-Warning "Could not find python310.lib; continuing without explicit PY lib args."
            } else {
                $cmakePythonArgs += @(
                    "-DPython3_EXECUTABLE=$py310Path",
                    "-DPython3_INCLUDE_DIR=$py310Include",
                    "-DPython3_LIBRARY=$py310Lib",
                    # Some projects still read legacy names:
                    "-DPYTHON_EXECUTABLE=$py310Path",
                    "-DPYTHON_INCLUDE_DIR=$py310Include",
                    "-DPYTHON_LIBRARY=$py310Lib"
                )

                # Also hint the MSVC environment in case anything uses LIB/INCLUDE scanning
                $env:INCLUDE = ($env:INCLUDE, $py310Include) -join ";"
                $env:LIB     = ($env:LIB, (Split-Path -Parent $py310Lib)) -join ";"

                Write-Output "Python 3.10 detected:"
                Write-Output "  EXE : $py310Path"
                Write-Output "  INC : $py310Include"
                Write-Output "  LIB : $py310Lib"
            }
        }
    }
} catch {
    Write-Warning "Python 3.10 discovery failed: $($_.Exception.Message)"
}

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
    -DOPENSIM_WITH_CASADI:BOOL=$MOCO `
    @cmakePythonArgs

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
    -DOPENSIM_INSTALL_UNIX_FHS=OFF `
    @cmakePythonArgs

cmake . -LAH
cmake --build . --config $DEBUG_TYPE -- /maxcpucount:$NUM_JOBS /p:CL_MPCount=1
cmake --install .

# ------------------------------------------------------------------------------------
# PY310 support: copy python310.lib into install lib (optional convenience)
# ------------------------------------------------------------------------------------
try {
    if ($PY_OK) {
        $pyLibDir = & py -3.10 -c "import sys, sysconfig, os; print(sysconfig.get_config_var('LIBDIR') or os.path.join(sys.base_prefix,'libs'))"
        $pyLib = Join-Path $pyLibDir "python310.lib"
        $dest = Join-Path $OPENSIM_INSTALL_DIR "lib"
        if (Test-Path $pyLib) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Copy-Item -LiteralPath $pyLib -Destination $dest -Force
            Write-Output "Copied python310.lib to $dest"
        } else {
            Write-Warning "python310.lib not found for post-install copy."
        }
    }
} catch {
    Write-Warning "Post-install python310.lib copy failed: $($_.Exception.Message)"
}

Write-Output "OpenSim setup complete. Libraries installed in: $OPENSIM_INSTALL_DIR"
