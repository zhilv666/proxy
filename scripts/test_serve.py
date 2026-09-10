#!/usr/bin/env python3
"""Black-box tests for the compiled web manager; uses only the Python stdlib.

Run after zig build: python scripts/test_serve.py [path/to/proxy]
Every test uses its own PROXY_HOME and an ephemeral loopback port.
"""

import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = Path(sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith('-')
              else 'zig-out/bin/proxy' + ('.exe' if os.name == 'nt' else '')).resolve()


class ServeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='proxy-serve-')
        self.root = Path(self.temp.name)
        self.home = self.root / 'nested' / 'config'
        self.env = {**os.environ, 'PROXY_HOME': str(self.home)}
        self.process = None
        self.log = None
        self.addCleanup(self.cleanup)
        self.start_server()

    def start_server(self):
        self.log = (self.root / 'server.log').open('wb')
        self.process = subprocess.Popen([str(BINARY), 'serve', '--port', '0'],
                                        env=self.env, stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            output = (self.root / 'server.log').read_text(encoding='utf-8', errors='replace')
            match = re.search(r'http://127\.0\.0\.1:(\d+)/', output)
            if match:
                self.port = int(match.group(1))
                return
            if self.process.poll() is not None:
                self.fail(f'serve exited early: {output}')
            time.sleep(0.02)
        self.fail('serve did not announce its port')

    def stop_server(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log:
            self.log.close()
            self.log = None

    def cleanup(self):
        self.stop_server()
        self.temp.cleanup()

    def request(self, method, path, value=None, *, headers=None, raw=None):
        request_headers = {}
        body = raw
        if method in ('POST', 'PUT', 'DELETE'):
            request_headers = {'Content-Type': 'application/json', 'X-Proxy-Request': '1'}
            if raw is None:
                body = json.dumps(value if value is not None else {}, ensure_ascii=False).encode()
        if headers:
            for key, val in headers.items():
                if val is None:
                    request_headers.pop(key, None)
                else:
                    request_headers[key] = val
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=8)
        try:
            connection.request(method, path, body=body, headers=request_headers)
            response = connection.getresponse()
            content = response.read()
            result = (json.loads(content) if content and 'application/json' in
                      response.getheader('Content-Type', '') else content)
            return response.status, result, dict(response.getheaders())
        finally:
            connection.close()

    def api(self, method, path, value=None, expected=200, **kwargs):
        status, result, _ = self.request(method, path, value, **kwargs)
        self.assertEqual(status, expected, result)
        return result

    def cli(self, *args, expected=0):
        result = subprocess.run([str(BINARY), *args], env=self.env, capture_output=True,
                                text=True, encoding='utf-8', timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn('error(gpa)', result.stderr)
        return result.stdout + result.stderr

    def config(self, **overrides):
        return {'host': '127.0.0.1', 'port': '7890', 'protocol': 'http',
                'username': '', 'password': '', **overrides}

    def files(self):
        return {p.name: p.read_bytes() for p in self.home.glob('*.json')}

    def test_help_and_invalid_options(self):
        self.assertIn('serve', self.cli('--help'))
        self.assertIn('127.0.0.1', self.cli('serve', '--help'))
        for args in (('--port', '-1'), ('--port', '65536'), ('--port',), ('--unknown',)):
            with self.subTest(args=args):
                self.cli('serve', *args, expected=1)

    def test_embedded_assets_and_empty_state(self):
        for path, content_type in (('/', 'text/html'), ('/app.js', 'text/javascript'),
                                   ('/app.css', 'text/css')):
            status, content, headers = self.request('GET', path)
            self.assertEqual(status, 200)
            self.assertIn(content_type, headers['Content-Type'])
            self.assertGreater(len(content), 100)
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
        status, content, headers = self.request('HEAD', '/')
        self.assertEqual(status, 200)
        self.assertEqual(content, b'')
        self.assertGreater(int(headers['Content-Length']), 100)
        state = self.api('GET', '/api/state')
        self.assertEqual(state['nodes'], [])
        self.assertEqual(state['aliases'], [])
        self.assertEqual(state['config']['node'], '')
        self.assertEqual(self.files(), {})
        self.api('GET', '/../../config.json', expected=404)
        self.api('GET', '/api/missing', expected=404)
        self.api('POST', '/api/state', expected=405)

    def test_current_config_round_trip_and_reset(self):
        config = self.config(host='proxy.example.com', port='1080', protocol='socks5',
                             username='用户"\\name', password='p@ss"\\word\n\t中')
        self.api('PUT', '/api/config', config)
        self.assertEqual(self.api('GET', '/api/config'), {**config, 'node': ''})
        self.assertEqual(json.loads((self.home / 'config.json').read_text(encoding='utf-8')),
                         {**config, 'node': ''})
        self.assertIn('proxy.example.com', self.cli('config', 'get', 'host'))
        self.cli('config', 'set', 'port', '8888')
        self.assertEqual(self.api('GET', '/api/config')['port'], '8888')
        self.api('POST', '/api/aliases', {'platform': 'all', 'name': 'gs', 'command': 'git status'}, 201)
        self.api('DELETE', '/api/config')
        self.assertTrue(all(value == '' for value in self.api('GET', '/api/config').values()))
        self.assertEqual(len(self.api('GET', '/api/aliases')), 1)
        result = self.cli(sys.executable, '-c', "import os; print(os.environ.get('http_proxy'))")
        self.assertIn('http://127.0.0.1:7890', result)

    def test_node_lifecycle_and_active_synchronization(self):
        dev = self.config(name='dev')
        office = self.config(name='office', host='10.0.0.2', port='8080')
        self.api('POST', '/api/nodes', dev, 201)
        self.api('POST', '/api/nodes', office, 201)
        self.assertEqual(self.api('GET', '/api/config')['node'], '')
        before = self.files()
        self.api('POST', '/api/nodes', dev, 409)
        self.assertEqual(self.files(), before)
        self.api('POST', '/api/nodes/activate', {'name': 'dev'})
        self.assertEqual(self.api('GET', '/api/config')['node'], 'dev')
        changed = self.config(port='9000', password='quote"\\secret')
        self.api('PUT', '/api/config', changed)
        nodes = self.api('GET', '/api/nodes')
        self.assertEqual(next(n for n in nodes if n['name'] == 'dev'), {**changed, 'name': 'dev'})
        self.cli('config', 'set', 'host', 'localhost')
        self.assertEqual(self.api('GET', '/api/nodes')[0]['host'], 'localhost')
        edited = self.config(name='开发 / "主机"', host='192.0.2.10', original_name='dev')
        self.api('PUT', '/api/nodes', edited)
        active = self.api('GET', '/api/config')
        self.assertEqual(active['node'], edited['name'])
        self.assertEqual(active['host'], edited['host'])
        before = self.files()
        self.api('PUT', '/api/nodes', {**edited, 'original_name': edited['name'], 'name': 'office'}, 409)
        self.assertEqual(self.files(), before)
        self.api('DELETE', '/api/nodes', {'name': edited['name']})
        self.assertEqual(self.api('GET', '/api/config'), {**active, 'node': ''})
        self.api('POST', '/api/nodes/activate', {'name': 'office'})
        self.api('POST', '/api/nodes/unlink')
        self.assertEqual(self.api('GET', '/api/config')['node'], '')
        self.api('DELETE', '/api/nodes', {'name': 'office'})
        self.assertEqual(self.api('GET', '/api/nodes'), [])
        self.api('DELETE', '/api/nodes', {'name': 'missing'}, 404)

    def test_alias_edit_platform_move_and_escaping(self):
        command = 'tool --path "C:\\Program Files\\示例"\n--value="quoted"'
        alias = {'platform': 'all', 'name': 'demo', 'command': command}
        self.api('POST', '/api/aliases', alias, 201)
        self.api('POST', '/api/aliases', {**alias, 'platform': 'windows', 'command': 'cmd /c dir'}, 201)
        before = self.files()
        self.api('POST', '/api/aliases', alias, 409)
        self.assertEqual(self.files(), before)
        changed = {**alias, 'platform': 'linux', 'name': 'new-name',
                   'original_platform': 'all', 'original_name': 'demo'}
        self.api('PUT', '/api/aliases', changed)
        stored = json.loads((self.home / 'aliases.json').read_text(encoding='utf-8'))
        self.assertEqual(stored['linux']['new-name'], command)
        self.assertNotIn('demo', stored['all'])
        self.assertIn('new-name', self.cli('alias', 'list'))
        self.cli('alias', 'add', 'macos', 'quoted', command)
        aliases = self.api('GET', '/api/aliases')
        self.assertEqual(next(a['command'] for a in aliases if a['name'] == 'quoted'), command)
        self.api('DELETE', '/api/aliases', {'platform': 'linux', 'name': 'new-name'})
        self.api('DELETE', '/api/aliases', {'platform': 'linux', 'name': 'new-name'}, 404)
        self.assertEqual(len(self.api('GET', '/api/aliases')), 2)
        # Multi-line commands round-trip; browser CRLF is normalised to LF.
        self.api('POST', '/api/aliases', {'platform': 'all', 'name': 'multi', 'command': 'echo one\r\necho two\r\n'}, 201)
        self.assertEqual(next(a['command'] for a in self.api('GET', '/api/aliases') if a['name'] == 'multi'), 'echo one\necho two\n')
        self.assertIn('multi -> echo one', self.cli('alias', 'list'))

    def test_persistence_after_restart_and_cli_updates(self):
        self.cli('config', 'set', 'host', '192.0.2.5')
        self.cli('node', 'save', 'from-cli')
        self.cli('alias', 'add', 'all', 'gs', 'git status')
        state = self.api('GET', '/api/state')
        self.stop_server()
        self.start_server()
        self.assertEqual(self.api('GET', '/api/state'), state)
        self.assertIn('unsupported here: serve', self.cli('1', 'serve'))

    def test_invalid_payloads_preserve_existing_files(self):
        self.api('PUT', '/api/config', self.config())
        before = self.files()
        for changes in ({'port': '0'}, {'port': '65536'}, {'port': 80}, {'port': 'x'},
                        {'protocol': 'ftp'}, {'host': ''}, {'host': 'http://example.com'},
                        {'host': 'bad\x00host'}, {'username': []}):
            with self.subTest(changes=changes):
                self.api('PUT', '/api/config', self.config(**changes), 400)
                self.assertEqual(self.files(), before)
        for raw in (b'{', b'[]', b'null', b'{"port":"80"}'):
            self.api('PUT', '/api/config', expected=400, raw=raw)
            self.assertEqual(self.files(), before)
        for alias in ({'platform': 'unknown', 'name': 'gs', 'command': 'git status'},
                      {'platform': 'all', 'name': 'two words', 'command': 'git status'},
                      {'platform': 'all', 'name': 'gs', 'command': ' \t'}):
            self.api('POST', '/api/aliases', alias, 400)
        self.api('PUT', '/api/nodes', self.config(name='new', original_name='missing'), 404)
        self.assertEqual(self.files(), before)

    def test_invalid_stored_data_returns_error_without_overwrite(self):
        self.api('PUT', '/api/config', self.config())
        alias_path = self.home / 'aliases.json'
        alias_path.write_text('{"all":{"bad":42}}', encoding='utf-8')
        before = self.files()
        self.api('GET', '/api/state', expected=500)
        self.api('POST', '/api/aliases', {'platform': 'all', 'name': 'gs', 'command': 'git status'}, 500)
        self.assertEqual(self.files(), before)
        alias_path.write_text('{}', encoding='utf-8')
        (self.home / 'config.json').write_text('{"port":42}', encoding='utf-8')
        self.api('GET', '/api/config', expected=500)
        self.assertEqual(self.request('GET', '/')[0], 200)

    def test_cross_origin_and_host_protection(self):
        before = self.files()
        self.api('GET', '/api/state', expected=403, headers={'Host': f'attacker.test:{self.port}'})
        self.api('PUT', '/api/config', self.config(), 403,
                 headers={'Origin': 'https://example.com'})
        self.api('PUT', '/api/config', self.config(), 403, headers={'X-Proxy-Request': None})
        self.api('PUT', '/api/config', self.config(), 415, headers={'Content-Type': 'text/plain'})
        self.api('PUT', '/api/config', self.config(), 403, headers={'Origin': 'null'})
        self.assertEqual(self.files(), before)
        self.api('PUT', '/api/config', self.config(),
                 headers={'Origin': f'http://127.0.0.1:{self.port}'})

    def test_concurrent_writes_and_idle_browser_connection(self):
        idle = socket.create_connection(('127.0.0.1', self.port), timeout=2)
        try:
            start = time.monotonic()
            self.api('GET', '/api/state')
            self.assertLess(time.monotonic() - start, 2)
            def create(index):
                return self.api('POST', '/api/aliases',
                                {'platform': 'all', 'name': f'alias-{index}', 'command': f'echo {index}'}, 201)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(create, range(20)))
            self.assertEqual(len(self.api('GET', '/api/aliases')), 20)
            self.assertEqual(len(json.loads((self.home / 'aliases.json').read_text())['all']), 20)
        finally:
            idle.close()

    def test_node_order_persistence_cli_indexes_and_edit_stability(self):
        for index, name in enumerate(('dev', 'office', '备用 / 节点')):
            self.api('POST', '/api/nodes', self.config(name=name, port=str(7890 + index)), 201)
        self.api('POST', '/api/nodes/activate', {'name': 'office'})
        current = self.api('GET', '/api/config')
        entries = {entry['name']: entry for entry in self.api('GET', '/api/nodes')}
        wanted = ['备用 / 节点', 'dev', 'office']
        self.api('PUT', '/api/nodes/order', {'names': wanted})
        self.assertEqual(self.api('GET', '/api/nodes'), [entries[name] for name in wanted])
        self.assertEqual(self.api('GET', '/api/config'), current)
        self.assertEqual(list(json.loads((self.home / 'profiles.json').read_text(encoding='utf-8'))), wanted)
        self.stop_server()
        self.start_server()
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/nodes')], wanted)
        self.cli('switch', '1')
        self.assertEqual(self.api('GET', '/api/config')['node'], wanted[0])
        self.cli('node', 'rename', '1', 'renamed')
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/nodes')], ['renamed', 'dev', 'office'])
        self.api('PUT', '/api/nodes', self.config(name='web-renamed', original_name='renamed'))
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/nodes')], ['web-renamed', 'dev', 'office'])
        self.api('DELETE', '/api/nodes', {'name': 'web-renamed'})
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/nodes')], ['dev', 'office'])
        self.assertEqual(self.api('GET', '/api/config')['node'], '')

    def test_invalid_and_stale_node_orders_do_not_change_files(self):
        for name in ('a', 'b', 'c'):
            self.api('POST', '/api/nodes', self.config(name=name), 201)
        before = self.files()
        for names, expected in ((['a', 'a', 'c'], 400), (['a', 'b'], 409),
                                (['a', 'b', 'missing'], 409), (['a', 2, 'c'], 400),
                                ('a,b,c', 400)):
            with self.subTest(names=names):
                self.api('PUT', '/api/nodes/order', {'names': names}, expected)
                self.assertEqual(self.files(), before)
        self.api('GET', '/api/nodes/order', expected=405)
        self.cli('node', 'save', 'new-from-cli')
        before = self.files()
        self.api('PUT', '/api/nodes/order', {'names': ['c', 'b', 'a']}, 409)
        self.assertEqual(self.files(), before)
        self.assertEqual(len(self.api('GET', '/api/nodes')), 4)

    def test_alias_order_interleaves_platforms_without_changing_commands(self):
        aliases = [
            {'platform': 'all', 'name': 'same', 'command': 'echo all'},
            {'platform': 'windows', 'name': 'same', 'command': 'cmd /c echo windows'},
            {'platform': 'linux', 'name': 'build', 'command': 'make'},
            {'platform': 'all', 'name': 'format', 'command': 'tool "C:\\示例\\quoted"'},
        ]
        for alias in aliases:
            self.api('POST', '/api/aliases', alias, 201)
        original_aliases = (self.home / 'aliases.json').read_bytes()
        current = self.api('GET', '/api/config')
        wanted = [aliases[index] for index in (3, 1, 2, 0)]
        identities = [{'platform': alias['platform'], 'name': alias['name']} for alias in wanted]
        self.api('PUT', '/api/aliases/order', {'aliases': identities})
        self.assertEqual(self.api('GET', '/api/aliases'), wanted)
        self.assertEqual((self.home / 'aliases.json').read_bytes(), original_aliases)
        self.assertEqual(self.api('GET', '/api/config'), current)
        self.assertEqual(json.loads((self.home / 'order.json').read_text(encoding='utf-8'))['aliases'], identities)
        self.stop_server()
        self.start_server()
        self.assertEqual(self.api('GET', '/api/aliases'), wanted)
        self.cli('alias', 'add', 'all', 'new', 'echo appended')
        self.assertEqual(self.api('GET', '/api/aliases'), wanted + [{'platform': 'all', 'name': 'new', 'command': 'echo appended'}])

    def test_alias_order_survives_rename_platform_move_and_delete(self):
        for name in ('a', 'b', 'c'):
            self.api('POST', '/api/aliases', {'platform': 'all', 'name': name, 'command': f'echo {name}'}, 201)
        self.api('PUT', '/api/aliases/order', {'aliases': [{'platform': 'all', 'name': name} for name in ('c', 'b', 'a')]})
        self.api('PUT', '/api/aliases', {'platform': 'macos', 'name': 'renamed', 'command': 'echo renamed',
                                       'original_platform': 'all', 'original_name': 'c'})
        self.assertEqual([(entry['platform'], entry['name']) for entry in self.api('GET', '/api/aliases')],
                         [('macos', 'renamed'), ('all', 'b'), ('all', 'a')])
        self.api('PUT', '/api/aliases', {'platform': 'all', 'name': 'b', 'command': 'echo updated',
                                       'original_platform': 'all', 'original_name': 'b'})
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/aliases')], ['renamed', 'b', 'a'])
        self.cli('alias', 'remove', 'all', 'b')
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/aliases')], ['renamed', 'a'])
        self.cli('alias', 'add', 'all', 'b', 'echo new')
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/aliases')], ['renamed', 'a', 'b'])
        self.api('DELETE', '/api/aliases', {'platform': 'macos', 'name': 'renamed'})
        self.assertEqual([entry['name'] for entry in self.api('GET', '/api/aliases')], ['a', 'b'])

    def test_invalid_and_stale_alias_orders_do_not_change_files(self):
        a = {'platform': 'all', 'name': 'a'}
        b = {'platform': 'windows', 'name': 'a'}
        for identity in (a, b):
            self.api('POST', '/api/aliases', {**identity, 'command': 'echo keep'}, 201)
        self.api('PUT', '/api/aliases/order', {'aliases': [b, a]})
        before = self.files()
        for order, expected in (([a, a], 400), ([a], 409), ([a, {'platform': 'linux', 'name': 'missing'}], 409),
                                ([a, {'name': 'a'}], 400), ([a, 'bad'], 400), ({}, 400)):
            with self.subTest(order=order):
                self.api('PUT', '/api/aliases/order', {'aliases': order}, expected)
                self.assertEqual(self.files(), before)
        self.cli('alias', 'add', 'all', 'new', 'echo new')
        before = self.files()
        self.api('PUT', '/api/aliases/order', {'aliases': [a, b]}, 409)
        self.assertEqual(self.files(), before)
        self.assertEqual(len(self.api('GET', '/api/aliases')), 3)

    def test_request_limits_and_incomplete_body(self):
        self.api('PUT', '/api/config', expected=413, raw=b'',
                 headers={'Content-Length': str(64 * 1024 + 1)})
        with socket.create_connection(('127.0.0.1', self.port), timeout=3) as connection:
            headers = (f'PUT /api/config HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n'
                       'Content-Type: application/json\r\nX-Proxy-Request: 1\r\n'
                       'Content-Length: 100\r\n\r\n{')
            connection.sendall(headers.encode())
            connection.shutdown(socket.SHUT_WR)
            self.assertIn(b'400 Bad Request', connection.recv(4096))
        self.assertEqual(self.files(), {})


if __name__ == '__main__':
    if not BINARY.is_file():
        raise SystemExit(f'Build the executable first: {BINARY}')
    unittest.main(verbosity=2)
