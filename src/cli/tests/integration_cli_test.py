#!/usr/bin/env python3
"""`telar integration`, `telar plugin trust` and `telar proxy trust status` through the executable, in private homes:
the files they write, keep and remove, and the output other telar commands parse."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CLAUDE = ('claude', '.claude', 'settings.json')
EXTENSIONS = {'pi': '.pi/agent/extensions/telar.ts', 'opencode': 'config/opencode/plugins/telar.ts'}


def environment(root):
    result = {k: v for k, v in os.environ.items()
              if not k.startswith(('TELAR_', 'XDG_')) and k not in ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PI_CODING_AGENT_DIR')}
    for key, name in (('HOME', 'home'), ('XDG_CONFIG_HOME', 'home/config'), ('XDG_DATA_HOME', 'home/data'), ('XDG_STATE_HOME', 'home/state'), ('TMPDIR', 'tmp')):
        path = root / name
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        result[key] = str(path)
    return result


class Home:
    def __init__(self, binary, root):
        self.binary = binary
        self.root = root
        self.env = environment(root)
        self.home = Path(self.env['HOME'])
        self.count = 0

    def run(self, *words, status=0, binary=None):
        """Runs telar; `status` is the exit status expected, 'failure' any but 0, None any."""
        result = subprocess.run([str(binary or self.binary), *map(str, words)], env=self.env, capture_output=True, timeout=15)
        assert status is None or (result.returncode != 0 if status == 'failure' else result.returncode == status), (words, result)
        self.count += 1
        return result


def identity(path):
    """The bytes and the inode: a rewrite with the same bytes still replaces the inode."""
    state = path.stat()
    return path.read_bytes(), state.st_ino, state.st_mtime_ns


def install_output(home):
    """`machine setup` reads "already present" in the remote install's stdout to report an
    agent as integrated before; an install that changes nothing rewrites nothing."""
    settings = home.home / '.claude/settings.json'
    first = home.run('integration', 'install', 'claude').stdout
    assert b'already present' not in first and settings.exists(), first
    before = identity(settings)
    second = home.run('integration', 'install', 'claude').stdout
    assert b'already present' in second and identity(settings) == before, second
    for provider, relative in EXTENSIONS.items():
        path = home.home / relative
        first = home.run('integration', 'install', provider).stdout
        assert b'already present' not in first and path.exists(), first
        before = identity(path)
        second = home.run('integration', 'install', provider).stdout
        assert b'already present' in second and identity(path) == before, second
        home.run('integration', 'uninstall', provider)


def unparseable_settings(home):
    """Settings telar cannot read are refused, never replaced by telar's defaults."""
    settings = home.root / 'refused/settings.json'
    settings.parent.mkdir(mode=0o700)
    for source in ('{', '[]', '"text"', '{"hooks":{"Stop":{}}}'):
        settings.write_text(source)
        home.run('integration', 'install', 'claude', '--settings', settings, status='failure')
        assert settings.read_text() == source, source
        home.run('integration', 'uninstall', 'claude', '--settings', settings, status=None)
        assert settings.read_text() == source, source


def skills(home):
    """Only telar's own skill files are replaced or removed: a skill the user wrote under the
    same name survives install and uninstall."""
    root = home.home / '.claude/skills'
    telar, coordinator = root / 'telar/SKILL.md', root / 'telar-coordinator/SKILL.md'
    telar.parent.mkdir(parents=True, exist_ok=True)
    telar.write_text('My own telar notes\n')
    home.run('integration', 'install', 'claude')
    assert telar.read_text() == 'My own telar notes\n' and coordinator.exists()
    home.run('integration', 'uninstall', 'claude')
    assert telar.read_text() == 'My own telar notes\n' and not coordinator.exists()
    telar.unlink()
    home.run('integration', 'install', 'claude')
    owned = telar.read_text()
    telar.write_text(owned.replace('Use when', 'An older copy. Use when', 1))
    home.run('integration', 'install', 'claude')
    assert telar.read_text() == owned
    # The coordinator skill shipped before the marker existed: its header alone marks it.
    marker = '<!-- telar-integration: skill telar-coordinator -->\n'
    legacy = coordinator.read_text()
    assert marker in legacy
    coordinator.write_text(legacy.replace(marker, '', 1))
    # The other skill never shipped without it: the header alone is the user's copy.
    telar.write_text(owned.replace('<!-- telar-integration: skill telar -->\n', '', 1))
    home.run('integration', 'uninstall', 'claude')
    assert not coordinator.exists() and telar.exists()
    telar.unlink()


def extensions(home):
    """The pi extension and OpenCode plugin carry the executable as a string literal, and a
    file at their path that is not telar's survives install and uninstall."""
    directory = home.root / 'bin "quoted" back\\slash'
    directory.mkdir()
    binary = directory / 'telar'
    shutil.copy2(home.binary, binary)
    for provider, relative in EXTENSIONS.items():
        path = home.home / relative
        home.run('integration', 'install', provider, binary=binary)
        assert json.dumps(str(binary), ensure_ascii=False) in path.read_text(), path.read_text()
        home.run('integration', 'uninstall', provider, binary=binary)
        assert not path.exists()
        path.write_text('// my own plugin\n')
        home.run('integration', 'install', provider, status=1)
        home.run('integration', 'uninstall', provider, status=1)
        assert path.read_text() == '// my own plugin\n'
        path.unlink()


def linked_settings(home):
    """Settings kept as a link into a dotfiles checkout stay a link, and the file it names
    gets the hooks with its own permissions; settings under missing directories get them."""
    dotfiles = home.home / 'dotfiles/settings.json'
    dotfiles.parent.mkdir()
    dotfiles.write_text('{"theme":"dark"}')
    dotfiles.chmod(0o640)
    settings = home.home / '.claude/settings.json'
    settings.parent.mkdir()
    settings.symlink_to(dotfiles)
    home.run('integration', 'install', 'claude')
    assert settings.is_symlink() and os.readlink(settings) == str(dotfiles)
    installed = json.loads(dotfiles.read_text())
    assert installed['theme'] == 'dark' and 'Stop' in installed['hooks'], installed
    assert dotfiles.stat().st_mode & 0o777 == 0o640, oct(dotfiles.stat().st_mode)
    nested = home.root / 'missing/parents/settings.json'
    home.run('integration', 'install', 'claude', '--settings', nested)
    assert 'Stop' in json.loads(nested.read_text())['hooks']


def legacy_settings(home):
    """With CLAUDE_CONFIG_DIR set, hooks left in ~/.claude are reported, and --legacy removes
    them there without touching the settings in use."""
    old = home.home / '.claude/settings.json'
    home.run('integration', 'install', 'claude')
    current = home.root / 'claude-config'
    home.env['CLAUDE_CONFIG_DIR'] = str(current)
    home.run('integration', 'install', 'claude')
    in_use = (current / 'settings.json').read_text()
    assert b'hooks remain in' in home.run('integration', 'status', 'claude').stdout
    home.run('integration', 'uninstall', 'claude', '--legacy')
    assert 'Stop' not in json.loads(old.read_text()).get('hooks', {}), old.read_text()
    assert (current / 'settings.json').read_text() == in_use
    assert b'hooks remain in' not in home.run('integration', 'status', 'claude').stdout
    # The variable naming the home's own directory leaves no other settings to clean.
    home.env['CLAUDE_CONFIG_DIR'] = str(home.home / '.claude')
    home.run('integration', 'uninstall', 'claude', '--legacy', status=1)


def trusted(home):
    store = Path(home.env['XDG_CONFIG_HOME']) / 'telar/trust.json'
    return {grant['plugin']: sorted(grant['capabilities']) for grant in json.loads(store.read_text())['grants']} if store.exists() else {}


def plugin_trust(home):
    """Trust grants what the package declares and the user named, and untrust revokes it."""
    package = home.root / 'package'
    package.mkdir(mode=0o700)
    (package / 'plugin.json').write_text(json.dumps({'api_version': 1, 'id': 'fixture', 'version': '1', 'entry': 'main.lua',
                                                     'source': {'url': 'fixture', 'revision': '1'}, 'actions': ['run'],
                                                     'capabilities': ['notifications', 'proxy.tap']}))
    (package / 'main.lua').write_text('return {actions={run=function() end}}\n')
    assert b'CapabilityNotDeclared' in home.run('plugin', 'trust', package, '--capability', 'process.spawn', status=1).stderr
    assert trusted(home) == {}
    home.run('plugin', 'trust', package, '--capability', 'notifications')
    assert trusted(home) == {'fixture': ['notifications']}
    home.run('plugin', 'trust', package)
    assert trusted(home) == {'fixture': ['notifications', 'proxy.tap']}
    home.run('plugin', 'untrust', 'fixture')
    assert trusted(home) == {}


def proxy_trust_status(home):
    """`proxy trust status` reports an unreadable trust record as a failure, never as a
    store without telar's CA (an install would then add a second one). Status only: an
    install would change the system trust store."""
    authority = home.root / 'ca'
    home.run('proxy', 'trust', 'status', '--ca-dir', authority)
    authority.mkdir(mode=0o700)
    record = authority / 'trust-install.json'
    record.write_text('{broken')
    record.chmod(0o600)
    home.run('proxy', 'trust', 'status', '--ca-dir', authority, status=1)
    home.run('proxy', 'trust', 'status', '--ca-dir', 'relative/ca', status=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    parser.add_argument('--scratch', type=Path)
    args = parser.parse_args()
    count = 0
    for check in (install_output, unparseable_settings, skills, extensions, plugin_trust, linked_settings, legacy_settings, proxy_trust_status):
        with tempfile.TemporaryDirectory(prefix='integration-', dir=args.scratch) as directory:
            home = Home(args.telar.resolve(), Path(directory).resolve())
            check(home)
            count += home.count
    print(f'{count} integration and plugin trust CLI cases passed')


if __name__ == '__main__':
    main()
