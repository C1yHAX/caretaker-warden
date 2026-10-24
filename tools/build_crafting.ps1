param([string]$Zig = (Join-Path $PSScriptRoot 'vendor/zig-windows-x86_64-0.13.0/zig.exe'))
$ErrorActionPreference = 'Stop'
$wardenRoot = Split-Path $PSScriptRoot -Parent
Push-Location $wardenRoot
try {
    New-Item -ItemType Directory -Path validation/native-build -Force | Out-Null
    $wardenNativeSources = @('native/third_party/minhook/src/hook.c', 'native/third_party/minhook/src/buffer.c',
        'native/third_party/minhook/src/trampoline.c', 'native/third_party/minhook/src/hde/hde64.c')
    & $Zig cc -shared -O2 -std=c11 -Wall -Wextra -Werror native/crafting.c @wardenNativeSources -lbcrypt -o validation/native-build/warden_crafting.dll
    if ($LASTEXITCODE) { throw 'Herstellungsmodul konnte nicht gebaut werden.' }
    & $Zig cc -O2 -std=c11 -Wall -Wextra -Werror -Wno-unused-variable native/test_crafting.c @wardenNativeSources -lbcrypt -o validation/test_crafting_native.exe
    if ($LASTEXITCODE) { throw 'Native Tests konnten nicht gebaut werden.' }
    & ./validation/test_crafting_native.exe
    if ($LASTEXITCODE) { throw 'Native Tests fehlgeschlagen.' }
    Copy-Item -LiteralPath validation/native-build/warden_crafting.dll -Destination Warden/Scripts/native/warden_crafting.dll -Force
} finally { Pop-Location }
