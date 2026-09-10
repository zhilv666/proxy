'use strict';

const $ = (selector, root = document) => root.querySelector(selector);
const platforms = { all: '通用 · all', windows: 'Windows', linux: 'Linux', macos: 'macOS' };
const defaults = { host: '127.0.0.1', port: '7890', protocol: 'http', username: '', password: '' };
const editorDialog = $('#editor-dialog');
const editorForm = $('#editor-form');
let state = null;
let view = 'proxies';
let connected = false;
let busy = false;
let editing = null;
let notificationTimer;
let sortSession = null;

// 主题：优先用户选择，其次跟随系统；未手动选择时系统切换实时生效
const systemDark = window.matchMedia('(prefers-color-scheme: dark)');

function applyTheme(theme) {
  const dark = theme === 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  const toggle = $('#theme-toggle');
  toggle.setAttribute('aria-pressed', String(dark));
  const label = dark ? '切换到浅色模式' : '切换到深色模式';
  toggle.setAttribute('aria-label', label);
  toggle.title = label;
}

applyTheme(localStorage.getItem('proxy-theme') || (systemDark.matches ? 'dark' : 'light'));

$('#theme-toggle').addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('proxy-theme', next);
  applyTheme(next);
});

systemDark.addEventListener('change', event => {
  if (!localStorage.getItem('proxy-theme')) applyTheme(event.matches ? 'dark' : 'light');
});

// 检查更新：比对 GitHub 最新 Release 与当前编译版本，有新版本时在左下角提示
const RELEASES_API = 'https://api.github.com/repos/zhilv666/proxy/releases/latest';
let updateChecked = false;
let latestRelease = null;

function parseVersion(text) {
  const match = /(\d+)\.(\d+)(?:\.(\d+))?([-+.0-9A-Za-z]*)/.exec(text || '');
  if (!match) return null;
  // dev 为后缀标记：1.4.2-6-g37bd812-dirty 这类构建视为同号正式版的预发布
  return { parts: [Number(match[1]), Number(match[2]), Number(match[3] || 0)], dev: match[4].length > 0 };
}

function isNewer(latest, current) {
  for (let index = 0; index < 3; index++) {
    if (latest.parts[index] !== current.parts[index]) return latest.parts[index] > current.parts[index];
  }
  return current.dev && !latest.dev;
}

async function checkUpdates(currentVersion) {
  const button = $('#update-available');
  try {
    const response = await fetch(RELEASES_API, {
      headers: { Accept: 'application/vnd.github+json' },
      cache: 'no-store',
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) return;
    const release = await response.json();
    const latest = parseVersion(release.tag_name);
    if (!latest) return;
    const current = parseVersion(currentVersion);
    // 当前版本无法解析（如 dev 构建）时也提示，便于开发环境发现正式版
    if (!current || isNewer(latest, current)) {
      latestRelease = release;
      $('#latest-version').textContent = release.tag_name;
      button.hidden = false;
    }
  } catch {
    // 离线、被限流或网络受限时静默跳过，不影响配置管理
  }
}

function escapeHtml(text) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// 轻量 Markdown 渲染：标题、列表、代码块、行内代码、加粗、链接（仅 http/https）
function renderMarkdown(markdown) {
  const inline = text => escapeHtml(text)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  const html = [];
  let inCode = false;
  let inList = false;
  const closeList = () => { if (inList) { html.push('</ul>'); inList = false; } };
  for (const line of (markdown || '').replace(/\r\n?/g, '\n').split('\n')) {
    if (/^```/.test(line)) {
      closeList();
      html.push(inCode ? '</pre>' : '<pre>');
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      html.push(`${escapeHtml(line)}\n`);
      continue;
    }
    const heading = /^(#{1,4})\s+(.*)$/.exec(line);
    if (heading) {
      closeList();
      html.push(`<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`);
      continue;
    }
    const item = /^\s*[-*]\s+(.*)$/.exec(line);
    if (item) {
      if (!inList) { html.push('<ul>'); inList = true; }
      html.push(`<li>${inline(item[1])}</li>`);
      continue;
    }
    closeList();
    if (line.trim()) html.push(`<p>${inline(line)}</p>`);
  }
  closeList();
  if (inCode) html.push('</pre>');
  return html.join('');
}

function openUpdateDialog() {
  if (!latestRelease) return;
  $('#update-title').textContent = `发现新版本 ${latestRelease.tag_name}`;
  const published = (latestRelease.published_at || '').slice(0, 10);
  $('#update-meta').textContent = published ? `发布于 ${published} · 当前版本 ${state?.version || '未知'}` : `当前版本 ${state?.version || '未知'}`;
  $('#update-notes').innerHTML = renderMarkdown(latestRelease.body) || '<p class="muted">该版本暂无更新说明。</p>';
  $('#update-link').href = latestRelease.html_url || 'https://github.com/zhilv666/proxy/releases/latest';
  $('#update-dialog').showModal();
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

async function api(path, method = 'GET', body) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const headers = { Accept: 'application/json' };
    const options = { method, headers, cache: 'no-store', signal: controller.signal };
    if (method !== 'GET') {
      headers['Content-Type'] = 'application/json';
      headers['X-Proxy-Request'] = '1';
      options.body = JSON.stringify(body ?? {});
    }
    const response = await fetch(path, options);
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || `请求失败（${response.status}）`);
    return result;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('连接超时，请确认本地服务仍在运行。');
    if (error instanceof TypeError) throw new Error('无法连接本地服务，请确认 proxy serve 仍在运行，然后刷新。');
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

function notify(message, isError = false) {
  const box = $('#notification');
  clearTimeout(notificationTimer);
  box.textContent = message;
  box.classList.toggle('error', isError);
  box.hidden = false;
  notificationTimer = setTimeout(() => { box.hidden = true; }, isError ? 8000 : 4000);
}

function setControls() {
  document.querySelectorAll('[data-write]').forEach(button => {
    button.disabled = busy || !connected;
  });
  document.querySelectorAll('.drag-handle').forEach(button => {
    button.disabled ||= button.closest('tbody').children.length < 2;
  });
  $('#editor-fields').disabled = busy;
  $('#refresh').disabled = busy;
  $('#editor-dialog .dialog-close').disabled = busy;
  $('.dialog-cancel').disabled = busy;
  $('#editor-submit').textContent = busy ? '正在保存…' : editing?.kind === 'alias' ? '保存别名' : '保存节点';
}

function showConnectionError(message) {
  connected = false;
  const banner = $('#connection-error');
  banner.textContent = message;
  banner.hidden = false;
  if (!state) {
    $('#active-node').textContent = '读取失败';
    $('#active-address').textContent = '检查配置后点击刷新';
    setEmpty('nodes', 0, '配置暂时不可用', '检查上方提示，处理后点击刷新。');
    setEmpty('aliases', 0, '配置暂时不可用', '检查上方提示，处理后点击刷新。');
  }
  setControls();
}

function effective(config) {
  return {
    ...config,
    host: config.host || defaults.host,
    port: config.port || defaults.port,
    protocol: config.protocol || defaults.protocol,
  };
}

function fillForm(form, values) {
  for (const [name, value] of Object.entries(values)) {
    const field = form.elements.namedItem(name);
    if (field && 'value' in field) field.value = value;
  }
}

function applyState(next) {
  state = next;
  connected = true;
  $('#connection-error').hidden = true;
  const config = effective(state.config);
  $('#active-node').textContent = config.node || '独立配置';
  $('#active-address').textContent = `${config.protocol}://${config.host}:${config.port}`;
  $('#node-count').textContent = state.nodes.length;
  $('#alias-count').textContent = state.aliases.length;
  $('#nav-node-count').textContent = state.nodes.length;
  $('#nav-alias-count').textContent = state.aliases.length;
  $('#platform-detail').textContent = `当前平台 · ${platforms[state.platform] || state.platform}`;
  if (state.version) {
    const versionEl = $('#app-version');
    versionEl.textContent = `v${state.version}`;
    versionEl.title = state.commit ? `编译版本 ${state.version}（提交 ${state.commit}）` : `编译版本 ${state.version}`;
  }
  renderNodes();
  renderAliases();
  setControls();
  if (!updateChecked) {
    updateChecked = true;
    checkUpdates(state.version);
  }
}

async function refresh(announce = false) {
  if (busy) return;
  cancelSort();
  busy = true;
  setControls();
  try {
    applyState(await api('/api/state'));
    if (announce) notify('已读取最新配置');
  } catch (error) {
    showConnectionError(error.message);
  } finally {
    busy = false;
    setControls();
  }
}

async function mutate(path, method, payload, message, { closeEditor = false } = {}) {
  if (busy || !connected) return;
  busy = true;
  setControls();
  $('#editor-error').hidden = true;
  try {
    await api(path, method, payload);
    if (closeEditor) editorDialog.close();
    try {
      applyState(await api('/api/state'));
      notify(message);
    } catch (error) {
      showConnectionError(`${message}，但无法读取最新状态。${error.message}`);
    }
  } catch (error) {
    if (editorDialog.open) {
      $('#editor-error').textContent = error.message;
      $('#editor-error').hidden = false;
    } else {
      notify(error.message, true);
    }
  } finally {
    busy = false;
    setControls();
  }
}

function setEmpty(kind, count, title, description) {
  const box = $(`#${kind}-empty`);
  box.hidden = count !== 0;
  $('h3', box).textContent = title;
  $('p', box).textContent = description;
}

function rowButton(label, action, danger = false) {
  const button = element('button', `text-button${danger ? ' danger' : ''}`, label);
  button.type = 'button';
  button.dataset.write = '';
  button.addEventListener('click', action);
  return button;
}

function sortKey(kind, entry) {
  return kind === 'nodes' ? entry.name : JSON.stringify([entry.platform, entry.name]);
}

function sortBody(kind) {
  return $(kind === 'nodes' ? '#node-rows' : '#alias-rows');
}

function sortCell(kind, entry) {
  const cell = element('td', 'drag-cell');
  const button = element('button', 'drag-handle');
  button.type = 'button';
  button.dataset.write = '';
  button.setAttribute('aria-label', `调整「${entry.name}」的顺序`);
  button.setAttribute('aria-describedby', `${kind === 'nodes' ? 'node' : 'alias'}-sort-help sort-instructions`);
  button.title = '拖动排序；也可用方向键上移、下移';
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  icon.setAttribute('aria-hidden', 'true');
  use.setAttribute('href', '#icon-grip');
  icon.append(use);
  button.append(icon);
  button.addEventListener('pointerdown', event => {
    if (busy || !connected || sortSession || !event.isPrimary || event.button !== 0) return;
    event.preventDefault();
    button.focus({ preventScroll: true });
    sortSession = {
      kind, key: sortKey(kind, entry), button, row: button.closest('tr'),
      pointerId: event.pointerId, startX: event.clientX, startY: event.clientY,
      x: event.clientX, y: event.clientY, active: false, target: null, after: false, frame: 0,
    };
    button.setPointerCapture(event.pointerId);
  });
  button.addEventListener('pointermove', event => {
    if (!sortSession || event.pointerId !== sortSession.pointerId) return;
    sortSession.x = event.clientX;
    sortSession.y = event.clientY;
    if (!sortSession.active && Math.hypot(event.clientX - sortSession.startX, event.clientY - sortSession.startY) >= 5) {
      sortSession.active = true;
      sortSession.row.classList.add('dragging');
      document.body.classList.add('sorting');
      scrollWhileSorting();
    }
    if (sortSession.active) updateSortTarget();
  });
  button.addEventListener('pointerup', event => {
    if (!sortSession || event.pointerId !== sortSession.pointerId) return;
    const { active, key, target, after } = sortSession;
    cancelSort();
    if (active && target) saveVisibleOrder(kind, key, target, after);
  });
  button.addEventListener('pointercancel', cancelSort);
  button.addEventListener('lostpointercapture', cancelSort);
  button.addEventListener('keydown', event => {
    if (busy || !connected || sortSession || event.altKey || event.ctrlKey || event.metaKey) return;
    const rows = Array.from(sortBody(kind).children);
    const key = sortKey(kind, entry);
    const index = rows.findIndex(row => row.dataset.sortKey === key);
    const positions = { ArrowUp: index - 1, ArrowDown: index + 1, Home: 0, End: rows.length - 1 };
    if (!(event.key in positions)) return;
    event.preventDefault();
    const targetIndex = Math.max(0, Math.min(rows.length - 1, positions[event.key]));
    if (targetIndex !== index) saveVisibleOrder(kind, key, rows[targetIndex].dataset.sortKey, targetIndex > index);
  });
  cell.append(button);
  return cell;
}

function updateSortTarget() {
  if (!sortSession?.active) return;
  const body = sortBody(sortSession.kind);
  body.querySelectorAll('.drop-before, .drop-after').forEach(row => row.classList.remove('drop-before', 'drop-after'));
  sortSession.target = null;
  const bounds = body.getBoundingClientRect();
  if (sortSession.x < bounds.left || sortSession.x > bounds.right ||
      sortSession.y < bounds.top - 32 || sortSession.y > bounds.bottom + 32) return;
  const rows = Array.from(body.children);
  const target = rows.find(row => sortSession.y < row.getBoundingClientRect().bottom) || rows.at(-1);
  if (!target || target === sortSession.row) return;
  const rect = target.getBoundingClientRect();
  sortSession.after = sortSession.y > rect.top + rect.height / 2;
  sortSession.target = target.dataset.sortKey;
  target.classList.add(sortSession.after ? 'drop-after' : 'drop-before');
}

function scrollWhileSorting() {
  if (!sortSession?.active) return;
  const edge = 80;
  const y = sortSession.y;
  const delta = y < edge ? -Math.min(18, (edge - y) / 4)
    : y > window.innerHeight - edge ? Math.min(18, (y - window.innerHeight + edge) / 4) : 0;
  if (delta) window.scrollBy(0, delta);
  updateSortTarget();
  sortSession.frame = requestAnimationFrame(scrollWhileSorting);
}

function cancelSort() {
  const session = sortSession;
  if (!session) return;
  sortSession = null;
  cancelAnimationFrame(session.frame);
  session.row.classList.remove('dragging');
  sortBody(session.kind).querySelectorAll('.drop-before, .drop-after').forEach(row => row.classList.remove('drop-before', 'drop-after'));
  document.body.classList.remove('sorting');
  if (session.button.hasPointerCapture(session.pointerId)) session.button.releasePointerCapture(session.pointerId);
}

async function saveVisibleOrder(kind, key, target, after) {
  if (busy || !connected) return;
  const visibleKeys = Array.from(sortBody(kind).children, row => row.dataset.sortKey);
  if (key === target || !visibleKeys.includes(key) || !visibleKeys.includes(target)) return;
  const reordered = visibleKeys.filter(value => value !== key);
  reordered.splice(reordered.indexOf(target) + (after ? 1 : 0), 0, key);
  if (reordered.every((value, index) => value === visibleKeys[index])) return;
  const entries = new Map(state[kind].map(entry => [sortKey(kind, entry), entry]));
  const visible = new Set(visibleKeys);
  let next = 0;
  // Keep hidden entries in their original slots when a search/filter is active.
  const complete = state[kind].map(entry => visible.has(sortKey(kind, entry)) ? entries.get(reordered[next++]) : entry);
  const payload = kind === 'nodes' ? { names: complete.map(entry => entry.name) }
    : { aliases: complete.map(({ platform, name }) => ({ platform, name })) };
  notify('正在保存顺序…');
  await mutate(`/api/${kind}/order`, 'PUT', payload, '顺序已保存');
  const moved = Array.from(sortBody(kind).children).find(row => row.dataset.sortKey === key);
  $('.drag-handle', moved || sortBody(kind))?.focus({ preventScroll: true });
}

function renderNodes() {
  if (!state) return;
  const query = $('#node-search').value.trim().toLocaleLowerCase();
  const rows = $('#node-rows');
  rows.replaceChildren();
  let visible = 0;
  state.nodes.forEach((node, index) => {
    const value = effective(node);
    if (!`${value.name} ${value.host} ${value.port} ${value.protocol}`.toLocaleLowerCase().includes(query)) return;
    visible++;
    const isActive = node.name === state.config.node;
    const row = element('tr');
    row.dataset.sortKey = sortKey('nodes', node);
    row.append(sortCell('nodes', node), element('td', 'index-cell', String(index + 1).padStart(2, '0')));
    const nameCell = element('td', 'name-cell');
    const name = element('div', 'node-name');
    name.append(element('span', '', node.name));
    if (isActive) name.append(element('span', 'badge green', '当前'));
    nameCell.append(name);
    const addressCell = element('td');
    addressCell.dataset.label = '代理地址';
    const address = element('div', 'node-address');
    address.append(element('span', 'protocol-label', value.protocol.toUpperCase()), element('span', 'mono', `${value.host}:${value.port}`));
    addressCell.append(address);
    const credentials = element('td', 'credential-cell', node.username || (node.password ? '已设置密码' : '未设置'));
    credentials.dataset.label = '身份验证';
    const actionsCell = element('td', 'actions-cell');
    const actions = element('div', 'row-actions');
    if (isActive) {
      actions.append(element('span', 'active-label', '使用中'));
    } else {
      const activate = rowButton('启用', () => {
        mutate('/api/nodes/activate', 'POST', { name: node.name }, `已启用节点「${node.name}」`);
      });
      activate.classList.add('activate-button');
      actions.append(activate);
    }
    actions.append(rowButton('编辑', () => openEditor('node', node)), rowButton('删除', () => {
      const detail = isActive ? '删除后当前配置会保留代理参数并解除节点关联。' : '此操作无法撤销。';
      if (window.confirm(`删除节点「${node.name}」？${detail}`)) {
        mutate('/api/nodes', 'DELETE', { name: node.name }, '节点已删除');
      }
    }, true));
    actionsCell.append(actions);
    row.append(nameCell, addressCell, credentials, actionsCell);
    rows.append(row);
  });
  $('#nodes-list-count').textContent = query ? `${visible} / ${state.nodes.length}` : state.nodes.length;
  setEmpty('nodes', visible, query ? '没有找到匹配的节点' : '还没有保存的代理节点', query ? '试试其他关键词，或清空搜索条件。' : '点击「添加节点」，为不同环境保存一份配置。');
}

function renderAliases() {
  if (!state) return;
  const query = $('#alias-search').value.trim().toLocaleLowerCase();
  const platform = $('#platform-filter').value;
  const rows = $('#alias-rows');
  rows.replaceChildren();
  let visible = 0;
  for (const alias of state.aliases) {
    if (platform !== '*' && alias.platform !== platform) continue;
    if (!`${alias.name} ${alias.command}`.toLocaleLowerCase().includes(query)) continue;
    visible++;
    const row = element('tr');
    row.dataset.sortKey = sortKey('aliases', alias);
    const commandCell = element('td', 'mono command-cell', alias.command);
    commandCell.dataset.label = '命令';
    row.append(sortCell('aliases', alias), element('td', 'name-cell mono alias-name', alias.name), commandCell);
    const platformCell = element('td');
    platformCell.dataset.label = '适用平台';
    platformCell.append(element('span', 'badge', platforms[alias.platform] || alias.platform));
    const actionsCell = element('td', 'actions-cell');
    const actions = element('div', 'row-actions');
    actions.append(rowButton('编辑', () => openEditor('alias', alias)), rowButton('删除', () => {
      if (window.confirm(`删除 ${platforms[alias.platform] || alias.platform} 平台的别名「${alias.name}」？此操作无法撤销。`)) {
        mutate('/api/aliases', 'DELETE', { platform: alias.platform, name: alias.name }, '别名已删除');
      }
    }, true));
    actionsCell.append(actions);
    row.append(platformCell, actionsCell);
    rows.append(row);
  }
  const filtered = query || platform !== '*';
  $('#aliases-list-count').textContent = filtered ? `${visible} / ${state.aliases.length}` : state.aliases.length;
  setEmpty('aliases', visible, filtered ? '没有找到匹配的别名' : '让常用命令更简短', filtered ? '试试其他关键词或平台。' : '点击「添加别名」，保存你的第一条快捷命令。');
}

function switchView(next) {
  cancelSort();
  view = next;
  const aliases = view === 'aliases';
  $('#proxies-view').hidden = aliases;
  $('#aliases-view').hidden = !aliases;
  $('#page-title').textContent = aliases ? '命令别名' : '代理配置';
  $('#breadcrumb').textContent = aliases ? '命令别名' : '代理配置';
  $('#add-entry-label').textContent = aliases ? '添加别名' : '添加节点';
  document.title = `Proxy · ${aliases ? '命令别名' : '代理配置'}`;
  document.querySelectorAll('[data-view]').forEach(button => {
    const active = button.dataset.view === next;
    button.classList.toggle('active', active);
    if (active) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
}

function openEditor(kind, original = null) {
  if (busy || !connected) return;
  editing = { kind, original };
  editorForm.reset();
  $('#editor-fields').replaceChildren($(`#${kind}-editor-template`).content.cloneNode(true));
  const isAlias = kind === 'alias';
  $('#editor-title').textContent = `${original ? '编辑' : '添加'}${isAlias ? '别名' : '节点'}`;
  $('#editor-description').textContent = isAlias ? '设置名称、命令及适用平台，保存后即可在命令行使用。' : original?.name === state.config.node ? '这是当前使用的节点，保存后会同步更新当前代理。' : '保存独立的代理配置，需要时再启用。';
  const values = isAlias ? original || { name: '', platform: 'all', command: '' } : { ...effective(original || defaults), name: original?.name || '' };
  fillForm(editorForm, values);
  $('#editor-error').hidden = true;
  setControls();
  editorDialog.showModal();
  $('[name="name"]', editorForm).focus();
}

document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click', () => switchView(button.dataset.view)));
$('#refresh').addEventListener('click', () => refresh(true));
$('#add-entry').addEventListener('click', () => openEditor(view === 'aliases' ? 'alias' : 'node'));
$('#node-search').addEventListener('input', () => { cancelSort(); renderNodes(); setControls(); });
$('#alias-search').addEventListener('input', () => { cancelSort(); renderAliases(); setControls(); });
$('#platform-filter').addEventListener('change', () => { cancelSort(); renderAliases(); setControls(); });
editorForm.addEventListener('submit', event => {
  event.preventDefault();
  if (!editing || !editorForm.reportValidity()) return;
  const payload = Object.fromEntries(new FormData(editorForm));
  payload.name = payload.name.trim();
  const { kind, original } = editing;
  if (payload.host) payload.host = payload.host.trim();
  if (original) {
    payload.original_name = original.name;
    if (kind === 'alias') payload.original_platform = original.platform;
  }
  mutate(kind === 'alias' ? '/api/aliases' : '/api/nodes', original ? 'PUT' : 'POST', payload, `${kind === 'alias' ? '别名' : '节点'}已保存`, { closeEditor: true });
});
$('#update-available').addEventListener('click', openUpdateDialog);
document.querySelectorAll('.dialog-close').forEach(button => {
  button.addEventListener('click', () => button.closest('dialog').close());
});
$('.dialog-cancel').addEventListener('click', () => editorDialog.close());
editorDialog.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
document.addEventListener('click', event => {
  const toggle = event.target.closest('.password-toggle');
  if (!toggle) return;
  const field = $('input', toggle.parentElement);
  const reveal = field.type === 'password';
  field.type = reveal ? 'text' : 'password';
  toggle.textContent = reveal ? '隐藏' : '显示';
  toggle.setAttribute('aria-label', reveal ? '隐藏密码' : '显示密码');
  toggle.setAttribute('aria-pressed', String(reveal));
});
window.addEventListener('beforeunload', event => {
  if (busy) {
    event.preventDefault();
    event.returnValue = '';
  }
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && sortSession) {
    event.preventDefault();
    cancelSort();
  }
});
window.addEventListener('blur', cancelSort);

refresh();
