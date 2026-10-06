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
            '"value": os.getenv("VALUE"), "proxy": os.getenv("http_proxy")}))\n',
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


if __name__ == '__main__':
    unittest.main()
