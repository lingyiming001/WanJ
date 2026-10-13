"""Integration tests exercise the same engine used by the native interface."""
import bz2
import gzip
import io
import pathlib
import subprocess
import tarfile
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
exe = root / '压缩助手.app/Contents/MacOS/ArchiveAssistant'


def run(*args, success=True):
    result = subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True, timeout=60)
    assert (result.returncode == 0) == success, result.stderr
    return pathlib.Path(result.stdout.strip()) if success else result


with tempfile.TemporaryDirectory() as temp:
    base = pathlib.Path(temp)
    source = base / '中文 文件夹'
    source.mkdir()
    (source / '子目录').mkdir()
    (source / '空目录').mkdir()
    (source / '子目录' / '文本.txt').write_text('中文内容\n' * 300, encoding='utf-8')
    (source / '.hidden').write_bytes(b'hidden')
    (source / 'empty').write_bytes(b'')
    (source / 'binary.bin').write_bytes(bytes(range(256)) * 30)
    other = base / 'other'
    other.mkdir()
    special = other / '@特殊 -file.txt'
    special.write_bytes(b'other directory')
    leading = other / '-option.txt'
    leading.write_bytes(b'leading dash')
    output = base / 'output'
    output.mkdir()
    expected = {p.relative_to(source): p.read_bytes() for p in source.rglob('*') if p.is_file()}
    for fmt in ['zip', '7z', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz']:
        archive = run('--compress', fmt, output, '归档', source, special, leading)
        assert archive.name == '归档.' + fmt
        second = run('--compress', fmt, output, '归档', source, special, leading)
        assert second.name == '归档 (2).' + fmt
        extracted = run('--extract', archive, output)
        assert extracted.name == '归档' or extracted.name.startswith('归档 (')
        tree = extracted / source.name
        actual = {p.relative_to(tree): p.read_bytes() for p in tree.rglob('*') if p.is_file()}
        assert actual == expected, (fmt, actual.keys())
        assert (tree / '空目录').is_dir(), fmt
        assert (extracted / special.name).read_bytes() == special.read_bytes()
        assert (extracted / leading.name).read_bytes() == leading.read_bytes()
        if fmt == 'zip':
            with zipfile.ZipFile(archive) as independent:
                assert independent.testzip() is None
                assert independent.read('./' + source.name + '/子目录/文本.txt') == (source / '子目录' / '文本.txt').read_bytes()
        print('PASS:', fmt, 'multi-source round trip, Unicode, hidden files, empty directory, collision protection')

    # Save inside a selected folder without including the in-progress archive.
    nested = run('--compress', 'zip', source, '内部保存', source)
    with zipfile.ZipFile(nested) as z:
        assert not any('.archive-job-' in name for name in z.namelist())
    print('PASS: destination inside source excludes active job')

    for extension, encode in [('gz', gzip.compress), ('bz2', bz2.compress)]:
        stream = base / ('单文件.txt.' + extension)
        stream.write_bytes(encode(b'compressed stream\n'))
        extracted = run('--extract', stream, output)
        assert (extracted / '单文件.txt').read_bytes() == b'compressed stream\n'
        print('PASS:', extension, 'single stream decompression')

    duplicate = other / source.name
    duplicate.mkdir()
    run('--compress', 'zip', output, '重复', source, duplicate, success=False)
    run('--compress', 'zip', output, '../越界', source, success=False)
    run('--compress', 'zip', output, '丢失', base / 'missing', success=False)
    run('--compress', 'zip', base / 'missing-destination', '失败', source, success=False)
    print('PASS: duplicate names, invalid output name, missing inputs and destination rejected')

    # Traversal archive must not write into the parent of the fresh extraction tree.
    hostile = base / 'hostile.tar'
    with tarfile.open(hostile, 'w') as t:
        entry = tarfile.TarInfo('../../escaped.txt')
        entry.size = 6
        t.addfile(entry, io.BytesIO(b'escape'))
    run('--extract', hostile, output, success=False)
    assert not (output / 'escaped.txt').exists()
    assert not (base / 'escaped.txt').exists()
    assert not list(output.glob('.archive-job-*'))
    print('PASS: path traversal blocked and partial output cleaned')

    # Cancel a real process and ensure staged results can be cleaned without publishing.
    # Native UI owns cancellation; here test the same engine's failure cleanup after SIGTERM.
    large = base / 'large.bin'
    import os
    with large.open('wb') as f:
        block = os.urandom(4 * 1024 * 1024)
        for _ in range(32):
            f.write(block)
    proc = subprocess.Popen([str(exe), '--compress', 'tar.xz', str(output), 'cancelled', str(large)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    import time
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        children = subprocess.run(['/usr/bin/pgrep', '-P', str(proc.pid)], capture_output=True, text=True).stdout.split()
        if children:
            import os, signal
            os.kill(int(children[0]), signal.SIGTERM)
            break
        if proc.poll() is not None:
            raise AssertionError('compression ended before cancellation could be exercised')
        time.sleep(0.01)
    stdout, stderr = proc.communicate(timeout=30)
    assert proc.returncode != 0
    assert not (output / 'cancelled.tar.xz').exists()
    assert not list(output.glob('.archive-job-*'))
    print('PASS: interrupted job cleans staging and publishes no archive')
