"""Review tripwire for shipped browser sources, not a semantic JS sandbox."""
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import sys

SCRIPTS = {'glue.js', 'node-host.js', 'control.js', 'pod.js', 'page.js'}
FILES = SCRIPTS | {'model.ml', 'dune', 'index.html'}
FORBIDDEN = {'Worker', 'navigator', 'indexedDB', 'postMessage', 'eval', 'Function'}
IDENTIFIER = re.compile(r'[A-Za-z_$][A-Za-z0-9_$]*')
ESCAPE = re.compile(r'\\(?:u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})|x([0-9a-fA-F]{2})|([\s\S]))')


def decoded(text):
    def replace(match):
        digits = next((group for group in match.groups()[:3] if group), None)
        if digits:
            point = int(digits, 16)
            return chr(point) if point <= 0x10ffff else 'invalid_escape'
        return '' if match[4] in '\r\n' else match[4]
    return ESCAPE.sub(replace, text)


def code_tokens(source, ocaml=False):
    """Keep literal property names and template expressions; omit comments."""
    tokens = set()
    cursor = 0

    def words(text):
        tokens.update(IDENTIFIER.findall(decoded(text)))

    def quoted(delimiter):
        nonlocal cursor
        cursor += 1
        start = cursor
        while cursor < len(source):
            char = source[cursor]
            if char == '\\':
                cursor += 2
            elif char == delimiter:
                words(source[start:cursor])
                cursor += 1
                return
            elif delimiter == '`' and source.startswith('${', cursor):
                words(source[start:cursor])
                cursor += 2
                scan('}')
                start = cursor
            else:
                cursor += 1
        words(source[start:cursor])

    def scan(until=None):
        nonlocal cursor
        while cursor < len(source):
            char = source[cursor]
            if until and char == until:
                cursor += 1
                return
            if not ocaml and source.startswith('//', cursor):
                end = source.find('\n', cursor + 2)
                cursor = len(source) if end < 0 else end + 1
            elif not ocaml and source.startswith('/*', cursor):
                end = source.find('*/', cursor + 2)
                cursor = len(source) if end < 0 else end + 2
            elif ocaml and source.startswith('(*', cursor):
                depth = 1
                cursor += 2
                while cursor < len(source) and depth:
                    if source.startswith('(*', cursor):
                        depth += 1
                        cursor += 2
                    elif source.startswith('*)', cursor):
                        depth -= 1
                        cursor += 2
                    else:
                        cursor += 1
            elif char in ('"', "'", '`'):
                quoted(char)
            elif char == '{':
                cursor += 1
                scan('}')
            else:
                match = IDENTIFIER.match(source, cursor)
                if match:
                    tokens.add(match[0])
                    cursor = match.end()
                elif char == '\\':
                    match = re.match(r'(?:[A-Za-z0-9_$]|\\u(?:[0-9a-fA-F]{4}|\{[0-9a-fA-F]+\}))+', source[cursor:])
                    if match:
                        words(match[0])
                        cursor += len(match[0])
                    else:
                        cursor += 1
                else:
                    cursor += 1
    scan()
    return tokens


class PageScripts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scripts = []
        self.errors = []
        self.in_script = False

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name.startswith('on') or (value or '').lstrip().lower().startswith('javascript:'):
                self.errors.append('inline executable HTML attribute')
        if tag == 'script':
            self.in_script = True
            sources = [value for name, value in attrs if name == 'src']
            if len(sources) != 1 or sources[0] not in SCRIPTS:
                self.errors.append('script requires one known local src')
            self.scripts.extend(sources)

    def handle_endtag(self, tag):
        if tag == 'script':
            self.in_script = False

    def handle_data(self, data):
        if self.in_script and data.strip():
            self.errors.append('inline script content')

    def validate(self, source):
        self.feed(source)
        self.close()
        if self.scripts != ['glue.js', 'page.js']:
            self.errors.append('page scripts must be glue.js then page.js')
        return self.errors


def tree_errors(browser):
    paths = set()
    errors = []
    for path in browser.rglob('*'):
        relative = path.relative_to(browser).as_posix()
        paths.add(relative)
        if path.is_symlink() or not path.is_file():
            errors.append(f'unsupported browser path: {relative}')
    if paths != FILES:
        errors.append(f'browser tree differs: missing={sorted(FILES - paths)} extra={sorted(paths - FILES)}')
    return errors


def audit(root):
    browser = root / 'browser'
    errors = tree_errors(browser)
    if errors:
        return errors, 0
    lines = len((browser / 'glue.js').read_text().splitlines())
    if not 1 <= lines <= 300:
        errors.append(f'GLUE lines={lines}, limit=300')
    errors.extend(PageScripts().validate((browser / 'index.html').read_text()))
    for name in sorted(SCRIPTS | {'model.ml'}):
        file = browser / name
        if name != 'glue.js':
            forbidden = code_tokens(file.read_text(), ocaml=name.endswith('.ml')) & FORBIDDEN
            if forbidden:
                errors.append(f'raw browser capability outside GLUE: {name}: {sorted(forbidden)}')
        if name.endswith('.js'):
            check = subprocess.run(['node', '--check', str(file)], capture_output=True, text=True)
            if check.returncode:
                errors.append(check.stderr)
    return errors, lines


if __name__ == '__main__':
    errors, lines = audit(Path(__file__).resolve().parent.parent)
    for error in errors:
        print('BROWSER-AUDIT FAIL', error)
    if errors:
        sys.exit(1)
    print(f'BROWSER-AUDIT OK glue_lines={lines}/300 scripts={len(SCRIPTS)}')
