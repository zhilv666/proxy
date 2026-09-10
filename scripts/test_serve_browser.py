#!/usr/bin/env python3
"""Browser regression for sorting; requires Python Playwright and Chromium.

Run after zig build: python -B scripts/test_serve_browser.py [path/to/proxy]
Uses an isolated PROXY_HOME and writes screenshots to .zig-cache.
"""

import json
from pathlib import Path
import re

from playwright.sync_api import expect, sync_playwright
from test_serve import ServeTests


def keys(page, kind):
    selector = '#node-rows' if kind == 'nodes' else '#alias-rows'
    return page.locator(f'{selector} tr').evaluate_all('(rows) => rows.map(row => row.dataset.sortKey)')


def wait_order(page, kind, wanted):
    selector = '#node-rows' if kind == 'nodes' else '#alias-rows'
    page.wait_for_function(
        '({selector, wanted}) => JSON.stringify(Array.from(document.querySelector(selector).children, row => row.dataset.sortKey)) === JSON.stringify(wanted)',
        arg={'selector': selector, 'wanted': wanted},
    )
    expect(page.locator('#refresh')).to_be_enabled()


def row(page, kind, key):
    selector = '#node-rows' if kind == 'nodes' else '#alias-rows'
    return page.locator(f'{selector} tr').nth(keys(page, kind).index(key))


def mouse_move(page, kind, source, target, after=False):
    selector = '#node-rows' if kind == 'nodes' else '#alias-rows'
    page.locator(selector).evaluate('(body) => window.scrollTo(0, body.getBoundingClientRect().top + window.scrollY - 180)')
    source_box = row(page, kind, source).locator('.drag-handle').bounding_box()
    target_box = row(page, kind, target).bounding_box()
    target_y = target_box['y'] + (target_box['height'] - 8 if after else 8)
    page.mouse.move(source_box['x'] + source_box['width'] / 2, source_box['y'] + source_box['height'] / 2)
    page.mouse.down()
    page.mouse.move(source_box['x'] + source_box['width'] / 2, target_y, steps=12)
    expect(row(page, kind, target)).to_have_class(re.compile('drop-after' if after else 'drop-before'))
    page.mouse.up()


fixture = ServeTests(methodName='runTest')
artifacts = Path(__file__).resolve().parents[1] / '.zig-cache'
artifacts.mkdir(exist_ok=True)
try:
    fixture.setUp()
    for index, name in enumerate(('本地开发', '公司内网', '香港节点', '备用节点')):
        fixture.api('POST', '/api/nodes', fixture.config(name=name, port=str(7890 + index)), 201)
    fixture.api('POST', '/api/nodes/activate', {'name': '本地开发'})
    aliases = [
        {'platform': 'all', 'name': 'gs', 'command': 'git status --short'},
        {'platform': 'windows', 'name': 'open', 'command': 'explorer .'},
        {'platform': 'all', 'name': 'build', 'command': 'zig build -Doptimize=ReleaseFast'},
        {'platform': 'linux', 'name': 'update', 'command': 'sudo apt update'},
    ]
    for alias in aliases:
        fixture.api('POST', '/api/aliases', alias, 201)
    current = fixture.api('GET', '/api/config')
    original_commands = (fixture.home / 'aliases.json').read_bytes()
    url = f'http://127.0.0.1:{fixture.port}/'

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        context = browser.new_context(viewport={'width': 1600, 'height': 1150})
        page = context.new_page()
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('dialog', lambda dialog: dialog.accept())
        page.goto(url)
        expect(page.locator('#node-rows tr')).to_have_count(4)
        expect(page.locator('#active-node')).to_have_text('本地开发')
        expect(page.locator('#active-address')).to_have_text(f"{current['protocol']}://{current['host']}:{current['port']}")
        assert page.locator('#current-form').count() == 0

        mouse_move(page, 'nodes', '备用节点', '本地开发')
        wait_order(page, 'nodes', ['备用节点', '本地开发', '公司内网', '香港节点'])
        expect(row(page, 'nodes', '备用节点').locator('.drag-handle')).to_be_focused()
        mouse_move(page, 'nodes', '备用节点', '香港节点', after=True)
        wait_order(page, 'nodes', ['本地开发', '公司内网', '香港节点', '备用节点'])
        row(page, 'nodes', '备用节点').locator('.drag-handle').press('Home')
        wait_order(page, 'nodes', ['备用节点', '本地开发', '公司内网', '香港节点'])
        row(page, 'nodes', '备用节点').locator('.drag-handle').press('ArrowDown')
        wait_order(page, 'nodes', ['本地开发', '备用节点', '公司内网', '香港节点'])
        row(page, 'nodes', '香港节点').locator('.drag-handle').press('Home')
        wait_order(page, 'nodes', ['香港节点', '本地开发', '备用节点', '公司内网'])
        page.locator('#node-search').fill('节点')
        row(page, 'nodes', '备用节点').locator('.drag-handle').press('Home')
        wait_order(page, 'nodes', ['备用节点', '香港节点'])
        page.locator('#node-search').fill('')
        wait_order(page, 'nodes', ['备用节点', '本地开发', '香港节点', '公司内网'])
        assert fixture.api('GET', '/api/config') == current
        page.locator('#refresh').click()
        expect(page.locator('#refresh')).to_be_enabled()

        # A failed save must retain the visible order and the data on disk.
        before = keys(page, 'nodes')
        page.route('**/api/nodes/order', lambda route: route.fulfill(
            status=500, content_type='application/json', body=json.dumps({'error': '排序保存失败测试'})))
        row(page, 'nodes', before[0]).locator('.drag-handle').press('End')
        expect(page.locator('#notification')).to_contain_text('排序保存失败测试')
        assert keys(page, 'nodes') == before
        assert [entry['name'] for entry in fixture.api('GET', '/api/nodes')] == before
        page.unroute('**/api/nodes/order')

        # A stale browser cannot drop a node created by another client.
        fixture.api('POST', '/api/nodes', fixture.config(name='新建节点'), 201)
        row(page, 'nodes', before[0]).locator('.drag-handle').press('End')
        expect(page.locator('#notification')).to_contain_text('配置列表已变化')
        assert keys(page, 'nodes') == before
        page.locator('#refresh').click()
        wait_order(page, 'nodes', before + ['新建节点'])
        page.reload()
        wait_order(page, 'nodes', before + ['新建节点'])
        page.screenshot(path=str(artifacts / 'serve-sort-proxies-desktop.png'), full_page=True)

        page.locator('[data-view=aliases]').click()
        initial = keys(page, 'aliases')
        mouse_move(page, 'aliases', initial[-1], initial[0])
        wanted = [initial[-1], *initial[:-1]]
        wait_order(page, 'aliases', wanted)
        row(page, 'aliases', wanted[0]).locator('.drag-handle').press('ArrowDown')
        wanted[0], wanted[1] = wanted[1], wanted[0]
        wait_order(page, 'aliases', wanted)
        page.locator('#platform-filter').select_option('all')
        visible = keys(page, 'aliases')
        row(page, 'aliases', visible[0]).locator('.drag-handle').press('End')
        wait_order(page, 'aliases', list(reversed(visible)))
        slots = [index for index, identity in enumerate(wanted) if identity in visible]
        for index, identity in zip(slots, reversed(visible)):
            wanted[index] = identity
        page.locator('#platform-filter').select_option('*')
        wait_order(page, 'aliases', wanted)
        assert (fixture.home / 'aliases.json').read_bytes() == original_commands
        page.reload()
        page.locator('[data-view=aliases]').click()
        wait_order(page, 'aliases', wanted)
        page.screenshot(path=str(artifacts / 'serve-sort-aliases-desktop.png'), full_page=True)

        # Exercise actual touch pointer events, rather than mouse emulation.
        mobile = browser.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
        touch_page = mobile.new_page()
        touch_page.on('pageerror', lambda error: errors.append(str(error)))
        touch_page.goto(url)
        expect(touch_page.locator('#node-rows tr')).to_have_count(5)
        assert touch_page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
        order = keys(touch_page, 'nodes')
        touch_page.locator('#node-rows').evaluate('(body) => window.scrollTo(0, body.getBoundingClientRect().top + window.scrollY - 70)')
        source_box = row(touch_page, 'nodes', order[1]).locator('.drag-handle').bounding_box()
        target_box = row(touch_page, 'nodes', order[0]).bounding_box()
        start_x = source_box['x'] + source_box['width'] / 2
        start_y = source_box['y'] + source_box['height'] / 2
        end_y = target_box['y'] + 14
        cdp = mobile.new_cdp_session(touch_page)
        cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': start_x, 'y': start_y}]})
        for step in range(1, 13):
            cdp.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [
                {'x': start_x, 'y': start_y + (end_y - start_y) * step / 12}]})
        expect(row(touch_page, 'nodes', order[0])).to_have_class(re.compile('drop-before'))
        cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
        order[0], order[1] = order[1], order[0]
        wait_order(touch_page, 'nodes', order)
        touch_page.reload()
        wait_order(touch_page, 'nodes', order)
        touch_page.screenshot(path=str(artifacts / 'serve-sort-proxies-mobile.png'), full_page=True)
        touch_page.locator('[data-view=aliases]').click()
        assert touch_page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
        touch_page.screenshot(path=str(artifacts / 'serve-sort-aliases-mobile.png'), full_page=True)
        touch_page.locator('#add-entry').click()
        expect(touch_page.locator('#editor-dialog')).to_be_visible()
        assert touch_page.locator('#editor-dialog').bounding_box()['width'] <= 390
        touch_page.screenshot(path=str(artifacts / 'serve-sort-editor-mobile.png'), full_page=True)
        assert not errors, errors
        browser.close()
        print('Browser sorting checks passed: mouse, touch, keyboard, filtered order, persistence,')
        print('stale lists, save failures, unchanged proxy/commands, and responsive layout.')
finally:
    fixture.doCleanups()
