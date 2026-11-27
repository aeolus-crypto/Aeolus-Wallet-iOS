#!/usr/bin/env python3
"""Syntax-check the JavaScript embedded in the native plugins' Swift multi-line strings.

A JS syntax error in one of these scripts fails silently on the phone (the whole script is
skipped), so the notch layout or the window.Android bridge just disappears. This runs every
\"\"\" block through `node --check`.

Usage: python3 -I tests/swift_js_check.py <dir with .swift files>
"""
import pathlib
import re
import subprocess
import sys
import tempfile

BLOCK = re.compile(r'"""\n(.*?)\n\s*"""', re.S)


def swift_to_js(body: str) -> str:
    body = re.sub(r'\\\([^)]*\)', 'x', body)  # string interpolation -> identifier
    body = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m.group(1), 16)), body)
    return (body.replace('\\\\', '\0').replace('\\"', '"').replace('\\n', '\n')
                .replace('\\t', '\t').replace('\0', '\\'))


def main(root: str) -> int:
    checked, failed = 0, 0
    for f in sorted(pathlib.Path(root).rglob('*.swift')):
        for m in BLOCK.finditer(f.read_text(encoding='utf-8')):
            js = swift_to_js(m.group(1))
            line = f.read_text(encoding='utf-8')[:m.start()].count('\n') + 1
            with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as t:
                t.write(js)
            r = subprocess.run(['node', '--check', t.name], capture_output=True, text=True)
            pathlib.Path(t.name).unlink()
            checked += 1
            if r.returncode != 0:
                failed += 1
                print(f'FAIL {f}:{line}\n{r.stderr.strip()}')
    print(f'swift_js_check: {checked} embedded scripts, {failed} failed')
    return 1 if failed or checked == 0 else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
