#!/usr/bin/env python3
"""CLI regression tests: python scripts/test_alias.py [path/to/proxy].

Uses an isolated PROXY_HOME and local child processes; no network or real Codex run.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BINARY = Path(sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith('-')
              else 'zig-out/bin/proxy' + ('.exe' if os.name == 'nt' else '')).resolve()
PROXY_ENV = ('http_proxy', 'https_proxy', 'all_proxy', 'ftp_proxy',
             'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'FTP_PROXY')


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


class AliasTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='proxy-alias-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.env = {**os.environ, 'PROXY_HOME': str(self.root / 'config'),
                    'CODEX_CA_CERTIFICATE': 'parent-value'}
        self.capture = self.root / 'capture args.py'
        self.capture.write_text(
            'import json, os, sys\n'
            'print(json.dumps({"args": sys.argv[1:], "cert": os.getenv("CODEX_CA_CERTIFICATE"), '
            '"node_cert": os.getenv("NODE_EXTRA_CA_CERTS"), "empty": os.getenv("EMPTY"), '
            '"value": os.getenv("VALUE"), "proxy": os.getenv("http_proxy"), '
            f'"proxy_env": {{name: os.getenv(name) for name in {PROXY_ENV!r}}}}}))\n',
            encoding='utf-8')
        self.command = f'{quote(sys.executable)} {quote(self.capture)}'

    def cli(self, *args, code=0):
        result = subprocess.run([str(BINARY), *args], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout

    def alias(self, command):
        self.cli('alias', 'add', 'all', 'test-alias', command)

    def test_certificate_export_and_unchanged_parent_environment(self):
        self.alias("export CODEX_CA_CERTIFICATE='D:\\reqable-ca.pem'\r\n" + self.command)
        output = json.loads(self.cli('test-alias', '--dangerously-bypass-approvals-and-sandbox', 'two words'))
        self.assertEqual(output['cert'], r'D:\reqable-ca.pem')
        self.assertEqual(output['args'], ['--dangerously-bypass-approvals-and-sandbox', 'two words'])
        self.assertEqual(output['proxy'], 'http://127.0.0.1:7890')
        fresh = json.loads(self.cli(sys.executable, str(self.capture)))
        self.assertEqual(fresh['cert'], 'parent-value')

    def test_exports_persist_between_commands_and_accept_empty_values(self):
        self.alias('export NODE_EXTRA_CA_CERTS="D:\\\\cert files\\\\reqable-ca.pem" EMPTY="" VALUE="a=b"\n'
                   + self.command + '\nexport VALUE=changed\n' + self.command)
        first, last = map(json.loads, self.cli('test-alias', 'last only').splitlines())
        for output in (first, last):
            self.assertEqual(output['node_cert'], r'D:\cert files\reqable-ca.pem')
            self.assertEqual(output['empty'], '')
        self.assertEqual(first['value'], 'a=b')
        self.assertEqual(first['args'], [])
        self.assertEqual(last['value'], 'changed')
        self.assertEqual(last['args'], ['last only'])

    def test_quoted_arguments_and_literal_extra_arguments(self):
        args = ['', 'two words', r'D:\cert files\ca.pem', 'say "hello"', "it's literal"]
        extra = ['a & b', '$(echo unexpected)', '"quoted"']
        self.alias(self.command + ' ' + ' '.join(map(quote, args)))
        self.assertEqual(json.loads(self.cli('test-alias', *extra))['args'], args + extra)

    def test_nonzero_exit_stops_remaining_commands(self):
        self.alias('export VALUE=ready\n' + quote(sys.executable)
                   + ' -c "raise SystemExit(17)"\n' + self.command)
        self.assertEqual(self.cli('test-alias', code=17), '')

    def test_invalid_export_and_quotes_stop_execution(self):
        for line, error in [('export', 'InvalidExport'), ('export BAD-NAME=value', 'InvalidExport'),
                            ('export MISSING', 'InvalidExport'),
                            ('export CERT="unfinished', 'InvalidAliasQuotes')]:
            with self.subTest(line=line):
                self.alias(line + '\n' + self.command)
                result = subprocess.run([str(BINARY), 'test-alias'], env=self.env,
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stdout + result.stderr)
                self.assertNotIn('"args":', result.stdout)

    def test_export_only_alias(self):
        self.alias('export VALUE=local')
        self.assertEqual(self.cli('test-alias'), '')

    def test_direct_flags_clear_inherited_proxy_environment(self):
        self.env.update({name: 'http://inherited.invalid:9999' for name in PROXY_ENV})
        self.alias(self.command)
        for option in ('-n', '--no-proxy'):
            with self.subTest(option=option):
                output = json.loads(self.cli(option, 'test-alias', 'two words'))
                self.assertTrue(all(value is None for value in output['proxy_env'].values()))
                self.assertEqual(output['cert'], 'parent-value')
                self.assertEqual(output['args'], ['two words'])
                self.assertIsNone(json.loads(self.cli(option, sys.executable, str(self.capture)))['proxy'])
        self.assertEqual(self.env['http_proxy'], 'http://inherited.invalid:9999')
        self.assertEqual(json.loads(self.cli('test-alias'))['proxy'], 'http://127.0.0.1:7890')

    def test_saved_mode_and_temporary_overrides(self):
        self.alias(self.command)
        alias_path = self.root / 'config' / 'aliases.json'
        self.assertIsInstance(json.loads(alias_path.read_text())['all']['test-alias'], str)
        self.cli('alias', 'mode', 'all', 'test-alias', 'direct')
        stored = alias_path.read_bytes()
        self.assertIn('test-alias [direct] ->', self.cli('alias', 'list'))
        self.assertIsNone(json.loads(self.cli('test-alias'))['proxy'])
        for option in ('-p', '--proxy'):
            self.assertEqual(json.loads(self.cli(option, 'test-alias'))['proxy'], 'http://127.0.0.1:7890')
        self.assertEqual(alias_path.read_bytes(), stored)
        # Replacing a command must preserve its saved mode.
        self.alias(self.command + ' changed')
        self.assertIsNone(json.loads(self.cli('test-alias'))['proxy'])
        self.cli('alias', 'mode', 'all', 'test-alias', 'proxy')
        self.assertIn('test-alias [proxy] ->', self.cli('alias', 'list'))
        self.assertEqual(json.loads(self.cli('test-alias'))['proxy'], 'http://127.0.0.1:7890')
        self.assertIsInstance(json.loads(alias_path.read_text())['all']['test-alias'], str)

    def test_direct_mode_clears_exports_before_every_child(self):
        self.alias("export CODEX_CA_CERTIFICATE='D:\\cert files\\ca.pem'\n"
                   'export http_proxy=http://alias.invalid:1234 HTTPS_PROXY=http://alias.invalid:1234\n'
                   + self.command + '\nexport ALL_PROXY=socks5://alias.invalid:1234\n' + self.command)
        self.cli('alias', 'mode', 'all', 'test-alias', 'direct')
        for output in map(json.loads, self.cli('test-alias', 'last').splitlines()):
            self.assertTrue(all(value is None for value in output['proxy_env'].values()))
            self.assertEqual(output['cert'], r'D:\cert files\ca.pem')
        for output in map(json.loads, self.cli('-p', 'test-alias').splitlines()):
            self.assertEqual(output['proxy'], 'http://127.0.0.1:7890')

    def test_direct_mode_does_not_load_proxy_config(self):
        self.alias(self.command)
        self.cli('alias', 'mode', 'all', 'test-alias', 'direct')
        config = self.root / 'config' / 'config.json'
        config.write_text('{invalid json', encoding='utf-8')
        self.assertIsNone(json.loads(self.cli('test-alias'))['proxy'])
        self.assertIsNone(json.loads(self.cli('-n', sys.executable, str(self.capture)))['proxy'])
        self.assertEqual(config.read_text(), '{invalid json')

    def test_platform_alias_mode_and_node_override(self):
        self.alias(self.command)
        self.cli('alias', 'mode', 'all', 'test-alias', 'direct')
        platform = 'windows' if os.name == 'nt' else ('macos' if sys.platform == 'darwin' else 'linux')
        self.cli('alias', 'add', platform, 'test-alias', self.command + ' platform')
        output = json.loads(self.cli('test-alias'))
        self.assertEqual(output['proxy'], 'http://127.0.0.1:7890')
        self.assertEqual(output['args'], ['platform'])
        self.cli('alias', 'mode', platform, 'test-alias', 'direct')
        self.assertIsNone(json.loads(self.cli('test-alias'))['proxy'])
        self.cli('config', 'set', 'port', '8123')
        self.cli('node', 'save', 'selected')
        self.cli('node', 'unlink')
        self.cli('config', 'set', 'port', '7890')
        before = {path.name: path.read_bytes() for path in (self.root / 'config').glob('*.json')}
        self.assertEqual(json.loads(self.cli('1', 'test-alias'))['proxy'], 'http://127.0.0.1:8123')
        self.assertEqual({path.name: path.read_bytes() for path in (self.root / 'config').glob('*.json')}, before)

    def test_execution_options_stop_at_command_and_support_separator(self):
        self.alias(self.command)
        output = json.loads(self.cli('-n', 'test-alias', '-p', '--no-proxy', '--'))
        self.assertEqual(output['args'], ['-p', '--no-proxy', '--'])
        self.assertIsNone(output['proxy'])
        self.cli('alias', 'add', 'all', '-n', self.command)
        self.assertIsNone(json.loads(self.cli('-n', '--', '-n'))['proxy'])

    def test_invalid_modes_and_conflicting_options_do_not_write_config(self):
        self.alias(self.command)
        before = {path.name: path.read_bytes() for path in (self.root / 'config').glob('*.json')}
        for args in [('-n',), ('-p',), ('-n', '-p', 'test-alias'), ('-n', '1', 'test-alias'),
                     ('-n', 'config', 'set', 'port', '1234'), ('-p', 'on'),
                     ('alias', 'mode', 'all', 'test-alias', 'invalid'),
                     ('alias', 'mode', 'all', 'missing', 'direct'),
                     ('alias', 'mode', 'unknown', 'test-alias', 'direct')]:
            with self.subTest(args=args):
                result = subprocess.run([str(BINARY), *args], env=self.env,
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({path.name: path.read_bytes() for path in (self.root / 'config').glob('*.json')}, before)

    @unittest.skipUnless(os.name == 'nt', 'Windows command shim')
    def test_windows_cmd_shim_receives_export_and_arguments(self):
        shim = self.root / 'proxy-test-codex.cmd'
        shim.write_text(f'@"{sys.executable}" "{self.capture}" %*\n', encoding='utf-8')
        self.env['PATH'] = str(self.root) + os.pathsep + os.environ.get('PATH', '')
        self.alias("export CODEX_CA_CERTIFICATE='D:\\reqable-ca.pem'\n"
                   'proxy-test-codex --dangerously-bypass-approvals-and-sandbox')
        output = json.loads(self.cli('test-alias', '--version', 'two words'))
        self.assertEqual(output['cert'], r'D:\reqable-ca.pem')
        self.assertEqual(output['args'], ['--dangerously-bypass-approvals-and-sandbox', '--version', 'two words'])
        direct = json.loads(self.cli('-n', 'test-alias', '--version'))
        self.assertIsNone(direct['proxy'])
        self.assertEqual(direct['cert'], r'D:\reqable-ca.pem')


if __name__ == '__main__':
    unittest.main()
