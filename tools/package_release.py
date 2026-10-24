"""Package the curated repository; verify runtime bytes and exclude user state."""
from pathlib import Path
import hashlib, json, zipfile

ROOT = Path(__file__).resolve().parent.parent
WARDEN = (ROOT / 'Warden').is_dir()
NAME = 'Warden-1.0.0' if WARDEN else 'Caretaker-Refinery-Intake-1.0.0'
FORBIDDEN = {'settings.ini', 'hotspots.tsv', 'destinations.tsv'}
manifest = json.loads((ROOT / 'Dateien.json').read_text(encoding='utf-8'))
files = {}
for item in manifest:
    rel = item['path']
    if WARDEN:
        prefix = 'Voyage/Binaries/Win64/ue4ss/Mods/'
        assert rel.startswith(prefix)
        source = ROOT / rel[len(prefix):]
    else:
        source = ROOT / rel
    assert source.resolve().is_relative_to(ROOT.resolve())
    assert source.name not in FORBIDDEN
    data = source.read_bytes()
    assert len(data) == item['bytes']
    assert hashlib.sha256(data).hexdigest() == item['sha256'], rel
    files[rel] = data
for name in ['README.md', 'LICENSE', 'CHANGELOG.md', 'RELEASE-NOTES.md', 'THIRD-PARTY-NOTICES.md', 'Dateien.json', 'ASSET-CHANGES.json', 'BUILDING.md', 'verification/release.json']:
    p = ROOT / name
    if p.exists():
        files[name] = p.read_bytes()
dist = ROOT / 'dist'
dist.mkdir(exist_ok=True)
target = dist / (NAME + '.zip')
with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name, data in sorted(files.items()):
        info = zipfile.ZipInfo(name, date_time=(2026, 10, 24, 12, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        z.writestr(info, data)
with zipfile.ZipFile(target) as z:
    assert z.testzip() is None
    assert all(Path(x).name not in FORBIDDEN for x in z.namelist())
digest = hashlib.sha256(target.read_bytes()).hexdigest()
(dist / 'SHA256SUMS.txt').write_text(digest + '  ' + target.name + '\n', encoding='ascii')
print(json.dumps(dict(name=target.name, bytes=target.stat().st_size, sha256=digest, runtimeFiles=len(manifest)), indent=2))
