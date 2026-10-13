"""Run against libarchive's official RAR / RAR5 uuencoded test fixtures."""
import binascii
import pathlib
import subprocess
import tempfile
import urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
exe = root / '压缩助手.app/Contents/MacOS/ArchiveAssistant'
base = 'https://raw.githubusercontent.com/libarchive/libarchive/master/libarchive/test/'
with tempfile.TemporaryDirectory() as tmp:
    folder = pathlib.Path(tmp)
    for fixture in ['test_read_format_rar.rar', 'test_read_format_rar5_stored.rar']:
        encoded = urllib.request.urlopen(base + fixture + '.uu').read().splitlines()
        content = b''.join(binascii.a2b_uu(line) for line in encoded[1:] if line not in (b'end', b'`', b' '))
        archive = folder / fixture
        archive.write_bytes(content)
        run = subprocess.run([str(exe), '--extract', str(archive), tmp], capture_output=True, text=True)
        assert run.returncode == 0, run.stderr
        output = pathlib.Path(run.stdout.strip())
        assert any(p.is_file() for p in output.rglob('*'))
        before = {p.relative_to(output): p.read_bytes() for p in output.rglob('*') if p.is_file()}
        second = subprocess.run([str(exe), '--extract', str(archive), tmp], capture_output=True, text=True)
        assert second.returncode == 0, second.stderr
        assert pathlib.Path(second.stdout.strip()) != output
        assert before == {p.relative_to(output): p.read_bytes() for p in output.rglob('*') if p.is_file()}
        print('PASS:', fixture, 'extraction and existing output protection')
    broken = folder / 'broken.rar'
    broken.write_bytes(b'not a rar archive')
    run = subprocess.run([str(exe), '--extract', str(broken), tmp], capture_output=True)
    assert run.returncode != 0
    assert not list(folder.glob('.rar-extract-*'))
    assert not (folder / 'broken').exists()
    print('PASS: corrupt archive reports failure and cleans temporary output')
