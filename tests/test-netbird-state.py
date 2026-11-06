#!/usr/bin/env python3
# All state and service stubs run in temporary directories; real system state paths are never accessed.
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / 'qpkg/shared/netbird-state.sh'
SERVICE = ROOT / 'qpkg/shared/netbird.sh'


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='netbird state ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.install = self.base / 'install path'
        self.install.mkdir()
        self.state = self.base / 'ram/var/lib/netbird'
        self.config = self.base / 'ram/etc/netbird'
        self.target = self.install / 'var/lib/netbird'
        self.ctarget = self.install / 'var/etc/netbird'
        self.env = dict(os.environ, QPKG_ROOT=str(self.install),
                        STATE=str(self.state), CONFIG=str(self.config))

    def run_shell(self, script='', success=True):
        result = subprocess.run(['sh', '-c', '. ' + shlex.quote(str(HELPER)) + '\n' +
                                 script + '\nnb_prepare_state "$STATE" "$CONFIG"'],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)

    def seed(self):
        self.state.mkdir(parents=True)
        self.config.mkdir(parents=True)
        (self.state / '.identity').write_text('synthetic-test-identity')
        (self.state / 'nested').mkdir()
        (self.state / 'nested/data').write_bytes(b'\x00test\xff')
        (self.config / 'default.json').write_text('{"test": true}')

    def test_fresh_permissions_and_spaces(self):
        self.run_shell()
        for source, target in [(self.state, self.target), (self.config, self.ctarget)]:
            self.assertEqual(source.resolve(), target.resolve())
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)

    def test_identity_repeat_and_reboot(self):
        self.seed()
        (self.state / 'active_profile.json').write_text('{"name": "default"}')
        (self.state / 'default.json').write_text(
            '{"peer": "nas-test.netbird.cloud", "ip": "100.91.46.214/16"}')
        (self.state / 'state.json').write_text('{"registered": true}')
        self.run_shell()
        expected = {name: (self.target / name).read_bytes() for name in
                    ['.identity', 'active_profile.json', 'default.json', 'state.json']}
        self.assertEqual((self.target / 'nested/data').read_bytes(), b'\x00test\xff')
        self.assertTrue(list(self.state.parent.glob('netbird.backup.*/original/.identity')))
        self.assertEqual((self.ctarget / 'default.json').read_text(), '{"test": true}')

        # A service restart must not overwrite the migrated identity.
        self.run_shell()
        self.assertEqual({name: (self.state / name).read_bytes() for name in expected}, expected)

        # A full reboot removes runtime directories but preserves state on the install volume.
        shutil.rmtree(self.base / 'ram')
        self.run_shell()
        self.assertEqual(self.state.resolve(), self.target.resolve())
        self.assertEqual(self.config.resolve(), self.ctarget.resolve())
        self.assertEqual({name: (self.state / name).read_bytes() for name in expected}, expected)
        self.assertEqual((self.config / 'default.json').read_text(), '{"test": true}')
        self.assertEqual((self.target / 'nested/data').read_bytes(), b'\x00test\xff')

    def test_conflict(self):
        self.seed()
        self.target.mkdir(parents=True)
        (self.target / 'other').write_text('existing')
        self.run_shell(success=False)
        self.assertFalse(self.state.is_symlink())
        self.assertEqual((self.target / 'other').read_text(), 'existing')

    def test_copy_failure_and_silent_truncation(self):
        self.seed()
        for stub in ['cp() { return 1; }', 'cp() { return 0; }']:
            self.run_shell(stub, success=False)
            self.assertFalse(self.target.exists())
            self.assertTrue((self.state / '.identity').exists())
            self.assertEqual(list(self.target.parent.glob('*.staging.*')), [])

    def test_link_failure_restores_source_and_allows_retry(self):
        self.seed()
        self.run_shell('ln() { return 1; }', success=False)
        self.assertFalse(self.state.is_symlink())
        self.assertEqual((self.state / '.identity').read_text(),
                         'synthetic-test-identity')
        self.assertFalse(self.target.exists())
        self.run_shell()
        self.assertEqual((self.state / '.identity').read_text(),
                         'synthetic-test-identity')

    def test_link_failure_preserves_existing_target(self):
        self.seed()
        self.target.mkdir(parents=True)
        self.run_shell('ln() { return 1; }', success=False)
        self.assertFalse(self.state.is_symlink())
        self.assertTrue(self.target.is_dir())
        self.assertEqual((self.state / '.identity').read_text(),
                         'synthetic-test-identity')
        self.run_shell(success=False)
        self.assertEqual((self.state / '.identity').read_text(),
                         'synthetic-test-identity')

    def test_unsafe_links(self):
        self.state.parent.mkdir(parents=True)
        for dest in [self.base / 'missing', self.base / 'unknown']:
            if dest.name == 'unknown':
                dest.mkdir()
            self.state.symlink_to(dest)
            self.run_shell(success=False)
            self.state.unlink()
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(self.base)
        self.run_shell(success=False)

    def test_stale_volume_link_with_existing_target(self):
        self.run_shell()
        self.state.unlink()
        self.state.symlink_to(self.base / 'old install/var/lib/netbird')
        self.run_shell(success=False)
        self.assertTrue(self.state.is_symlink())
        self.assertTrue(self.target.is_dir())

    def test_reboot_missing_directories(self):
        self.seed()
        self.run_shell()
        self.state.unlink()
        self.config.unlink()
        self.run_shell()
        self.assertEqual((self.state / '.identity').read_text(), 'synthetic-test-identity')

    def test_same_directory_volume_alias(self):
        self.run_shell()
        alias = self.base / 'old install'
        alias.symlink_to(self.install)
        self.state.unlink()
        self.state.symlink_to(alias / 'var/lib/netbird')
        self.run_shell()
        self.assertEqual(os.readlink(self.state), str(self.target))

    def test_webui_link_recreated_after_reboot(self):
        web = self.install / 'web'
        web.mkdir()
        link = self.base / 'qts-web/netbird'
        link.parent.mkdir()
        setup = SERVICE.read_text().split('setup_webui() {\n', 1)[1].split('    # Drop-in proxy config', 1)[0]
        setup = setup.replace('_web_link=/home/Qhttpd/Web/netbird',
                              '_web_link=' + shlex.quote(str(link)))
        script = 'log() { :; }\nsetup_webui() {\n' + setup + '}\nsetup_webui\n'

        for _ in range(2):
            result = subprocess.run(['sh', '-c', script], env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(link.resolve(), web.resolve(), (result.stdout, result.stderr))
            self.assertEqual(os.readlink(link), str(web))
            link.unlink()  # QTS web root may lose package links during reboot.

        result = subprocess.run(['sh', '-c', script], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(link), str(web))
        result = subprocess.run(['sh', '-c', script], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(link), str(web))

        link.unlink()
        link.symlink_to(self.base / 'old install/web')
        result = subprocess.run(['sh', '-c', script], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(link), str(web))
        link.unlink()

        link.mkdir()
        result = subprocess.run(['sh', '-c', script], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.is_dir())
        self.assertFalse(link.is_symlink())

    def test_service_guards(self):
        # Use the real startup function, replacing only the platform config command; failures must return before service side effects.
        text = SERVICE.read_text()
        start = text[text.index('start_service() {'):text.index('\nstop_service() {')]
        start = start.replace('/sbin/getcfg', 'getcfg')
        prefix = '''
log() { :; }
record_error() { printf '%s' "$1" > "$QPKG_ROOT/error"; }
getcfg() { printf TRUE; }
nb_load_config() { :; }
setup_webui() { touch "$QPKG_ROOT/UNSAFE"; }
QPKG_NAME=netbird
PIDF="$QPKG_ROOT/pid"
NETBIRD_BIN=/usr/bin/true
SVCLOG="$QPKG_ROOT/log"
NETBIRD_CONF="$QPKG_ROOT/config"
'''
        for mode in ['copy_failure', 'missing_pid', 'running']:
            with self.subTest(mode=mode):
                error = self.install / 'error'
                if error.exists():
                    error.unlink()
                guard = self.install / 'guard.sh'
                guard.write_text('. ' + shlex.quote(str(HELPER)) + '''
nb_prepare_state() { nb_state_prepare_dir "$STATE" "$QPKG_ROOT/var/lib/netbird"; }
cp() { return 1; }
''')
                self.state.mkdir(parents=True, exist_ok=True)
                (self.state / 'identity').write_text('synthetic')
                script = prefix + '\nNETBIRD_STATE=' + shlex.quote(str(guard)) + '\n'
                script += 'pidof() { return ' + ('0' if mode == 'missing_pid' else '1') + '; }\n'
                if mode == 'running':
                    script += 'printf "%s" "$$" > "$PIDF"\n'
                script += start + '\nstart_service\n'
                result = subprocess.run(['sh', '-c', script], env=self.env, capture_output=True)
                self.assertEqual(result.returncode, 0 if mode == 'running' else 1, result.stderr)
                self.assertEqual(error.exists(), mode != 'running')
                self.assertFalse((self.install / 'UNSAFE').exists())
                self.assertFalse(self.target.exists())
                self.assertFalse(self.state.is_symlink())


if __name__ == '__main__':
    unittest.main(verbosity=2)
