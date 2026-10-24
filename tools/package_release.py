"""Build a deterministic runtime-only ZIP; documentation stays in the repository."""
from pathlib import Path, PurePosixPath
import argparse, hashlib, json, zipfile

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = 'Warden-1.0.0.zip'
KIND = 'warden'

def runtime_path(name):
    p = PurePosixPath(name)
    return (name.startswith('Voyage/') and '..' not in p.parts and '\\' not in name
            and (p.suffix in {'.pak', '.ucas', '.utoc', '.lua', '.dll', '.ini'}
                 or p.name.endswith('.tlcaddon.json')
                 or p.name in {'enabled.txt', 'mods.txt', 'load_order.txt'}))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=ROOT/'build-runtime-only/package',
                        help='Energy only: directory containing the four verified built files')
    args = parser.parse_args()
    rows = json.loads((ROOT/'Dateien.json').read_text(encoding='utf-8'))
    expected = {row['path'] for row in rows}
    assert len(rows) == len(expected) == 32, 'Unexpected runtime manifest'
    files = {}
    for row in rows:
        name = row['path']
        assert runtime_path(name), 'Non-runtime or unsafe path: '+name
        assert PurePosixPath(name).name not in {'settings.ini', 'destinations.tsv', 'hotspots.tsv'}
        if KIND == 'energy':
            source = args.package/PurePosixPath(name).name
        elif KIND == 'warden':
            prefix = 'Voyage/Binaries/Win64/ue4ss/Mods/'
            assert name.startswith(prefix)
            source = ROOT/name.removeprefix(prefix)
        else:
            source = ROOT/name
        data = source.read_bytes()
        assert len(data) == row['bytes'] and hashlib.sha256(data).hexdigest() == row['sha256'], name
        if source.suffix not in {'.pak', '.ucas', '.utoc', '.dll'}:
            text = data.decode('utf-8')
            for private in ['C:\\Users\\', 'C:/Users/', 'E:\\Program Files\\GitHub',
                            'E:/Program Files/GitHub', 'ghp_', 'glpat-', 'gho_']:
                assert private not in text, 'Private marker in '+name
        files[name] = data
    if KIND in {'wireless', 'refinery-intake'}:
        actual = {p.relative_to(ROOT).as_posix() for p in (ROOT/'Voyage').rglob('*')
                  if p.is_file() and runtime_path(p.relative_to(ROOT).as_posix())}
        assert actual == expected, 'Unlisted runtime files'
    out = ROOT/'dist'; out.mkdir(exist_ok=True)
    target = out/ARCHIVE
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 24, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, data, compresslevel=9)
    with zipfile.ZipFile(target) as z:
        assert z.testzip() is None and set(z.namelist()) == expected
        for row in rows: assert hashlib.sha256(z.read(row['path'])).hexdigest() == row['sha256']
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    checksum = 'Energy-SHA256SUMS.txt' if KIND == 'energy' else 'SHA256SUMS.txt'
    (out/checksum).write_text(digest+'  '+target.name+'\n', encoding='ascii')
    print(json.dumps(dict(file=target.name, bytes=target.stat().st_size, sha256=digest,
                          runtimeFiles=len(files), runtimeOnly=True), indent=2))

if __name__ == '__main__':
    main()
