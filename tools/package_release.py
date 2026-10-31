"""Build and verify the complete runtime-only Warden release ZIP."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = 'Warden-1.0.0.zip'
PREFIX = 'Voyage/Binaries/Win64/ue4ss/Mods/Warden/'
DEFAULT_CONFIG = ROOT / 'config/settings.ini'
DEFAULTS = dict(language='de', toggleKey='F1', position='left',
                walk='true', block='true', trace='false')
REQUIRED = {PREFIX + path for path in (
    'enabled.txt', 'settings.ini', 'Scripts/main.lua', 'Scripts/core.lua',
    'Scripts/i18n.lua', 'Scripts/locales/en.lua', 'Scripts/data/item_paths.lua',
    'Scripts/data/item_types.lua', 'Scripts/native/warden_crafting.dll',
)}
EXTERNAL_MODULES = {'UEHelpers'}  # Supplied by the documented UE4SS prerequisite.


def runtime_path(name):
    path = PurePosixPath(name)
    if not name.startswith(PREFIX) or '..' in path.parts or '\\' in name:
        return False
    relative = name.removeprefix(PREFIX)
    return (relative in {'enabled.txt', 'settings.ini'}
            or (relative.startswith('Scripts/') and path.suffix in {'.lua', '.dll'}))


def config_values(data):
    return dict(re.findall(r'^\s*(\w+)\s*=\s*([^\r\n]*?)\s*$',
                           data.decode('utf-8-sig'), re.MULTILINE))


def verify_dependencies(files):
    """Catch omissions even when somebody also omits the file from the manifest."""
    assert REQUIRED <= files.keys(), 'Missing required runtime files: ' + str(REQUIRED - files.keys())
    assert config_values(files[PREFIX + 'settings.ini']) == DEFAULTS, 'Non-default release settings'
    modules = {name.removeprefix(PREFIX + 'Scripts/')[:-4].replace('/', '.')
               for name in files if name.startswith(PREFIX + 'Scripts/') and name.endswith('.lua')}
    pattern = r'''(?:\brequire\s*\(?\s*|\bpcall\s*\(\s*require\s*,\s*)["']([^"']+)["']'''
    for name, data in files.items():
        if not name.endswith('.lua'):
            continue
        for module in re.findall(pattern, data.decode('utf-8')):
            assert module in modules or module in EXTERNAL_MODULES, f'{name}: missing Lua module {module}'


def build():
    rows = json.loads((ROOT / 'Dateien.json').read_text(encoding='utf-8'))
    expected = {row['path'] for row in rows}
    assert rows and len(rows) == len(expected), 'Empty or duplicate runtime manifest'
    actual = {PREFIX + p.relative_to(ROOT / 'Warden').as_posix()
              for p in (ROOT / 'Warden/Scripts').rglob('*') if p.is_file()
              and runtime_path(PREFIX + p.relative_to(ROOT / 'Warden').as_posix())}
    actual.update({PREFIX + 'enabled.txt', PREFIX + 'settings.ini'})
    assert actual == expected, f'Unlisted or unexpected runtime files: {actual ^ expected}'
    files = {}
    for row in rows:
        name = row['path']
        assert runtime_path(name), 'Non-runtime or unsafe path: ' + name
        relative = name.removeprefix(PREFIX)
        # Never publish a developer's or installed user's settings. Only this template.
        source = DEFAULT_CONFIG if relative == 'settings.ini' else ROOT / 'Warden' / relative
        data = source.read_bytes()
        assert len(data) == row['bytes'] and hashlib.sha256(data).hexdigest() == row['sha256'], name
        if source.suffix != '.dll':
            text = data.decode('utf-8')
            for private in ['C:\\Users\\', 'C:/Users/', 'E:\\Program Files\\GitHub',
                            'E:/Program Files/GitHub', 'ghp_', 'glpat-', 'gho_']:
                assert private not in text, 'Private marker in ' + name
        files[name] = data
    verify_dependencies(files)
    out = ROOT / 'dist'
    out.mkdir(exist_ok=True)
    target = out / ARCHIVE
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 24, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compresslevel=9)
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None and len(archive.namelist()) == len(expected)
        assert set(archive.namelist()) == expected
        packaged = {name: archive.read(name) for name in archive.namelist()}
        assert packaged == files, 'ZIP contents differ from checked runtime files'
        verify_dependencies(packaged)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (out / 'SHA256SUMS.txt').write_text(digest + '  ' + target.name + '\n', encoding='ascii')
    return dict(file=target.name, bytes=target.stat().st_size, sha256=digest,
                runtimeFiles=len(files), runtimeOnly=True, defaultSettingsIncluded=True)


if __name__ == '__main__':
    print(json.dumps(build(), indent=2))
