
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

const SAVED_LAYOUT = (() => {
  try {
    const v = localStorage.getItem('booktool.layout');
    if (v === 'gallery' || v === 'compact' || v === 'list') return v;
  } catch {}
  return 'gallery';
})();

const state = {
  view: 'all',
  layout: SAVED_LAYOUT,
  filters: {
    q: '', author: null, series: null, genre: null, status: null,
    format: null, tag: null, year_from: null, year_to: null,
    has_isbn: null, has_cover: null, has_series: null,
  },
  order: 'author',
  books: [],
  groups: [],
  selectedId: null,
  selection: new Set(),
  editing: false,
  currentBook: null,

  sources: [],
};

const _decodeQueue = [];
let _decodeRunning = false;

function scheduleDecode(img) {
  _decodeQueue.push(img);
  if (!_decodeRunning) runDecodeQueue();
}

async function runDecodeQueue() {
  _decodeRunning = true;
  try {
    while (_decodeQueue.length > 0) {
      const batch = _decodeQueue.splice(0, 16);

      await Promise.all(batch.map(img => img.decode().catch(() => null)));

      await new Promise(r => requestAnimationFrame(r));
    }
  } finally {
    _decodeRunning = false;
  }
}

function attachCover(img, url) {
  img.src = url;

  if (typeof img.decode === 'function') {
    if (img.complete) scheduleDecode(img);
    else img.addEventListener('load', () => scheduleDecode(img), { once: true });
  }
}

const LAZY_PLACEHOLDER = "data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns%3D'http%3A//www.w3.org/2000/svg'/%3E";

let _lazyCoverObserver = null;
function lazyCoverObserver() {
  if (_lazyCoverObserver) return _lazyCoverObserver;
  if (typeof IntersectionObserver !== 'function') return null;

  const root = document.querySelector('#library') || null;
  _lazyCoverObserver = new IntersectionObserver((entries, observer) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const img = entry.target;
      observer.unobserve(img);
      const url = img.dataset.src;
      if (!url) continue;
      img.removeAttribute('data-src');
      attachCover(img, url);
    }
  }, { root, rootMargin: '600px 0px', threshold: 0.01 });
  return _lazyCoverObserver;
}

function lazyAttachCover(img, url) {
  const obs = lazyCoverObserver();
  if (!obs) {

    attachCover(img, url);
    return;
  }
  img.dataset.src = url;
  if (!img.src) img.src = LAZY_PLACEHOLDER;
  obs.observe(img);
}

let toastTimer = null;
function toast(msg, kind) {
  const el = $('#toast');
  el.textContent = msg;
  el.classList.toggle('error', kind === 'error');
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
}

const FACET_STATE_KEY = (key) => `booktool.facet.${key}`;
function applyStoredFacetState() {
  for (const det of document.querySelectorAll('details.facet-group, details.library-fold')) {
    const key = det.dataset.key || det.closest('[data-key]')?.dataset.key;
    if (!key) continue;
    const v = (() => { try { return localStorage.getItem(FACET_STATE_KEY(key)); } catch { return null; } })();
    if (v === '1') det.open = true;
    else if (v === '0') det.open = false;

    det.addEventListener('toggle', () => {
      try { localStorage.setItem(FACET_STATE_KEY(key), det.open ? '1' : '0'); } catch {}
    });
  }
}
applyStoredFacetState();

$$('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    $$('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.view = btn.dataset.view;
    clearSelection();
    refresh();

    document.body.classList.remove('sidebar-open');
  });
});

function setSidebarOpen(open) {
  document.body.classList.toggle('sidebar-open', open);
  const btn = $('#sidebar-toggle');
  if (btn) btn.setAttribute('aria-expanded', open ? 'true' : 'false');
}
$('#sidebar-toggle')?.addEventListener('click', () => {
  setSidebarOpen(!document.body.classList.contains('sidebar-open'));
});

document.body.addEventListener('click', (e) => {
  if (!document.body.classList.contains('sidebar-open')) return;
  if (e.target.closest('#facets')) return;
  if (e.target.closest('#sidebar-toggle')) return;
  setSidebarOpen(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && document.body.classList.contains('sidebar-open')) {
    setSidebarOpen(false);
  }
});

$$('.layout').forEach(btn => {
  btn.addEventListener('click', () => {
    $$('.layout').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.layout = btn.dataset.layout;
    $('#library').dataset.layout = state.layout;
    try { localStorage.setItem('booktool.layout', state.layout); } catch {}
    render();
  });
});

(function applySavedLayout() {
  if (state.layout === 'gallery') return;
  $('#library').dataset.layout = state.layout;
  $$('.layout').forEach(b => {
    if (b.dataset.layout === state.layout) b.classList.add('active');
    else b.classList.remove('active');
  });
})();

const SORT_OPTIONS = [
  { value: 'author',       label: 'Author',         dir: '↑', group: 'core' },
  { value: 'title',        label: 'Title',          dir: '↑', group: 'core' },
  { value: 'series',       label: 'Series',         dir: '↑', group: 'core' },
  { value: 'year_desc',    label: 'Year, newest',   dir: '↓', group: 'time' },
  { value: 'year_asc',     label: 'Year, oldest',   dir: '↑', group: 'time' },
  { value: 'added_desc',   label: 'Recently added', dir: '↓', group: 'time' },
  { value: 'updated_desc', label: 'Recently updated', dir: '↓', group: 'time' },
  { value: 'size_desc',    label: 'File size',      dir: '↓', group: 'meta' },
];

function sortOption(value) {
  return SORT_OPTIONS.find(o => o.value === value) || SORT_OPTIONS[0];
}

function updateSortPillLabel() {
  const opt = sortOption(state.order);
  const span = $('#sort-pill .sort-label');
  if (span) span.textContent = `Sort: ${opt.label} ${opt.dir}`;
}

function renderSortMenu() {
  const menu = $('#sort-menu');
  menu.innerHTML = '';
  let lastGroup = null;
  for (const opt of SORT_OPTIONS) {
    if (lastGroup && opt.group !== lastGroup) {
      const sep = document.createElement('div');
      sep.className = 'popover-sep';
      menu.appendChild(sep);
    }
    lastGroup = opt.group;
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'popover-item';
    item.setAttribute('role', 'menuitemradio');
    if (opt.value === state.order) item.classList.add('active');
    item.innerHTML =
      `<span class="popover-item-label">${escapeHtml(opt.label)}</span>` +
      `<span class="popover-item-dir">${opt.dir}</span>`;
    item.addEventListener('click', () => {
      state.order = opt.value;
      closeSortMenu();
      updateSortPillLabel();
      refresh();
    });
    menu.appendChild(item);
  }
}

function openSortMenu() {
  renderSortMenu();
  const menu = $('#sort-menu');
  const pill = $('#sort-pill');
  pill.setAttribute('aria-expanded', 'true');
  menu.hidden = false;

  setTimeout(() => document.addEventListener('click', onSortOutside, { once: true }), 0);

  document.addEventListener('keydown', onSortKey);
}
function closeSortMenu() {
  $('#sort-menu').hidden = true;
  $('#sort-pill').setAttribute('aria-expanded', 'false');
  document.removeEventListener('keydown', onSortKey);
}
function onSortOutside(e) {
  if (e.target.closest('#sort-pill') || e.target.closest('#sort-menu')) {

    setTimeout(() => document.addEventListener('click', onSortOutside, { once: true }), 0);
    return;
  }
  closeSortMenu();
}
function onSortKey(e) { if (e.key === 'Escape') closeSortMenu(); }

$('#sort-pill').addEventListener('click', (e) => {
  e.stopPropagation();
  if ($('#sort-menu').hidden) openSortMenu();
  else closeSortMenu();
});

updateSortPillLabel();

let searchTimer = null;
$('#search').addEventListener('input', (e) => {
  const raw = e.target.value;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    parseSearchInto(raw, state.filters);
    refresh();

    if (state.filters.q && state.filters.q.length >= 2) {
      addSearchHistoryEntry(state.filters.q);
    }
  }, 180);
});
$('#search').addEventListener('focus', () => showSearchHistoryDropdown());
$('#search').addEventListener('blur', () => {

  setTimeout(hideSearchHistoryDropdown, 150);
});

const SEARCH_HISTORY_KEY = 'booktool.search.history';
const SEARCH_HISTORY_CAP = 10;

function getSearchHistory() {
  try { return JSON.parse(localStorage.getItem(SEARCH_HISTORY_KEY) || '[]'); }
  catch { return []; }
}
function addSearchHistoryEntry(q) {
  const t = q.trim();
  if (!t) return;
  const list = getSearchHistory();
  const i = list.findIndex(e => e.toLowerCase() === t.toLowerCase());
  if (i >= 0) list.splice(i, 1);
  list.unshift(t);
  if (list.length > SEARCH_HISTORY_CAP) list.length = SEARCH_HISTORY_CAP;
  try { localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(list)); } catch {}
}
function clearSearchHistory() {
  try { localStorage.removeItem(SEARCH_HISTORY_KEY); } catch {}
}

function showSearchHistoryDropdown() {
  const input = $('#search');
  if (input.value && input.value.length > 0) { hideSearchHistoryDropdown(); return; }
  const list = getSearchHistory();
  if (list.length === 0) return;
  let dd = $('#search-history');
  if (!dd) {
    dd = document.createElement('div');
    dd.id = 'search-history';
    dd.className = 'search-history';
    input.parentElement.appendChild(dd);
  }
  dd.innerHTML = '';
  const head = document.createElement('div');
  head.className = 'search-history-head';
  head.innerHTML = '<span>Recent searches</span>';
  const clr = document.createElement('button');
  clr.type = 'button';
  clr.className = 'search-history-clear';
  clr.textContent = 'Clear';
  clr.addEventListener('mousedown', (e) => {
    e.preventDefault();
    clearSearchHistory();
    hideSearchHistoryDropdown();
  });
  head.appendChild(clr);
  dd.appendChild(head);
  for (const entry of list) {
    const li = document.createElement('button');
    li.type = 'button';
    li.className = 'search-history-item';
    li.textContent = entry;
    li.addEventListener('mousedown', (e) => {
      e.preventDefault();
      input.value = entry;
      parseSearchInto(entry, state.filters);
      hideSearchHistoryDropdown();
      refresh();
    });
    dd.appendChild(li);
  }

  dd.hidden = false;
}
function hideSearchHistoryDropdown() {
  const dd = $('#search-history');
  if (dd) dd.hidden = true;
}

const RANK_TITLE = 1000;
const RANK_AUTHOR = 600;
const RANK_SERIES = 400;
const RANK_DESC = 100;
const RANK_EXACT_BONUS = 250;

function rankBookForQuery(book, q) {
  if (!q) return 0;
  const ql = q.toLowerCase();
  let score = 0;
  const fields = [
    [book.title, RANK_TITLE],
    [book.author_sort, RANK_AUTHOR],
    [book.series, RANK_SERIES],
    [book.description, RANK_DESC],
  ];
  for (const [f, weight] of fields) {
    if (!f) continue;
    const fl = String(f).toLowerCase();
    const idx = fl.indexOf(ql);
    if (idx < 0) continue;

    score += weight - Math.min(idx, weight - 1);
    if (fl === ql) score += RANK_EXACT_BONUS;
    if (fl.startsWith(ql)) score += 50;
  }
  return score;
}

function applyQueryRanking() {
  const q = state.filters?.q;
  if (!q || q.length < 1) return;

  const annotated = state.books.map((b, i) => ({ b, i, s: rankBookForQuery(b, q) }));
  annotated.sort((a, b) => b.s - a.s || a.i - b.i);
  state.books = annotated.map(a => a.b);
}

function parseSearchInto(raw, filters) {
  filters.q = '';
  filters.format = null;
  filters.year_from = null;
  filters.year_to = null;
  if (!raw) return;

  const tokens = [];
  let i = 0;
  while (i < raw.length) {
    while (i < raw.length && raw[i] === ' ') i++;
    if (i >= raw.length) break;
    let buf = '', inQuotes = false;
    while (i < raw.length) {
      const ch = raw[i];
      if (ch === '"') { inQuotes = !inQuotes; i++; continue; }
      if (ch === ' ' && !inQuotes) break;
      buf += ch;
      i++;
    }
    if (buf) tokens.push(buf);
  }

  const plain = [];
  for (const tok of tokens) {
    const m = tok.match(/^(\w+):(.+)$/);
    if (!m) { plain.push(tok); continue; }
    const key = m[1].toLowerCase();
    const val = m[2];
    if (key === 'author') filters.author = val;
    else if (key === 'series') filters.series = val;
    else if (key === 'genre') filters.genre = val;
    else if (key === 'status' && /^(unread|reading|finished)$/.test(val)) filters.status = val;
    else if (key === 'tag') filters.tag = val;
    else if (key === 'format' && /^(epub|mobi|azw3|pdf)$/.test(val)) filters.format = val;
    else if (key === 'year') {
      const range = val.match(/^(\d{4})-(\d{4})$/);
      const single = val.match(/^(\d{4})$/);
      if (range) { filters.year_from = +range[1]; filters.year_to = +range[2]; }
      else if (single) { filters.year_from = +val; filters.year_to = +val; }
    }
    else if (key === 'has' && /^(isbn|cover|series)$/.test(val)) filters[`has_${val}`] = true;
    else if (key === 'missing' && /^(isbn|cover|series)$/.test(val)) filters[`has_${val}`] = false;
    else plain.push(tok);
  }
  filters.q = plain.join(' ');
}

function buildQuery() {
  const params = new URLSearchParams();
  const f = state.filters;
  if (f.q) params.set('q', f.q);
  if (f.author) params.set('author', f.author);
  if (f.series) params.set('series', f.series);
  if (f.genre) params.set('genre', f.genre);
  if (f.status) params.set('status', f.status);
  if (f.tag) params.set('tag', f.tag);
  if (f.formats && f.formats.size > 0) {
    params.set('format', [...f.formats].join(','));
  } else if (f.format) {
    params.set('format', f.format);
  }
  if (f.year_from != null) params.set('year_from', f.year_from);
  if (f.year_to != null) params.set('year_to', f.year_to);
  if (f.has_isbn != null) params.set('has_isbn', f.has_isbn ? '1' : '0');
  if (f.has_cover != null) params.set('has_cover', f.has_cover ? '1' : '0');
  if (f.has_series != null) params.set('has_series', f.has_series ? '1' : '0');
  if (state.order && state.order !== 'author') params.set('order', state.order);
  return params;
}

function setFilter(key, value) { state.filters[key] = value; refresh(); }
function clearFilter(key) {
  state.filters[key] = null;
  if (key === 'year_from' || key === 'year_to') {
    state.filters.year_from = null;
    state.filters.year_to = null;
  }
  refresh();
}
function clearAllFilters() {
  state.filters = {
    q: '', author: null, series: null, genre: null, status: null,
    format: null, formats: null, tag: null, year_from: null, year_to: null,
    has_isbn: null, has_cover: null, has_series: null,
  };
  $('#search').value = '';
  refresh();
}

async function refresh() {
  const grid = $('#library-grid');
  grid.innerHTML = '<p style="color:var(--fg-dim);padding:24px">loading…</p>';
  renderActiveFilters();
  renderFacetActive();
  try {
    if (state.view === 'duplicates') {
      state.groups = await fetch('/api/duplicates').then(r => r.json());
      state.books = state.groups.flatMap(g => g.books);
    } else if (state.view === 'missing') {
      const params = buildQuery();
      params.set('missing', '1');
      state.books = await fetch('/api/books?' + params).then(r => r.json());
      state.groups = [];
    } else if (state.view === 'unverified') {
      state.books = await fetch('/api/unverified').then(r => r.json());
      state.groups = [];
    } else if (state.view === 'series') {

      const params = buildQuery();
      params.set('has_series', '1');
      params.set('order', 'series');
      state.books = await fetch('/api/books?' + params).then(r => r.json());
      state.groups = groupBySeries(state.books);
    } else if (state.view === 'variants') {

      const params = buildQuery();
      state.books = await fetch('/api/books' + (params.toString() ? '?' + params : '')).then(r => r.json());
      state.groups = collapseVariants(state.books).filter(e => e.kind === 'cluster');
    } else if (state.view === 'rename') {

      const preset = state.renamePreset || 'default';
      const resp = await fetch('/api/standardize?preset=' + encodeURIComponent(preset)).then(r => r.json());
      state.standardize = resp;
      state.books = [];
      state.groups = [];
    } else if (state.view === 'stats') {

      state.stats = await fetch('/api/library-stats').then(r => r.json());
      state.books = [];
      state.groups = [];
    } else if (state.view === 'triage') {

      const [missing, unverified] = await Promise.all([
        fetch('/api/missing').then(r => r.json()),
        fetch('/api/unverified').then(r => r.json()),
      ]);
      const seen = new Set();
      const queue = [];
      for (const b of missing) { if (!seen.has(b.id)) { seen.add(b.id); queue.push(b); } }
      for (const b of unverified) { if (!seen.has(b.id)) { seen.add(b.id); queue.push(b); } }
      state.books = queue;
      state.groups = [];

      if (state.triageIdx == null) {
        state.triageIdx = 0;
        restoreTriagePosition();
      }
      if (state.triageIdx >= queue.length) state.triageIdx = Math.max(0, queue.length - 1);
    } else {
      const qs = buildQuery().toString();
      state.books = await fetch('/api/books' + (qs ? '?' + qs : '')).then(r => r.json());
      state.groups = [];
    }

    applyQueryRanking();

    render();
  } catch (err) {
    grid.innerHTML =
      `<p style="color:var(--danger);padding:24px">failed to load: ${err.message}</p>`;
  }
}

async function loadFacets() {
  try {
    const [authors, series, genres, formats, sources, tags] = await Promise.all([
      fetch('/api/authors').then(r => r.json()),
      fetch('/api/series').then(r => r.json()),
      fetch('/api/genres').then(r => r.json()),
      fetch('/api/formats').then(r => r.json()),
      fetch('/api/sources').then(r => r.json()),
      fetch('/api/tags').then(r => r.json()),
    ]);
    renderFacetList('#facet-authors', authors, 'author');
    renderFacetList('#facet-series', series, 'series');
    renderFacetList('#facet-genres', genres, 'genre');
    renderFormatFacet(formats);
    renderSourcesList(sources);
    renderTagFacet(tags);
    checkSevenzipHint(formats);
  } catch (err) {
    console.error('facet load failed', err);
  }
}

const SEVENZIP_HINT_KEY = 'booktool.sevenzipHintDismissed';
async function checkSevenzipHint(formats) {
  try {
    if (localStorage.getItem(SEVENZIP_HINT_KEY) === '1') return;
  } catch {}
  const needs7zz = (formats || []).some(f =>
    ['cbr', 'cb7', 'cbt'].includes((f.format || f.name || '').toLowerCase())
  );
  if (!needs7zz) return;
  try {
    const r = await fetch('/api/sevenzip-status');
    if (!r.ok) return;
    const s = await r.json();
    if (s.available) return;
    showSevenzipHint();
  } catch {}
}

function showSevenzipHint() {
  if (document.querySelector('.install-hint')) return;
  const banner = document.createElement('div');
  banner.className = 'install-hint';
  banner.innerHTML = `
    <button class="install-hint-close" aria-label="Dismiss">×</button>
    Comic archives in your library need <code>sevenzip</code> for covers and metadata.
    Install with <code>brew install sevenzip</code> (macOS) or <code>apt install p7zip-full</code> (Linux), then reload.
  `;
  banner.querySelector('.install-hint-close').addEventListener('click', () => {
    banner.remove();
    try { localStorage.setItem(SEVENZIP_HINT_KEY, '1'); } catch {}
  });
  document.body.appendChild(banner);
}

function renderTagFacet(tags) {
  const ul = $('#facet-tags');
  if (!ul) return;
  ul.innerHTML = '';
  if (!tags || tags.length === 0) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent = 'no tags yet';
    ul.appendChild(li);
    return;
  }
  for (const t of tags) {
    const li = document.createElement('li');
    li.dataset.key = 'tag';
    li.dataset.value = t.name;
    if (state.filters.tag === t.name) li.classList.add('active');
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = t.name;
    const count = document.createElement('span');
    count.className = 'count';
    count.textContent = String(t.count);
    li.append(name, count);
    li.addEventListener('click', () => {
      if (state.filters.tag === t.name) clearFilter('tag');
      else setFilter('tag', t.name);
    });
    ul.appendChild(li);
  }
}

function renderFormatFacet(formats) {
  const ul = $('#facet-formats');
  if (!ul) return;
  ul.innerHTML = '';
  const active = state.filters.formats || new Set();
  for (const f of (formats || [])) {
    const li = document.createElement('li');
    li.className = active.has(f.name) ? 'active' : '';
    li.dataset.value = f.name;
    const label = document.createElement('span');
    label.className = 'name';
    label.textContent = f.name.toUpperCase();
    const count = document.createElement('span');
    count.className = 'count';
    count.textContent = String(f.count);
    li.append(label, count);
    li.addEventListener('click', () => toggleFormatFilter(f.name));
    ul.appendChild(li);
  }
  if ((formats || []).length === 0) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent = 'none';
    ul.appendChild(li);
  }
}

function toggleFormatFilter(name) {

  if (!state.filters.formats) {
    state.filters.formats = new Set(state.filters.format ? [state.filters.format] : []);
  }
  state.filters.format = null;
  const s = state.filters.formats;
  if (s.has(name)) s.delete(name);
  else s.add(name);
  if (s.size === 0) state.filters.formats = null;
  refresh();
}

function renderSourcesList(sources) {
  state.sources = sources || [];
  renderSourcesSidebar(state.sources);
  if (!$('#sources-modal').hidden) renderSourcesModalList(state.sources);
  scheduleSourcePoll();
}

let _sourcePollHandle = null;
let _lastBookCount = -1;

function scheduleSourcePoll() {
  const anyScanning = (state.sources || []).some(s => s.scanning);
  if (!anyScanning) {
    if (_sourcePollHandle) {
      clearTimeout(_sourcePollHandle);
      _sourcePollHandle = null;
    }

    if (_lastBookCount !== -1) {
      _lastBookCount = -1;
      refresh();
    }
    return;
  }
  if (_sourcePollHandle) return;
  _sourcePollHandle = setTimeout(async () => {
    _sourcePollHandle = null;
    try {
      const sources = await fetch('/api/sources').then(r => r.json());
      state.sources = sources;
      renderSourcesSidebar(sources);
      if (!$('#sources-modal').hidden) renderSourcesModalList(sources);

      const total = sources.reduce((a, s) => a + (s.scan_seen || 0), 0);
      if (total !== _lastBookCount) {
        _lastBookCount = total;
        refresh();
      }
    } catch (err) {
      console.warn('source poll:', err);
    }
    scheduleSourcePoll();
  }, 1500);
}

function refreshLibraryFoldMeta(sources) {
  const meta = $('#library-fold-meta');
  if (!meta) return;
  if (!sources || sources.length === 0) { meta.textContent = ''; return; }
  const books = sources.reduce((acc, s) => acc + (s.last_seen || 0), 0);
  const folders = sources.length;
  meta.textContent = `${folders} folder${folders === 1 ? '' : 's'} · ${books} book${books === 1 ? '' : 's'}`;
}

function renderSourcesSidebar(sources) {
  refreshLibraryFoldMeta(sources);
  const el = $('#sources-list');
  if (!el) return;
  el.innerHTML = '';
  if (!sources || sources.length === 0) {
    const hint = document.createElement('span');
    hint.className = 'hint';
    hint.textContent = 'No folders tracked yet.';
    el.appendChild(hint);
    return;
  }
  for (const s of sources) {
    const row = document.createElement('div');
    row.className = 'source-row' + (s.scanning ? ' scanning' : '');
    row.title = s.path;
    row.addEventListener('click', (ev) => {
      if (ev.target.closest('.source-rescan')) return;
      openSourcesModal();
    });

    const dot = document.createElement('span');
    if (s.last_error) dot.className = 'dot dot-error';
    else if (s.scanning) dot.className = 'dot dot-warn';
    else if ((s.last_missing || 0) > 0) dot.className = 'dot dot-warn';
    else dot.className = 'dot dot-ok';
    row.appendChild(dot);

    const name = document.createElement('div');
    name.className = 'source-name';
    const label = s.name && s.name.length ? s.name : basename(s.path);
    const line = document.createElement('div');
    line.className = 'source-name-line';
    line.textContent = label;
    name.appendChild(line);
    const meta = document.createElement('div');
    meta.className = 'source-meta';
    const parts = [];
    if (s.scanning) {
      parts.push(`scanning · ${s.scan_seen || 0} files`);
    } else if (s.last_error) {
      parts.push('unreachable');
    } else {
      parts.push(`${s.last_seen || 0} book${s.last_seen === 1 ? '' : 's'}`);
      if (s.last_scanned_at) parts.push(relTime(s.last_scanned_at));
    }
    meta.textContent = parts.join(' · ');
    name.appendChild(meta);
    row.appendChild(name);

    const btn = document.createElement('button');
    btn.className = 'source-rescan';
    btn.textContent = s.scanning ? '…' : '↻';
    btn.title = 'Rescan this folder';
    btn.disabled = !!s.scanning;
    btn.addEventListener('click', async (ev) => {
      ev.stopPropagation();
      btn.disabled = true;
      btn.textContent = '…';
      try {
        await fetch(`/api/sources/${s.id}/rescan`, { method: 'POST' });
        const fresh = await fetch('/api/sources').then(r => r.json());
        state.sources = fresh;
        renderSourcesSidebar(fresh);
        scheduleSourcePoll();
      } catch (err) {
        toast('Rescan failed: ' + err.message, 'error');
        btn.disabled = false;
        btn.textContent = '↻';
      }
    });
    row.appendChild(btn);

    el.appendChild(row);
  }
}

function basename(p) {
  if (!p) return '(unknown)';
  const trimmed = p.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

function relTime(epochSec) {
  const diff = Math.floor(Date.now() / 1000) - epochSec;
  if (diff < 60) return 'just now';
  if (diff < 3600) return Math.floor(diff / 60) + ' min ago';
  if (diff < 86400) return Math.floor(diff / 3600) + ' h ago';
  return Math.floor(diff / 86400) + ' d ago';
}

function openSourcesModal() {
  const modal = $('#sources-modal');
  modal.hidden = false;
  renderSourcesModalList(state.sources || []);

  setTimeout(() => $('#modal-browse-btn').focus(), 50);
  document.addEventListener('keydown', onSourcesModalKey);
}

async function openJobsModal() {
  const modal = $('#jobs-modal');
  modal.hidden = false;
  await refreshJobsList();
  setTimeout(() => $('#job-name-input').focus(), 50);
  document.addEventListener('keydown', onJobsModalKey);
}
function closeJobsModal() {
  $('#jobs-modal').hidden = true;
  $('#job-add-error').hidden = true;
  document.removeEventListener('keydown', onJobsModalKey);
}
function onJobsModalKey(e) { if (e.key === 'Escape') closeJobsModal(); }

async function refreshJobsList() {
  const jobs = await fetch('/api/jobs').then(r => r.json()).catch(() => []);
  const list = $('#jobs-modal-list');
  const count = $('#jobs-count');
  count.textContent = jobs.length === 0 ? '' : `(${jobs.length})`;
  if (jobs.length === 0) {
    list.innerHTML = '<p class="hint">No jobs yet. Add one above — e.g. <code>nightly-rescan @daily rescan-all</code>.</p>';
    return;
  }
  list.innerHTML = '';
  for (const j of jobs) list.appendChild(jobRowEl(j));
}

function jobRowEl(j) {
  const row = document.createElement('div');
  row.className = 'job-row' + (j.enabled ? '' : ' disabled');

  const left = document.createElement('div');
  const name = document.createElement('div');
  name.className = 'job-name';
  name.textContent = j.name;
  const meta = document.createElement('div');
  meta.className = 'job-meta';
  const next = j.next_run_at ? formatRelative(j.next_run_at) : '—';
  const last = j.last_run_at ? `last ${formatRelative(j.last_run_at)}` : 'never run';
  meta.textContent = `${j.spec} · ${j.job_type} · next ${next} · ${last}`;
  left.append(name, meta);
  row.appendChild(left);

  if (j.last_run_status) {
    const st = document.createElement('span');
    st.className = 'job-status ' + j.last_run_status;
    st.textContent = j.last_run_status;
    if (j.last_run_summary) st.title = j.last_run_summary;
    row.appendChild(st);
  } else {
    row.appendChild(document.createElement('span'));
  }

  const runBtn = document.createElement('button');
  runBtn.className = 'job-action';
  runBtn.textContent = 'Run now';
  runBtn.addEventListener('click', async () => {
    runBtn.disabled = true;
    runBtn.textContent = 'Running…';
    try {
      const r = await fetch(`/api/jobs/${j.id}/run`, { method: 'POST' }).then(r => r.json());
      if (r.ok) toast(`Job "${j.name}" ran: ${r.job.last_run_summary || 'ok'}`);
      else toast(`Run skipped: ${r.reason}`, 'error');
    } catch (err) { toast('Run failed: ' + err.message, 'error'); }
    refreshJobsList();
  });

  const toggleBtn = document.createElement('button');
  toggleBtn.className = 'job-action';
  toggleBtn.textContent = j.enabled ? 'Disable' : 'Enable';
  toggleBtn.addEventListener('click', async () => {
    await fetch(`/api/jobs/${j.id}`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ enabled: !j.enabled }),
    });
    refreshJobsList();
  });

  const delBtn = document.createElement('button');
  delBtn.className = 'job-action danger';
  delBtn.textContent = 'Delete';
  delBtn.addEventListener('click', async () => {
    if (!confirm(`Delete scheduled job "${j.name}"?`)) return;
    await fetch(`/api/jobs/${j.id}`, { method: 'DELETE' });
    refreshJobsList();
  });

  row.append(runBtn, toggleBtn, delBtn);
  return row;
}

function formatRelative(ts) {
  const d = ts - Math.floor(Date.now() / 1000);
  if (d < -60) return Math.floor(-d / 60) + 'm ago';
  if (d < 0) return 'just now';
  if (d < 60) return `in ${d}s`;
  if (d < 3600) return `in ${Math.floor(d / 60)}m`;
  if (d < 86400) return `in ${Math.floor(d / 3600)}h`;
  return `in ${Math.floor(d / 86400)}d`;
}

$('#open-jobs-btn')?.addEventListener('click', openJobsModal);
$('#jobs-modal .modal-close')?.addEventListener('click', closeJobsModal);
$('#jobs-modal')?.addEventListener('click', (e) => {
  if (e.target.id === 'jobs-modal') closeJobsModal();
});
$('#job-add-btn')?.addEventListener('click', async () => {
  const name = $('#job-name-input').value.trim();
  const job_type = $('#job-type-select').value;
  const spec = $('#job-spec-select').value;
  const err = $('#job-add-error');
  err.hidden = true;
  if (!name) { err.textContent = 'Name is required.'; err.hidden = false; return; }
  try {
    const r = await fetch('/api/jobs', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name, spec, job_type }),
    });
    if (!r.ok) {
      const e = await r.json().catch(() => ({}));
      err.textContent = e.detail ? `${e.error || 'error'}: ${e.detail}` : (e.error || `HTTP ${r.status}`);
      err.hidden = false;
      return;
    }
    $('#job-name-input').value = '';
    refreshJobsList();
  } catch (e) {
    err.textContent = 'Network error: ' + e.message;
    err.hidden = false;
  }
});

function closeSourcesModal() {
  $('#sources-modal').hidden = true;
  $('#modal-add-error').hidden = true;
  $('#modal-path-input').value = '';
  $('#modal-name-input').value = '';
  document.removeEventListener('keydown', onSourcesModalKey);
}

function onSourcesModalKey(e) {
  if (e.key === 'Escape') closeSourcesModal();
}

function renderSourcesModalList(sources) {
  const host = $('#sources-modal-list');
  host.innerHTML = '';
  $('#sources-count').textContent = sources.length > 0
    ? `(${sources.length})`
    : '';

  if (sources.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'hint';
    empty.textContent = 'No folders yet. Use "Browse…" above to pick one.';
    host.appendChild(empty);
    return;
  }

  for (const s of sources) {
    host.appendChild(sourceCard(s));
  }
}

function sourceCard(s) {
  const card = document.createElement('div');
  card.className = 'source-card';
  if (s.last_error) card.classList.add('is-unreachable');
  if (s.scanning) card.classList.add('is-scanning');

  const dot = document.createElement('span');
  dot.className = 'source-dot ' + (
    s.scanning ? 'dot-scan' :
    s.last_error ? 'dot-error' :
    s.last_missing > 0 ? 'dot-warn' :
    s.last_scanned_at ? 'dot-ok' : 'dot-idle'
  );
  dot.title = s.scanning
    ? (s.scan_total > 0
        ? `Scanning… ${s.scan_seen}/${s.scan_total}`
        : 'Scanning…')
    : s.last_error
        ? `Unreachable: ${s.last_error}`
        : s.last_missing > 0 ? `${s.last_missing} files missing on disk`
        : s.last_scanned_at ? 'Synced'
        : 'Not yet scanned';
  card.appendChild(dot);

  const body = document.createElement('div');
  body.className = 'source-body';

  const title = document.createElement('div');
  title.className = 'source-title';
  title.textContent = s.name || s.path.split('/').filter(Boolean).pop() || s.path;
  body.appendChild(title);

  const sub = document.createElement('div');
  sub.className = 'source-path';
  sub.textContent = s.path;
  sub.title = s.path;
  body.appendChild(sub);

  const stats = document.createElement('div');
  stats.className = 'source-stats';
  if (s.scanning) {

    const pct = s.scan_total > 0
      ? Math.min(100, Math.round((s.scan_seen / s.scan_total) * 100))
      : 0;
    const counter = s.scan_total > 0
      ? `Scanning… ${s.scan_seen} / ${s.scan_total} (${pct}%)`
      : `Scanning…`;
    stats.innerHTML = `<span class="source-scanning-label">${counter}</span>`;
    const bar = document.createElement('div');
    bar.className = 'source-progress';
    const fill = document.createElement('div');
    fill.className = 'source-progress-fill';
    fill.style.width = pct + '%';
    if (s.scan_total === 0) bar.classList.add('indeterminate');
    bar.appendChild(fill);
    body.appendChild(stats);
    body.appendChild(bar);
  } else if (s.last_error) {
    stats.innerHTML = `<span class="source-error">⚠ ${escapeHtml(s.last_error)}</span> · last tried ${s.last_scanned_at ? relTime(s.last_scanned_at) : 'never'}`;
    body.appendChild(stats);
  } else {
    const ago = s.last_scanned_at ? relTime(s.last_scanned_at) : 'never';
    let line = `${s.last_seen} book${s.last_seen === 1 ? '' : 's'} · scanned ${ago}`;
    if (s.last_missing > 0) line += ` · <span class="source-missing">${s.last_missing} missing</span>`;
    stats.innerHTML = line;
    body.appendChild(stats);
  }

  card.appendChild(body);

  const actions = document.createElement('div');
  actions.className = 'source-card-actions';
  const rescan = document.createElement('button');
  rescan.className = 'icon-btn';
  if (s.scanning) {
    rescan.textContent = 'Scanning…';
    rescan.disabled = true;
  } else {
    rescan.textContent = 'Rescan';
    rescan.onclick = () => doRescanSource(s.id, rescan);
  }
  actions.appendChild(rescan);

  const more = document.createElement('div');
  more.className = 'actions-overflow';
  const trigger = document.createElement('button');
  trigger.className = 'overflow-trigger';
  trigger.textContent = '⋮';
  trigger.title = 'More actions';
  trigger.onclick = (e) => {
    e.stopPropagation();
    document.querySelectorAll('.actions-overflow.open').forEach(o => o !== more && o.classList.remove('open'));
    more.classList.toggle('open');
  };
  more.appendChild(trigger);
  const menu = document.createElement('div');
  menu.className = 'overflow-menu';
  const reveal = document.createElement('button');
  reveal.textContent = 'Open path in clipboard';
  reveal.title = 'Copies the folder path to your clipboard';
  reveal.onclick = async () => {
    try { await navigator.clipboard.writeText(s.path); toast('path copied'); }
    catch { toast('copy failed', 'error'); }
    more.classList.remove('open');
  };
  menu.appendChild(reveal);
  const rm = document.createElement('button');
  rm.className = 'danger';
  rm.textContent = 'Remove';
  rm.onclick = () => { more.classList.remove('open'); doRemoveSource(s.id, s); };
  menu.appendChild(rm);
  more.appendChild(menu);
  actions.appendChild(more);

  card.appendChild(actions);
  return card;
}

async function doRescanSource(id, btn) {
  const orig = btn.textContent;
  btn.disabled = true; btn.textContent = 'Starting…';
  try {
    const r = await fetch(`/api/sources/${id}/rescan`, { method: 'POST' });
    if (!r.ok) {

      throw new Error(`status ${r.status}`);
    }
    const j = await r.json();
    if (j.scheduled === false && j.error) {
      toast('rescan failed: ' + j.error, 'error');
    } else if (j.scheduled === false) {

      toast(`Rescanned · ${j.added} new, ${j.missing} missing`);
    }

  } catch (err) {
    toast('rescan failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = orig;
    await loadFacets();
  }
}

async function doRemoveSource(id, s) {
  const label = s.name || s.path;
  if (!confirm(`Stop tracking "${label}"?\nBooks already in the catalog stay there.`)) return;
  try {
    await fetch(`/api/sources/${id}`, { method: 'DELETE' });
    toast('source removed');
  } catch (err) {
    toast('remove failed: ' + err.message, 'error');
  }
  await loadFacets();
}

async function pickFolderNative() {
  try {
    const r = await fetch('/api/pick-folder', { method: 'POST' }).then(r => r.json());
    if (r.ok) return r.path;

    if (r.reason && r.reason !== 'cancelled' && r.reason !== 'unsupported') {
      toast('picker: ' + r.reason, 'error');
    }
    return null;
  } catch (err) {
    toast('picker unavailable — paste a path below', 'error');
    return null;
  }
}

async function addSourceFlow(path, name) {
  const errEl = $('#modal-add-error');
  errEl.hidden = true;
  if (!path) {
    errEl.textContent = 'Pick a folder or paste a path first.';
    errEl.hidden = false;
    return;
  }
  const btn = $('#modal-add-btn');
  btn.disabled = true; btn.textContent = 'Adding…';
  try {
    const r = await fetch('/api/sources', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ path, name: name || null }),
    }).then(r => r.json());

    if (r.scheduled) {

      toast('Scan started in background');
      $('#modal-path-input').value = '';
      $('#modal-name-input').value = '';
    } else if (r.scanned === false || r.error) {

      errEl.textContent = `Added but scan failed: ${r.error || 'unknown'}. You can remove it below.`;
      errEl.hidden = false;
    } else if (r.scanned === true) {

      toast(`Added · ${r.added} new, ${r.seen} total`);
      $('#modal-path-input').value = '';
      $('#modal-name-input').value = '';
    }
    await loadFacets();
    refresh();
  } catch (err) {
    errEl.textContent = 'add failed: ' + err.message;
    errEl.hidden = false;
  } finally {
    btn.disabled = false; btn.textContent = 'Add';
  }
}

$('#add-books-btn')?.addEventListener('click', openSourcesModal);
$('#open-sources-btn')?.addEventListener('click', openSourcesModal);
$('#sources-modal .modal-close')?.addEventListener('click', closeSourcesModal);
$('#sources-modal')?.addEventListener('click', (e) => {
  if (e.target.id === 'sources-modal') closeSourcesModal();
});
$('#modal-browse-btn')?.addEventListener('click', async () => {
  const path = await pickFolderNative();
  if (path) $('#modal-path-input').value = path;
});
$('#modal-add-btn')?.addEventListener('click', () => {
  addSourceFlow($('#modal-path-input').value.trim(), $('#modal-name-input').value.trim());
});
$('#modal-path-input')?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    addSourceFlow($('#modal-path-input').value.trim(), $('#modal-name-input').value.trim());
  }
});
$('#modal-rescan-all')?.addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  btn.disabled = true; btn.textContent = 'Scanning…';
  try {
    const sources = state.sources || [];
    let added = 0, missing = 0, unreachable = 0;
    for (const s of sources) {
      try {
        const r = await fetch(`/api/sources/${s.id}/rescan`, { method: 'POST' }).then(r => r.json());
        added += r.added || 0;
        missing += r.missing || 0;
      } catch { unreachable += 1; }
    }
    const tail = unreachable > 0 ? `, ${unreachable} unreachable` : '';
    toast(`Rescanned all · ${added} new, ${missing} missing${tail}`);
  } finally {
    btn.disabled = false; btn.textContent = 'Rescan all';
    await loadFacets();
    refresh();
  }
});

document.addEventListener('click', (e) => {
  if (!e.target.closest('.actions-overflow')) {
    document.querySelectorAll('.actions-overflow.open').forEach(o => o.classList.remove('open'));
  }
});

$('#rescan-all-btn')?.addEventListener('click', async (ev) => {
  const btn = ev.currentTarget;
  btn.disabled = true;
  const prev = btn.textContent;
  btn.textContent = 'Scanning…';
  try {
    const sources = state.sources || [];
    let added = 0, missing = 0, unreachable = 0;
    for (const s of sources) {
      try {
        const r = await fetch(`/api/sources/${s.id}/rescan`, { method: 'POST' }).then(r => r.json());
        added += r.added || 0;
        missing += r.missing || 0;
      } catch { unreachable += 1; }
    }
    const tail = unreachable > 0 ? `, ${unreachable} unreachable` : '';
    toast(`Rescanned all · ${added} new, ${missing} missing${tail}`);
  } finally {
    btn.disabled = false;
    btn.textContent = prev;
    await loadFacets();
    refresh();
  }
});

function openTransferModal(initialTab) {
  const modal = $('#transfer-modal');
  if (!modal) return;
  modal.hidden = false;
  switchTransferTab(initialTab || 'export');
}
function closeTransferModal() {
  const modal = $('#transfer-modal');
  if (modal) modal.hidden = true;
  resetTransferImport();
}
function switchTransferTab(tab) {
  $$('#transfer-modal .modal-tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  $('#transfer-export').hidden = tab !== 'export';
  $('#transfer-import').hidden = tab !== 'import';
}
function resetTransferImport() {
  const f = $('#transfer-file-input');
  if (f) f.value = '';
  const name = $('#transfer-file-name');
  if (name) name.textContent = '';
  const status = $('#transfer-import-status');
  if (status) status.textContent = '';
  const go = $('#transfer-import-go');
  if (go) go.disabled = true;
}

$('#import-btn')?.addEventListener('click', () => openTransferModal('import'));
$('#export-btn')?.addEventListener('click', () => openTransferModal('export'));
$('#transfer-modal .modal-close')?.addEventListener('click', closeTransferModal);
$('#transfer-modal')?.addEventListener('click', (e) => {
  if (e.target.id === 'transfer-modal') closeTransferModal();
});
$$('#transfer-modal .modal-tab').forEach(btn => {
  btn.addEventListener('click', () => switchTransferTab(btn.dataset.tab));
});

function triggerDownload(url) {

  const a = document.createElement('a');
  a.href = url;
  a.rel = 'noopener';
  document.body.appendChild(a);
  a.click();
  a.remove();
}
$('#transfer-export-json')?.addEventListener('click', () => {
  triggerDownload('/api/export');
  $('#transfer-export-status').textContent = 'Download started — check your browser\'s downloads.';
});
$('#transfer-export-csv')?.addEventListener('click', () => {
  triggerDownload('/api/export?format=csv');
  $('#transfer-export-status').textContent = 'Download started — check your browser\'s downloads.';
});

let _transferImportText = null;
$('#transfer-file-input')?.addEventListener('change', async (e) => {
  const file = e.target.files?.[0];
  if (!file) return;
  $('#transfer-file-name').textContent = `${file.name} · ${(file.size / 1024).toFixed(1)} KB`;
  _transferImportText = await file.text();
  $('#transfer-import-go').disabled = false;
  $('#transfer-import-status').textContent = '';
});

const drop = $('.transfer-drop');
if (drop) {
  ['dragenter', 'dragover'].forEach(ev => drop.addEventListener(ev, (e) => {
    e.preventDefault(); drop.classList.add('dragover');
  }));
  ['dragleave', 'drop'].forEach(ev => drop.addEventListener(ev, (e) => {
    e.preventDefault(); drop.classList.remove('dragover');
  }));
  drop.addEventListener('drop', async (e) => {
    const file = e.dataTransfer?.files?.[0];
    if (!file) return;
    $('#transfer-file-name').textContent = `${file.name} · ${(file.size / 1024).toFixed(1)} KB`;
    _transferImportText = await file.text();
    $('#transfer-import-go').disabled = false;
    $('#transfer-import-status').textContent = '';
  });
}

$('#transfer-import-go')?.addEventListener('click', async () => {
  if (!_transferImportText) return;
  const status = $('#transfer-import-status');
  const go = $('#transfer-import-go');
  go.disabled = true;
  status.textContent = 'Parsing…';
  let payload;
  try {
    payload = JSON.parse(_transferImportText);
  } catch (err) {
    status.textContent = 'That doesn\'t look like JSON. CSV import isn\'t supported yet — convert to JSON first.';
    go.disabled = false;
    return;
  }
  if (!Array.isArray(payload)) {
    status.textContent = 'Expected a JSON array at the top level.';
    go.disabled = false;
    return;
  }
  status.textContent = `Importing ${payload.length} row${payload.length === 1 ? '' : 's'}…`;
  try {
    const r = await fetch('/api/import', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const result = await r.json();
    status.textContent = `Matched ${result.matched} · Updated ${result.updated} · Skipped ${result.skipped}` +
      (result.error_count > 0 ? ` · ${result.error_count} error${result.error_count === 1 ? '' : 's'}` : '');
    if (result.updated > 0) {
      refresh();
      loadFacets();
    }
  } catch (err) {
    status.textContent = 'Import failed: ' + err.message;
  } finally {
    go.disabled = false;
  }
});

const enrichState = {
  pollTimer: null,
  lastSnapshot: null,
  recentLog: [],
  lastSeenId: 0,
};

async function fetchEnrichStatus() {
  try {
    const r = await fetch('/api/enrich/batch');
    if (!r.ok) return null;
    return await r.json();
  } catch { return null; }
}

function renderEnrichSidebarSummary(snap) {
  const el = $('#enrich-batch-summary');
  if (!el) return;
  if (!snap || !snap.buckets) { el.textContent = ''; return; }
  const b = snap.buckets;
  if (snap.state === 'running') {
    const pct = snap.total ? Math.round((snap.processed / snap.total) * 100) : 0;
    el.textContent = `Running… ${snap.processed} / ${snap.total} (${pct}%)`;
  } else if (b.eligible === 0) {
    el.textContent = `All ${b.total} books enriched (${b.ok} ok, ${b.no_match} no match).`;
  } else {
    el.textContent = `${b.eligible} of ${b.total} not yet enriched.`;
  }
}

function renderTopPills(snap) {
  const brand = $('.brand');
  const stats = $('#stats');
  if (!stats) return;
  if (!snap || !snap.buckets) { stats.innerHTML = ''; return; }
  const b = snap.buckets;

  if (brand) {
    if (b.total > 0) brand.dataset.meta = b.total.toLocaleString() + ' books';
    else delete brand.dataset.meta;
  }

  stats.innerHTML = '';

  const addPill = document.createElement('button');
  addPill.className = 'top-pill muted';
  addPill.title = 'Add books from a folder (Browse… or paste a path)';
  addPill.innerHTML = `<svg width="12" height="12" viewBox="0 0 16 16" fill="none" aria-hidden="true">
    <path d="M2 4a1 1 0 0 1 1-1h3l1 1.5h6a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z"
          stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/>
    <path d="M8 7v4M6 9h4" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
  </svg>Add books`;
  addPill.addEventListener('click', () => $('#add-books-btn')?.click() || $('#open-sources-btn')?.click());
  stats.appendChild(addPill);

  if (snap.state === 'running' && snap.total > 0) {
    const pill = document.createElement('button');
    pill.className = 'top-pill run';
    pill.title = 'Open enrichment progress';
    pill.innerHTML = `<span class="top-pill-dot"></span>Enriching · ${snap.processed} of ${snap.total}`;
    pill.addEventListener('click', () => openEnrichModal());
    stats.appendChild(pill);
  }
  if (b.eligible > 0) {
    const pill = document.createElement('button');
    pill.className = 'top-pill warn';
    pill.title = `${b.eligible} books not yet matched against Open Library — jump to Triage`;
    pill.innerHTML = `<span class="top-pill-dot"></span>${b.eligible.toLocaleString()} need triage`;
    pill.addEventListener('click', () => {

      const tab = $('.tab[data-view="triage"]') || $('.tab[data-view="unverified"]');
      if (tab) tab.click();
    });
    stats.appendChild(pill);
  }
}

function renderEnrichModalBody(snap) {
  const body = $('#enrich-modal-body');
  if (!body || !snap) return;
  const b = snap.buckets || { total: 0, eligible: 0, ok: 0, no_match: 0, errored: 0 };
  const running = snap.state === 'running';
  const finished = snap.state === 'finished';
  const canceled = snap.state === 'canceled';
  const pct = snap.total > 0 ? Math.min(100, (snap.processed / snap.total) * 100) : 0;
  const seconds = snap.started_at && (snap.finished_at || running)
    ? Math.max(1, (snap.finished_at || Math.floor(Date.now() / 1000)) - snap.started_at)
    : 0;
  const rate = (running || finished) && seconds > 0 ? (snap.processed / seconds) : 0;
  const etaSec = running && rate > 0 ? Math.ceil((snap.total - snap.processed) / rate) : 0;

  body.innerHTML = '';

  const overview = document.createElement('div');
  overview.className = 'enrich-overview';
  overview.innerHTML = `
    <div class="enrich-stat"><b>${b.total}</b><span>books</span></div>
    <div class="enrich-stat ok"><b>${b.ok}</b><span>enriched</span></div>
    <div class="enrich-stat nomatch"><b>${b.no_match}</b><span>no match</span></div>
    <div class="enrich-stat err"><b>${b.errored}</b><span>errored</span></div>
    <div class="enrich-stat todo"><b>${b.eligible}</b><span>remaining</span></div>
  `;
  body.appendChild(overview);

  if (running) {

    const bar = document.createElement('div');
    bar.className = 'enrich-progress';
    bar.innerHTML = `<div class="enrich-progress-fill" style="width: ${pct}%"></div>`;
    body.appendChild(bar);
    const meta = document.createElement('div');
    meta.className = 'enrich-progress-meta';
    const remainingStr = etaSec > 0 ? ` · ~${formatDuration(etaSec)} left` : '';
    meta.textContent = `${snap.processed} / ${snap.total} done` +
                       (rate > 0 ? ` · ${rate.toFixed(1)} books/s` : '') +
                       remainingStr;
    body.appendChild(meta);

    const current = document.createElement('div');
    current.className = 'enrich-current';
    current.innerHTML = `<span class="enrich-current-label">Now:</span>` +
                        `<span class="enrich-current-title">${escapeHtml(snap.current_title || '…')}</span>`;
    body.appendChild(current);

    if (enrichState.recentLog.length > 0) {
      const log = document.createElement('div');
      log.className = 'enrich-log';
      log.innerHTML = '<h4>Recently processed</h4>';
      const list = document.createElement('ol');
      for (const entry of enrichState.recentLog) {
        const li = document.createElement('li');
        li.className = 'enrich-log-' + entry.outcome;
        li.innerHTML = `<span class="badge">${entry.outcome}</span>` +
                       `<span class="title">${escapeHtml(entry.title)}</span>`;
        list.appendChild(li);
      }
      log.appendChild(list);
      body.appendChild(log);
    }

    const actions = document.createElement('div');
    actions.className = 'enrich-actions';
    const cancel = document.createElement('button');
    cancel.className = 'danger';
    cancel.textContent = 'Cancel job';
    cancel.onclick = cancelEnrichBatch;
    actions.appendChild(cancel);
    body.appendChild(actions);
  } else {

    const blurb = document.createElement('p');
    blurb.className = 'enrich-blurb';
    if (finished) {
      blurb.textContent = `Last run finished. Processed ${snap.processed} books — ${snap.ok} enriched, ${snap.no_match} not found on Open Library, ${snap.errored} errored.`;
    } else if (canceled) {
      blurb.textContent = `Last run was canceled after ${snap.processed} of ${snap.total} books.`;
    } else if (b.eligible === 0) {
      blurb.textContent = `Every book has been checked at least once. To retry "no match" entries, use per-book Fetch info on the detail panel.`;
    } else {
      blurb.textContent = `Fetches metadata from Open Library for ${b.eligible} book${b.eligible === 1 ? '' : 's'} that haven't been tried yet. ` +
                         `Books already enriched or marked "no match" are skipped on re-run.`;
    }
    body.appendChild(blurb);

    const actions = document.createElement('div');
    actions.className = 'enrich-actions';
    const start = document.createElement('button');
    start.className = 'primary';
    start.disabled = b.eligible === 0;
    start.textContent = b.eligible === 0 ? 'Nothing to enrich' :
                        (finished || canceled) ? 'Run again' : 'Start enrichment';
    start.onclick = startEnrichBatch;
    actions.appendChild(start);
    body.appendChild(actions);
  }
}

function formatDuration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${h}h ${m}m`;
}

function appendToRecentLog(snap, prevSnap) {

  if (!prevSnap) return;
  if (snap.current_id === prevSnap.current_id) return;
  if (!prevSnap.current_title) return;

  let outcome = 'ok';
  if (snap.errored > prevSnap.errored) outcome = 'error';
  else if (snap.no_match > prevSnap.no_match) outcome = 'no_match';
  else if (snap.ok > prevSnap.ok) outcome = 'ok';
  else return;
  enrichState.recentLog.unshift({ title: prevSnap.current_title, outcome });
  if (enrichState.recentLog.length > 12) enrichState.recentLog.length = 12;
}

async function pollEnrichStatus() {
  const snap = await fetchEnrichStatus();
  if (!snap) return;
  appendToRecentLog(snap, enrichState.lastSnapshot);
  enrichState.lastSnapshot = snap;
  renderEnrichSidebarSummary(snap);
  renderTopPills(snap);
  if (!$('#enrich-modal').hidden) renderEnrichModalBody(snap);

  clearTimeout(enrichState.pollTimer);
  if (snap.state === 'running') {
    enrichState.pollTimer = setTimeout(pollEnrichStatus, 800);
  } else {
    enrichState.pollTimer = null;

    if (snap.state === 'finished' || snap.state === 'canceled') {

      refresh();
    }
  }
}

async function startEnrichBatch() {
  enrichState.recentLog = [];
  enrichState.lastSnapshot = null;
  const r = await fetch('/api/enrich/batch', { method: 'POST' });
  if (!r.ok && r.status !== 409) {
    toast('Failed to start enrichment', 'error');
    return;
  }
  const snap = await r.json();
  enrichState.lastSnapshot = snap;
  renderEnrichModalBody(snap);
  renderEnrichSidebarSummary(snap);
  renderTopPills(snap);
  clearTimeout(enrichState.pollTimer);
  enrichState.pollTimer = setTimeout(pollEnrichStatus, 800);
}

async function cancelEnrichBatch() {
  await fetch('/api/enrich/batch', { method: 'DELETE' });
  pollEnrichStatus();
}

function openEnrichModal() {
  $('#enrich-modal').hidden = false;
  pollEnrichStatus();
}

function closeEnrichModal() {
  $('#enrich-modal').hidden = true;

}

$('#new-tag-input')?.addEventListener('keydown', async (e) => {
  if (e.key !== 'Enter') return;
  const name = e.target.value.trim();
  if (!name) return;
  e.target.value = '';
  const r = await fetch('/api/tags', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  if (!r.ok) { toast('failed to create tag', 'error'); return; }
  await loadFacets();
});

$('#enrich-batch-btn')?.addEventListener('click', openEnrichModal);
$('#enrich-modal .modal-close')?.addEventListener('click', closeEnrichModal);
$('#enrich-modal')?.addEventListener('click', (e) => {
  if (e.target.id === 'enrich-modal') closeEnrichModal();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('#enrich-modal').hidden) closeEnrichModal();
  if (e.key === 'Escape' && !$('#transfer-modal').hidden) closeTransferModal();
});

pollEnrichStatus();

function renderFacetList(selector, items, key) {
  const ul = $(selector);
  ul.innerHTML = '';
  if (items.length === 0) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent = '(none)';
    ul.appendChild(li);
    return;
  }
  for (const f of items) {
    const li = document.createElement('li');
    li.dataset.key = key;
    li.dataset.value = f.name;
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = f.name;
    const count = document.createElement('span');
    count.className = 'count';
    count.textContent = f.count;
    li.append(name, count);
    li.addEventListener('click', () => {
      const cur = state.filters[key];
      if (cur === f.name) clearFilter(key);
      else setFilter(key, f.name);
    });
    ul.appendChild(li);
  }
}

$$('.facet-group[data-key="status"] li').forEach(li => {
  li.addEventListener('click', () => {
    const v = li.dataset.value;
    if (state.filters.status === v) clearFilter('status');
    else setFilter('status', v);
  });
});
$$('.facet-group[data-key="has"] li').forEach(li => {
  li.addEventListener('click', () => {
    const key = 'has_' + li.dataset.value;
    if (state.filters[key] === true) clearFilter(key);
    else setFilter(key, true);
  });
});

$('#derive-paths-btn')?.addEventListener('click', async () => {
  const btn = $('#derive-paths-btn');
  btn.disabled = true;
  const original = btn.textContent;
  btn.textContent = 'Backfilling…';
  try {
    const r = await fetch('/api/derive-paths', { method: 'POST' }).then(r => r.json());
    toast(`Scanned ${r.scanned}, updated ${r.updated}`);
    await loadFacets();
    refresh();
  } catch (err) {
    toast('backfill failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = original;
  }
});

function renderFacetActive() {
  $$('.facet-group li').forEach(li => li.classList.remove('active'));
  const select = (key, value) => {
    if (value == null) return;
    document.querySelectorAll(`.facet-group[data-key="${key}"] li`).forEach(li => {
      if (li.dataset.value === String(value)) li.classList.add('active');
    });
  };
  select('status', state.filters.status);
  if (state.filters.has_isbn === true)
    document.querySelector('.facet-group[data-key="has"] li[data-value="isbn"]')?.classList.add('active');
  if (state.filters.has_cover === true)
    document.querySelector('.facet-group[data-key="has"] li[data-value="cover"]')?.classList.add('active');
  if (state.filters.has_series === true)
    document.querySelector('.facet-group[data-key="has"] li[data-value="series"]')?.classList.add('active');
  for (const key of ['author', 'series', 'genre']) select(key, state.filters[key]);

  const formatLis = document.querySelectorAll('.facet-group[data-key="format"] li');
  const formatActive = state.filters.formats
    ? state.filters.formats
    : (state.filters.format ? new Set([state.filters.format]) : new Set());
  formatLis.forEach(li => {
    if (formatActive.has(li.dataset.value)) li.classList.add('active');
  });
}

function renderActiveFilters() {
  const bar = $('#active-filters');
  bar.innerHTML = '';
  const f = state.filters;
  const chips = [];
  if (f.q) chips.push({ label: `text: ${f.q}`, clear: () => { f.q = ''; $('#search').value = ''; refresh(); } });
  if (f.author) chips.push({ label: `author: ${f.author}`, clear: () => clearFilter('author') });
  if (f.series) chips.push({ label: `series: ${f.series}`, clear: () => clearFilter('series') });
  if (f.genre) chips.push({ label: `genre: ${f.genre}`, clear: () => clearFilter('genre') });
  if (f.status) chips.push({ label: `status: ${f.status}`, clear: () => clearFilter('status') });
  if (f.tag) chips.push({ label: `tag: ${f.tag}`, clear: () => clearFilter('tag') });
  if (f.formats && f.formats.size > 0) {
    const list = [...f.formats].join(', ');
    chips.push({ label: `format: ${list}`, clear: () => { f.formats = null; refresh(); } });
  } else if (f.format) {
    chips.push({ label: `format: ${f.format}`, clear: () => clearFilter('format') });
  }
  if (f.year_from != null || f.year_to != null) {
    chips.push({
      label: `year: ${f.year_from ?? '…'}–${f.year_to ?? '…'}`,
      clear: () => clearFilter('year_from'),
    });
  }
  if (f.has_isbn != null) chips.push({ label: `${f.has_isbn ? 'has' : 'missing'}: isbn`, clear: () => clearFilter('has_isbn') });
  if (f.has_cover != null) chips.push({ label: `${f.has_cover ? 'has' : 'missing'}: cover`, clear: () => clearFilter('has_cover') });
  if (f.has_series != null) chips.push({ label: `${f.has_series ? 'has' : 'missing'}: series`, clear: () => clearFilter('has_series') });

  if (chips.length === 0) { bar.hidden = true; return; }
  bar.hidden = false;
  for (const c of chips) {
    const chip = document.createElement('button');
    chip.className = 'filter-chip';
    chip.textContent = c.label + ' ×';
    chip.title = 'Click to remove';
    chip.addEventListener('click', c.clear);
    bar.appendChild(chip);
  }
  const all = document.createElement('button');
  all.className = 'clear-all-btn';
  all.textContent = 'clear all';
  all.addEventListener('click', clearAllFilters);
  bar.appendChild(all);
}

function render() {
  const grid = $('#library-grid');

  _decodeQueue.length = 0;
  grid.innerHTML = '';

  const legacy = $('#library-empty');
  if (legacy) legacy.hidden = true;

  const isSpecialView = state.view === 'triage' || state.view === 'rename' ||
                        state.view === 'duplicates' || state.view === 'variants' ||
                        state.view === 'stats';
  const wantCompact = state.layout === 'compact' && !isSpecialView;
  const schema = isSpecialView
    ? 'special'
    : (wantCompact ? 'none' : groupSchemaFor(state.view, state.order));
  grid.dataset.groupSchema = schema;

  if (state.books.length === 0 && state.view !== 'duplicates' && state.view !== 'rename' && state.view !== 'stats') {
    grid.appendChild(emptyStateEl(state.view));
    return;
  }

  if (state.view === 'rename') {
    renderStandardizeLens(grid);
    return;
  }
  if (state.view === 'triage') {
    renderTriageLens(grid);
    return;
  }
  if (state.view === 'stats') {
    renderStatsView(grid);
    return;
  }
  if (state.view === 'duplicates') {
    if (state.groups.length === 0) {
      grid.appendChild(emptyStateEl('duplicates'));
      return;
    }
    for (const g of state.groups) grid.appendChild(dupGroupEl(g));
    return;
  }
  if (state.view === 'series') {
    if (state.groups.length === 0) {
      grid.appendChild(emptyStateEl('series'));
      return;
    }
    for (const g of state.groups) {
      grid.appendChild(sectionEl(g.name, 'series', g.books.length, g.books, 1));
    }
    return;
  }
  if (state.view === 'variants') {
    if (state.groups.length === 0) {
      grid.appendChild(emptyStateEl('variants'));
      return;
    }

    for (const cluster of state.groups) {
      const title = (cluster.primary.title || '(untitled)')
        + ' — ' + (cluster.primary.author_sort || 'unknown');
      grid.appendChild(sectionEl(
        title, 'cluster', cluster.members.length, cluster.members, 1,
        { collapse: false },
      ));
    }
    return;
  }

  if (schema === 'none') {
    renderBookEntries(grid, state.books);
    return;
  }
  const tree = groupBooks(state.books, schema);
  for (const top of tree) {
    if (!top.children) {
      grid.appendChild(sectionEl(top.name, top.kind, top.books.length, top.books, 1));
      continue;
    }

    if (top.children.length === 1 && top.children[0].kind === 'standalone') {
      grid.appendChild(sectionEl(
        top.name, top.kind, top.children[0].books.length,
        top.children[0].books, 1,
      ));
      continue;
    }

    const outer = document.createElement('section');
    outer.className = 'lib-section depth-1 kind-' + top.kind;
    outer.appendChild(sectionHeader(top.name, top.kind, top.count, 1));
    for (const sub of top.children) {
      outer.appendChild(sectionEl(sub.name, sub.kind, sub.books.length, sub.books, 2));
    }
    grid.appendChild(outer);
  }
}

function groupSchemaFor(view, order) {

  if (view === 'series') return 'series';
  switch (order) {
    case 'author': return 'author-series';
    case 'series': return 'series';
    case 'year_asc':
    case 'year_desc': return 'decade';
    default: return 'none';
  }
}

function groupBooks(books, schema) {
  if (schema === 'series') {
    return chunk(books, b => b.series, b => b.series, 'series')
      .filter(g => g.name);
  }
  if (schema === 'decade') {
    return chunk(books,
      b => b.year != null,
      b => decadeOf(b.year),
      'decade',
    ).map(g => ({ ...g, name: g.name || 'No year' }));
  }
  if (schema === 'author-series') {

    const outers = chunk(books, b => true, b => b.author_sort || '(unknown)', 'author');
    return outers.map(o => {
      const withSeries = [];
      const standalone = [];
      for (const b of o.books) (b.series ? withSeries : standalone).push(b);
      const subs = chunk(withSeries, b => b.series, b => b.series, 'series')
        .map(s => ({ ...s, kind: 'series' }));
      if (standalone.length > 0) {
        subs.push({ name: 'Standalone', kind: 'standalone',
                    count: standalone.length, books: standalone });
      }
      return { name: o.name, kind: 'author', count: o.books.length, children: subs };
    });
  }
  return [];
}

function chunk(books, predicate, keyOf, kind) {
  const out = [];
  let cur = null;
  for (const b of books) {
    const ok = predicate(b);
    const key = ok ? keyOf(b) : null;
    if (cur && cur._key === key) {
      cur.books.push(b);
      cur.count = cur.books.length;
    } else {
      cur = { _key: key, name: key, kind, count: 1, books: [b] };
      out.push(cur);
    }
  }
  return out;
}

function decadeOf(year) {
  if (year == null) return null;
  const d = Math.floor(year / 10) * 10;
  return d + 's';
}

function sectionEl(name, kind, count, books, depth, opts) {
  const sec = document.createElement('section');
  sec.className = `lib-section depth-${depth} kind-${kind}`;
  sec.appendChild(sectionHeader(name, kind, count, depth));
  const members = document.createElement('div');
  members.className = 'members';
  renderBookEntries(members, books, opts);
  sec.appendChild(members);
  return sec;
}

function cleanAuthorLabel(raw) {
  if (!raw) return raw;
  let s = String(raw);
  s = s.split(';')[0];
  s = s.split(/\s+\band\b\s+/i)[0];
  s = s.replace(/\s*\([^)]*\)/g, '');
  s = s.replace(/,\s*\d{4}-\d{0,4}\s*$/, '');
  const parts = s.split(',').map(p => p.trim()).filter(Boolean);
  if (parts.length >= 2) s = parts[0] + ', ' + parts[1];
  else if (parts.length === 1) s = parts[0];
  return s.trim() || raw;
}

function sectionHeader(name, kind, count, depth) {
  const h = document.createElement('div');
  h.className = `lib-section-header depth-${depth}`;
  const label = document.createElement('span');
  label.className = 'lib-section-name';
  const display = kind === 'author' ? cleanAuthorLabel(name) : name;
  label.textContent = display;
  const meta = document.createElement('span');
  meta.className = 'lib-section-count';
  meta.textContent = String(count);
  h.append(label, meta);
  if (kind === 'author' || kind === 'series') {
    h.title = display !== name ? `${name} — click to filter` : `Filter to "${name}"`;
    h.addEventListener('click', () => setFilter(kind, name));
  }
  return h;
}

function groupBySeries(books) {
  return groupBooks(books, 'series');
}

function trustLevel(b) {
  const conf = typeof b.confidence === 'number' ? b.confidence : 0;
  if (b.source === 'manual') return 'high';
  if (b.source && b.source !== 'embedded' && b.source !== 'derived') {
    return conf >= 0.7 ? 'high' : 'med';
  }
  if (b.isbn && conf >= 0.6) return 'med';
  return 'low';
}

function qualityFlag(b, trust) {
  if (b.missing_at) {
    return {
      kind: 'missing',
      text: 'missing file',
      title: 'File no longer exists on disk (last seen ' + relTime(b.missing_at) + ')',
    };
  }
  const hasTitle  = b.title && b.title.length > 0;
  const hasAuthor = b.author_sort && b.author_sort.length > 0;
  if (!hasTitle || !hasAuthor) {
    return {
      kind: 'missing',
      text: 'missing meta',
      title: 'No ' + (!hasTitle && !hasAuthor ? 'title or author' : !hasTitle ? 'title' : 'author') + ' embedded — Fetch info to identify',
    };
  }
  if (trust === 'low' || trust === 'med') {
    return {
      kind: 'unverified',
      text: 'unverified',
      title: trust === 'low'
        ? 'Embedded metadata only — not yet verified against Open Library'
        : 'Has ISBN but not yet provider-verified',
    };
  }
  if (b.read_status === 'reading') return { kind: 'reading', text: 'reading' };
  if (b.read_status === 'finished') return { kind: 'finished', text: 'finished' };
  return null;
}

function renderSizePill(b) {
  if (b.size == null || b.size === 0) return null;
  const mb = b.size / (1024 * 1024);
  let tier = 'normal';
  if (mb >= 50) tier = 'huge';
  else if (mb >= 10) tier = 'heavy';
  const text = mb < 1
    ? Math.round(mb * 1024) + ' KB'
    : mb < 100 ? mb.toFixed(1) + ' MB' : Math.round(mb) + ' MB';
  const isUnread = !b.read_status || b.read_status === 'unread';
  const weighty = tier !== 'normal' && isUnread;
  const el = document.createElement('span');
  el.className = 'size-pill tier-' + tier + (weighty ? ' is-weighty' : '');
  el.textContent = text;
  return el;
}

function syncCardForStatus(card, b) {
    card.className = card.className.replace(/\bstatus-(unread|reading|finished)\b/g, '').trim();
    card.classList.add('status-' + (b.read_status || 'unread'));

    const oldPill = card.querySelector(':scope > .cover-frame > .cover-status');
    if (oldPill) oldPill.remove();
    const trust = trustLevel(b);
    const flag = qualityFlag(b, trust);
    if (flag) {
        const pill = document.createElement('div');
        pill.className = 'cover-status status-' + flag.kind;
        pill.textContent = flag.text;
        if (flag.title) pill.title = flag.title;
        const frame = card.querySelector('.cover-frame');

        const checkbox = frame.querySelector('.cover-checkbox');
        if (checkbox) checkbox.insertAdjacentElement('afterend', pill);
        else frame.prepend(pill);
    }

    const tog = card.querySelector('.card-status-toggle');
    if (tog) {
        for (const btn of tog.querySelectorAll('button')) {
            btn.classList.toggle('active', btn.dataset.status === (b.read_status || 'unread'));
        }
    }
}

function buildCardStatusToggle(book) {
    const wrap = document.createElement('div');
    wrap.className = 'card-status-toggle';
    const cur = book.read_status || 'unread';
    const choices = [
        ['unread',   'U', 'Mark as unread'],
        ['reading',  'R', 'Mark as reading'],
        ['finished', 'F', 'Mark as finished'],
    ];
    for (const [status, label, title] of choices) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'card-status-btn' + (status === cur ? ' active' : '');
        btn.dataset.status = status;
        btn.textContent = label;
        btn.title = title;
        btn.setAttribute('aria-label', title);
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            if (btn.classList.contains('active')) return;
            await setStatusFromCard(book, status, wrap);
        });
        wrap.appendChild(btn);
    }
    return wrap;
}

async function setStatusFromCard(book, status, toggleEl) {

    const card = toggleEl.closest('.book-card');
    book.read_status = status;
    if (card) syncCardForStatus(card, book);
    try {
        const r = await fetch(`/api/books/${book.id}/status`, {
            method: 'PATCH',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ status }),
        });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const fresh = await r.json();

        Object.assign(book, fresh);

        for (const dup of document.querySelectorAll(`.book-card[data-id="${book.id}"]`)) {
            syncCardForStatus(dup, book);
        }

        if (state.currentBook && state.currentBook.id === book.id) {
            state.currentBook = Object.assign({}, state.currentBook, fresh);
            renderDetail(state.currentBook);
        }
    } catch (err) {
        toast('Status change failed: ' + err.message, 'error');
    }
}

function bookCard(b) {
  const card = document.createElement('div');
  card.className = 'book-card status-' + (b.read_status || 'unread');
  const trust = trustLevel(b);
  card.classList.add('trust-' + trust);
  if (b.id === state.selectedId) card.classList.add('active');
  if (state.selection.has(b.id)) card.classList.add('selected');
  card.dataset.id = b.id;

  if (b.author_sort) card.dataset.author = b.author_sort;
  if (b.series) card.dataset.series = b.series;

  const frame = document.createElement('div');
  frame.className = 'cover-frame';

  const img = document.createElement('img');
  img.className = 'thumb';
  img.alt = b.title || '';
  img.onerror = () => {
    img.remove();
    const ph = document.createElement('span');
    ph.className = 'placeholder';
    ph.textContent = 'no cover';
    frame.appendChild(ph);
  };
  frame.appendChild(img);
  lazyAttachCover(img, `/api/books/${b.id}/cover?t=${b.updated_at || ''}`);

  const checkbox = document.createElement('div');
  checkbox.className = 'cover-checkbox';
  checkbox.innerHTML = state.selection.has(b.id) ? '✓' : '';
  checkbox.title = 'Select for bulk actions';
  checkbox.addEventListener('click', (e) => { e.stopPropagation(); toggleSelect(b.id); });
  frame.appendChild(checkbox);

  const flag = qualityFlag(b, trust);
  if (flag) {
    const pill = document.createElement('div');
    pill.className = 'cover-status status-' + flag.kind;
    pill.textContent = flag.text;
    if (flag.title) pill.title = flag.title;
    frame.appendChild(pill);
    if (flag.kind === 'missing') card.classList.add('is-missing');
  }

  const fmt = document.createElement('div');
  fmt.className = 'cover-format fmt-' + (b.format || 'unknown');
  fmt.textContent = b.format;
  frame.appendChild(fmt);

  if (trust !== 'high') {
    const dot = document.createElement('div');
    dot.className = 'cover-trust trust-' + trust;
    dot.title = trust === 'low'
      ? 'Unverified — embedded metadata only; consider Fetch info'
      : 'Partial — has an ISBN but not provider-verified';
    frame.appendChild(dot);
  }

  frame.appendChild(buildCardStatusToggle(b));

  if (typeof b.read_percent === 'number' && b.read_percent > 0) {
    const pct = Math.max(1, Math.min(100, Math.round(b.read_percent * 100)));
    const bar = document.createElement('div');
    bar.className = 'cover-progress';
    bar.style.setProperty('--p', pct + '%');
    bar.title = `${pct}% read`;
    frame.appendChild(bar);
  }

  const meta = document.createElement('div');
  meta.className = 'meta';
  const title = document.createElement('div');
  title.className = 'title';
  title.textContent = b.title || b.path.split('/').pop();
  const sub = document.createElement('div');
  sub.className = 'sub';
  const parts = [];
  if (b.author_sort) parts.push(b.author_sort);
  if (b.series) parts.push(b.series + (b.series_index ? ' #' + b.series_index : ''));
  const author = document.createElement('span');
  author.className = 'sub-author';
  author.textContent = parts.join(' · ') || '(unknown author)';
  sub.appendChild(author);

  const sizePill = renderSizePill(b);
  if (sizePill) sub.appendChild(sizePill);
  meta.append(title, sub);

  card.append(frame, meta);
  card.dataset.click = 'single';
  return card;
}

function onLibraryClick(e) {
  const card = e.target.closest?.('.book-card');
  if (!card) return;

  if (e.target.closest('.cover-checkbox')) return;
  const kind = card.dataset.click;
  if (kind === 'cluster') {
    const ids = (card.dataset.cluster || '').split(',').map(Number);
    selectClusterByIds(ids);
  } else {
    const id = Number(card.dataset.id);
    if (id) selectBook(id);
  }
}

function badge(text, kind) {
  const el = document.createElement('span');
  el.className = 'badge' + (kind ? ' ' + kind : '');
  el.textContent = text;
  return el;
}

function collapseVariants(books) {

  const groups = new Map();
  const order = [];
  for (const b of books) {
    const key = variantKey(b);
    if (!groups.has(key)) {
      groups.set(key, []);
      order.push(key);
    }
    groups.get(key).push(b);
  }
  const out = [];
  for (const k of order) {
    const members = groups.get(k);
    if (members.length === 1) {
      out.push({ kind: 'single', book: members[0] });
    } else {
      out.push({ kind: 'cluster', primary: pickPrimary(members), members });
    }
  }
  return out;
}

function variantKey(b) {

  if (!b.title || !b.author_sort) return 'p:' + b.id;
  return b.author_sort.toLowerCase() + '\x1f' + b.title.toLowerCase();
}

const FORMAT_PREFERENCE = { epub: 0, mobi: 1, azw3: 2, pdf: 3 };

function pickPrimary(members) {
  let best = members[0];
  for (const b of members) {
    const ba = FORMAT_PREFERENCE[b.format] ?? 9;
    const bb = FORMAT_PREFERENCE[best.format] ?? 9;
    if (ba < bb) { best = b; continue; }
    if (ba > bb) continue;
    if ((b.size || 0) > (best.size || 0)) best = b;
  }
  return best;
}

function renderBookEntries(parent, books, opts) {
  const collapse = opts?.collapse !== false;
  if (!collapse) {
    for (const b of books) parent.appendChild(bookCard(b));
    return;
  }
  for (const entry of collapseVariants(books)) {
    if (entry.kind === 'single') parent.appendChild(bookCard(entry.book));
    else parent.appendChild(variantCard(entry));
  }
}

function variantCard(entry) {
  const b = entry.primary;
  const card = bookCard(b);
  card.classList.add('variant-cluster');
  card.dataset.cluster = entry.members.map(m => m.id).join(',');

  const frame = card.querySelector('.cover-frame');
  const count = document.createElement('div');
  count.className = 'cover-count';
  count.textContent = '×' + entry.members.length;
  count.title = entry.members.length + ' copies — click to compare';
  frame.appendChild(count);

  const oldFmt = frame.querySelector('.cover-format');
  if (oldFmt) oldFmt.remove();
  const stack = document.createElement('div');
  stack.className = 'cover-format-stack';
  const fmts = [...new Set(entry.members.map(m => (m.format || '').toLowerCase()))];
  for (const f of fmts) {
    const chip = document.createElement('span');
    chip.className = 'cover-format fmt-' + f;
    chip.textContent = f;
    stack.appendChild(chip);
  }
  frame.appendChild(stack);

  card.dataset.click = 'cluster';
  return card;
}

function emptyStateEl(view) {
  const filtersActive = anyFilterActive();
  const wrap = document.createElement('div');
  wrap.className = 'library-empty';
  const h = document.createElement('h2');
  const p = document.createElement('p');
  const actions = document.createElement('div');
  actions.className = 'library-empty-actions';

  if (filtersActive) {
    h.textContent = 'No books match your filters';
    p.textContent = 'Try removing one to widen the search.';
    const btn = document.createElement('button');
    btn.textContent = 'Clear all filters';
    btn.onclick = clearAllFilters;
    actions.appendChild(btn);
  } else if (view === 'series') {
    h.textContent = 'No series yet';
    p.textContent =
      'Run "Backfill from filenames" in the Series facet to extract series and ' +
      'number from existing filenames like "Author - Series 01 - Title.mobi".';
  } else if (view === 'unverified') {
    h.textContent = 'Everything checks out';
    p.textContent = 'No books are flagged as unverified. Hit "Fetch info" on a book to enrich its metadata.';
  } else if (view === 'missing') {
    h.textContent = 'No books missing metadata';
    p.textContent = 'Every book has a title, author, year, and ISBN.';
  } else if (view === 'duplicates') {
    h.textContent = 'No duplicates';
    p.textContent = 'No two books share an identical SHA-256 hash.';
  } else if (view === 'variants') {
    h.textContent = 'No variants';
    p.textContent = 'No book in your library has another copy (same author + title in another format or with different bytes).';
  } else {
    h.textContent = 'Your catalog is empty';
    p.innerHTML = 'Run <code>booktool scan DIR</code> in a terminal to ingest a directory of ebooks, then refresh.';
  }
  wrap.append(h, p);
  if (actions.children.length > 0) wrap.appendChild(actions);
  return wrap;
}

function anyFilterActive() {
  const f = state.filters;
  return !!(f.q || f.author || f.series || f.genre || f.status || f.format ||
            f.year_from != null || f.year_to != null ||
            f.has_isbn != null || f.has_cover != null || f.has_series != null);
}

function renderStandardizeLens(grid) {
  const data = state.standardize;
  if (!data) {
    grid.innerHTML = '<p style="padding:24px;color:var(--ink-mute)">loading…</p>';
    return;
  }
  const counts = data.counts || { total: 0, would_change: 0, same: 0, unrenameable: 0 };

  const toolbar = document.createElement('div');
  toolbar.className = 'standardize-toolbar';
  toolbar.innerHTML = `
    <div class="standardize-presets">
      ${['default', 'flat', 'series-dir'].map(p => `
        <button class="standardize-preset ${state.renamePreset === p || (!state.renamePreset && p === 'default') ? 'is-on' : ''}"
                data-preset="${p}">${p}</button>
      `).join('')}
    </div>
    <div class="standardize-counts">
      <span><b>${counts.would_change}</b> to rename</span>
      <span><b>${counts.same}</b> already canonical</span>
      <span><b>${counts.unrenameable}</b> missing metadata</span>
    </div>
    <button class="tbtn primary" id="standardize-apply-all"
            ${counts.would_change === 0 ? 'disabled' : ''}>Apply all (${counts.would_change})</button>
  `;
  for (const b of toolbar.querySelectorAll('.standardize-preset')) {
    b.addEventListener('click', () => {
      state.renamePreset = b.dataset.preset;
      refresh();
    });
  }
  toolbar.querySelector('#standardize-apply-all').addEventListener('click', async () => {
    const ids = (data.plans || []).filter(p => p.dst && !p.same).map(p => p.id);
    if (ids.length === 0) return;
    if (!confirm(`Rename ${ids.length} files? This moves them on disk.`)) return;
    await applyStandardize(ids);
  });
  grid.appendChild(toolbar);

  if (data.template) {
    const tpl = document.createElement('div');
    tpl.className = 'standardize-template';
    tpl.innerHTML = '<span>template:</span> <code>' + escapeHtml(data.template) + '</code>';
    grid.appendChild(tpl);
  }

  if (counts.total === 0) {
    grid.appendChild(emptyStateEl('all'));
    return;
  }

  const rename_rows = [], unrenamable_rows = [], same_rows = [];
  for (const p of (data.plans || [])) {
    if (p.dst == null) unrenamable_rows.push(p);
    else if (p.same) same_rows.push(p);
    else rename_rows.push(p);
  }
  const list = document.createElement('div');
  list.className = 'standardize-list';
  for (const p of rename_rows) list.appendChild(renameRowEl(p));
  if (unrenamable_rows.length > 0) {
    const h = document.createElement('div');
    h.className = 'standardize-section';
    h.textContent = `${unrenamable_rows.length} unrenameable — missing metadata`;
    list.appendChild(h);
    for (const p of unrenamable_rows) list.appendChild(renameRowEl(p));
  }
  if (same_rows.length > 0) {
    const h = document.createElement('div');
    h.className = 'standardize-section';
    h.textContent = `${same_rows.length} already canonical`;
    list.appendChild(h);
    for (const p of same_rows) list.appendChild(renameRowEl(p));
  }
  grid.appendChild(list);
}

function renameRowEl(plan) {
  const row = document.createElement('div');
  row.className = 'rename-row';
  if (plan.dst == null) row.classList.add('unrenameable');
  else if (plan.same) row.classList.add('same');
  row.dataset.id = plan.id;

  const pathBlock = document.createElement('div');
  pathBlock.className = 'rename-paths';

  if (plan.dst == null) {

    const old = document.createElement('div');
    old.className = 'rename-path rename-path-old';
    old.title = plan.src;
    old.textContent = plan.src;
    const reason = document.createElement('div');
    reason.className = 'rename-path rename-path-reason';
    reason.textContent = plan.unrenameable_reason || '—';
    pathBlock.append(old, reason);
  } else {
    const [prefix, oldName, newName] = splitRenamePath(plan.src, plan.dst);
    if (prefix.length > 0) {
      const dir = document.createElement('div');
      dir.className = 'rename-path-dir';
      dir.title = prefix;
      dir.textContent = prefix;
      pathBlock.appendChild(dir);
    }
    pathBlock.appendChild(renderBasenameDiff(oldName, newName, plan.same));
  }

  const action = document.createElement('div');
  action.className = 'rename-action';
  if (plan.dst && !plan.same) {
    const btn = document.createElement('button');
    btn.className = 'tbtn';
    btn.textContent = 'Apply';
    btn.addEventListener('click', () => applyStandardize([plan.id]));
    action.appendChild(btn);
  } else if (plan.same) {
    action.innerHTML = '<span class="rename-action-ok">✓ already canonical</span>';
  }
  row.append(pathBlock, action);
  return row;
}

function splitRenamePath(src, dst) {
  const srcSlash = src.lastIndexOf('/');
  const dstSlash = dst.lastIndexOf('/');
  const srcDir = srcSlash >= 0 ? src.slice(0, srcSlash + 1) : '';
  const dstDir = dstSlash >= 0 ? dst.slice(0, dstSlash + 1) : '';
  const srcBase = srcSlash >= 0 ? src.slice(srcSlash + 1) : src;
  const dstBase = dstSlash >= 0 ? dst.slice(dstSlash + 1) : dst;
  if (srcDir === dstDir) return [srcDir, srcBase, dstBase];

  let i = 0;
  while (i < src.length && i < dst.length && src[i] === dst[i]) i++;

  let cut = src.lastIndexOf('/', i);
  if (cut < 0) cut = -1;
  return [src.slice(0, cut + 1), src.slice(cut + 1), dst.slice(cut + 1)];
}

function renderBasenameDiff(oldName, newName, same) {
  const wrap = document.createElement('div');
  wrap.className = 'rename-basenames' + (same ? ' rename-same' : '');

  let prefix = 0;
  while (prefix < oldName.length && prefix < newName.length && oldName[prefix] === newName[prefix]) {
    prefix++;
  }

  let suffix = 0;
  while (
    suffix < oldName.length - prefix &&
    suffix < newName.length - prefix &&
    oldName[oldName.length - 1 - suffix] === newName[newName.length - 1 - suffix]
  ) {
    suffix++;
  }

  const oldLine = document.createElement('div');
  oldLine.className = 'rename-basename old';
  oldLine.title = oldName;
  oldLine.append(
    span('rename-common', oldName.slice(0, prefix)),
    span('rename-diff rename-diff-old', oldName.slice(prefix, oldName.length - suffix)),
    span('rename-common', oldName.slice(oldName.length - suffix)),
  );

  const newLine = document.createElement('div');
  newLine.className = 'rename-basename new';
  newLine.title = newName;
  newLine.append(
    span('rename-common', newName.slice(0, prefix)),
    span('rename-diff rename-diff-new', newName.slice(prefix, newName.length - suffix)),
    span('rename-common', newName.slice(newName.length - suffix)),
  );

  wrap.append(oldLine, newLine);
  return wrap;
}

function span(cls, text) {
  const s = document.createElement('span');
  s.className = cls;
  s.textContent = text;
  return s;
}

async function applyStandardize(ids) {
  const preset = state.renamePreset || 'default';
  const r = await fetch('/api/standardize/apply', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ids, preset }),
  });
  if (!r.ok) { toast('Standardize failed (' + r.status + ')', 'error'); return; }
  const resp = await r.json();
  const s = resp.summary || { ok: 0, errors: 0 };
  toast('Renamed ' + s.ok + (s.errors > 0 ? ', ' + s.errors + ' errors' : ''));

  refresh();
}

function renderStatsView(grid) {
    const s = state.stats;
    if (!s) {
        grid.innerHTML = '<p class="hint" style="padding:24px">loading…</p>';
        return;
    }
    const root = document.createElement('div');
    root.className = 'stats-page';
    root.appendChild(statsStatusCardEl(s.status));
    root.appendChild(statsMonthBarsEl(s.finished_by_month));
    root.appendChild(statsBookStripEl('Currently reading', s.currently_reading));
    root.appendChild(statsBookStripEl('Recently finished', s.recently_finished));
    root.appendChild(statsFormatsEl(s.formats));
    root.appendChild(statsTopAuthorsEl(s.top_authors));
    grid.appendChild(root);
}

function statsStatusCardEl(status) {
    const card = document.createElement('section');
    card.className = 'stats-card stats-status';
    const total = (status.unread || 0) + (status.reading || 0) + (status.finished || 0);
    const pct = total === 0 ? 0 : Math.round((status.finished / total) * 100);
    card.innerHTML = `
      <h3>Reading status</h3>
      <div class="stats-status-row">
        <div class="stats-stat stats-stat-unread">
          <b>${status.unread}</b><span>Unread</span>
        </div>
        <div class="stats-stat stats-stat-reading">
          <b>${status.reading}</b><span>Reading</span>
        </div>
        <div class="stats-stat stats-stat-finished">
          <b>${status.finished}</b><span>Finished</span>
        </div>
      </div>
      <p class="stats-status-sub">${pct}% of catalog finished${total ? ' (' + total + ' books)' : ''}</p>
    `;
    return card;
}

function statsMonthBarsEl(months) {
    const card = document.createElement('section');
    card.className = 'stats-card stats-months';
    card.innerHTML = '<h3>Books finished — last 12 months</h3>';
    if (!months || months.length === 0) {
        card.insertAdjacentHTML('beforeend', '<p class="hint">No finished books yet.</p>');
        return card;
    }
    const max = months.reduce((m, x) => Math.max(m, x.count), 0);
    const chart = document.createElement('div');
    chart.className = 'stats-month-chart';
    for (const m of months) {
        const col = document.createElement('div');
        col.className = 'stats-month-col';
        const h = max === 0 ? 0 : Math.round((m.count / max) * 100);
        col.innerHTML = `
          <div class="stats-month-bar-wrap">
            <div class="stats-month-bar" style="height:${h}%"
                 title="${m.count} book${m.count === 1 ? '' : 's'} finished in ${m.ym}"></div>
          </div>
          <div class="stats-month-label">${m.ym.slice(5)}</div>
          <div class="stats-month-count">${m.count || ''}</div>
        `;
        chart.appendChild(col);
    }
    card.appendChild(chart);
    return card;
}

function statsBookStripEl(heading, books) {
    const card = document.createElement('section');
    card.className = 'stats-card stats-strip';
    const h = document.createElement('h3');
    h.textContent = heading;
    if (books && books.length) {
        const meta = document.createElement('span');
        meta.className = 'stats-strip-meta';
        meta.textContent = books.length + (books.length === 10 ? '+' : '');
        h.appendChild(meta);
    }
    card.appendChild(h);
    if (!books || books.length === 0) {
        card.insertAdjacentHTML('beforeend',
            heading.includes('reading')
                ? '<p class="hint">Nothing in flight. Mark a book as Reading from any card to see it here.</p>'
                : '<p class="hint">No finished books yet.</p>');
        return card;
    }
    const wrap = document.createElement('div');
    wrap.className = 'stats-strip-cards';
    for (const b of books) wrap.appendChild(bookCard(b));
    card.appendChild(wrap);
    return card;
}

function statsFormatsEl(formats) {
    const card = document.createElement('section');
    card.className = 'stats-card stats-formats';
    card.innerHTML = '<h3>Format breakdown</h3>';
    if (!formats || formats.length === 0) {
        card.insertAdjacentHTML('beforeend', '<p class="hint">No books in the catalog yet.</p>');
        return card;
    }
    const max = formats.reduce((m, x) => Math.max(m, x.count), 0);
    const list = document.createElement('div');
    list.className = 'stats-bar-rows';
    for (const f of formats) {
        const pct = max === 0 ? 0 : Math.round((f.count / max) * 100);
        const row = document.createElement('div');
        row.className = 'stats-bar-row';
        row.innerHTML = `
          <span class="stats-bar-label cover-format fmt-${f.format}">${f.format}</span>
          <span class="stats-bar-track"><span class="stats-bar-fill" style="width:${pct}%"></span></span>
          <span class="stats-bar-count">${f.count}</span>
        `;
        list.appendChild(row);
    }
    card.appendChild(list);
    return card;
}

function statsTopAuthorsEl(authors) {
    const card = document.createElement('section');
    card.className = 'stats-card stats-authors';
    card.innerHTML = '<h3>Top authors</h3>';
    if (!authors || authors.length === 0) {
        card.insertAdjacentHTML('beforeend', '<p class="hint">No author data yet.</p>');
        return card;
    }
    const max = authors.reduce((m, x) => Math.max(m, x.count), 0);
    const list = document.createElement('div');
    list.className = 'stats-bar-rows';
    for (const a of authors) {
        const pct = max === 0 ? 0 : Math.round((a.count / max) * 100);
        const row = document.createElement('div');
        row.className = 'stats-bar-row stats-author-row';
        row.innerHTML = `
          <button class="stats-bar-label" data-author="${escapeAttr(a.name)}">${escapeHtml(a.name)}</button>
          <span class="stats-bar-track"><span class="stats-bar-fill" style="width:${pct}%"></span></span>
          <span class="stats-bar-count">${a.count}</span>
        `;

        row.querySelector('.stats-bar-label').addEventListener('click', () => {
            setFilter('author', a.name);
            switchView('all');
        });
        list.appendChild(row);
    }
    card.appendChild(list);
    return card;
}

function escapeAttr(s) { return escapeHtml(String(s)); }

function renderTriageLens(grid) {
  const queue = state.books || [];
  if (queue.length === 0) {
    grid.appendChild(emptyStateEl('unverified'));
    return;
  }
  const idx = Math.max(0, Math.min(state.triageIdx || 0, queue.length - 1));
  state.triageIdx = idx;
  const book = queue[idx];

  const head = document.createElement('div');
  head.className = 'triage-head';
  head.innerHTML = `
    <div class="triage-pos"><b>${idx + 1}</b> / ${queue.length}</div>
    <div class="triage-progress"><i style="width:${((idx + 1) / queue.length) * 100}%"></i></div>
    <div class="triage-help">
      <span class="kbd">J</span> next
      <span class="kbd">K</span> prev
      <span class="kbd">↵</span> apply
      <span class="kbd">S</span> skip
    </div>`;
  grid.appendChild(head);

  const body = document.createElement('div');
  body.className = 'triage-body';
  const coverWrap = document.createElement('div');
  coverWrap.className = 'triage-cover';
  const cover = document.createElement('img');
  cover.alt = book.title || '';
  attachCover(cover, `/api/books/${book.id}/cover?t=${book.updated_at || ''}`);
  coverWrap.appendChild(cover);
  body.appendChild(coverWrap);

  const right = document.createElement('div');
  right.className = 'triage-right';
  const title = document.createElement('h2');
  title.className = 'triage-title';
  title.textContent = book.title || book.path.split('/').pop();
  const meta = document.createElement('div');
  meta.className = 'triage-meta';
  const parts = [];
  if (book.author_sort) parts.push(book.author_sort);
  if (book.year) parts.push(book.year);
  if (book.format) parts.push(book.format.toUpperCase());
  meta.textContent = parts.join(' · ') || '(no metadata yet)';
  const pathLine = document.createElement('div');
  pathLine.className = 'triage-path';
  pathLine.textContent = book.path;
  right.append(title, meta, pathLine);

  const diffSlot = document.createElement('div');
  diffSlot.className = 'triage-diff';
  diffSlot.innerHTML = '<div class="triage-diff-placeholder">Fetching from Open Library…</div>';
  right.appendChild(diffSlot);
  body.appendChild(right);
  grid.appendChild(body);

  const foot = document.createElement('div');
  foot.className = 'triage-foot';
  foot.innerHTML = `
    <button class="btn" data-action="skip">Skip <span class="kbd">S</span></button>
    <button class="btn" data-action="prev">← prev <span class="kbd">K</span></button>
    <span class="triage-spacer"></span>
    <button class="btn primary" data-action="apply">Apply <span class="kbd">↵</span></button>
    <button class="btn" data-action="next">next → <span class="kbd">J</span></button>`;
  for (const btn of foot.querySelectorAll('button')) {
    btn.addEventListener('click', () => triageAction(btn.dataset.action));
  }
  grid.appendChild(foot);

  fetchTriageDiff(book, diffSlot);
}

const prefetchedIds = new Set();
function prefetchTriage(bookId) {
  if (prefetchedIds.has(bookId)) return;
  prefetchedIds.add(bookId);

  fetch(`/api/books/${bookId}/enrich`, { method: 'POST' }).catch(() => {});
}

const triageEnrichInFlight = new Set();
const triageEnrichDone = new Map();

async function fetchTriageDiff(book, slot) {

  if (triageEnrichDone.has(book.id)) {
    const cached = triageEnrichDone.get(book.id);
    if (cached.noMatch) {
      slot.innerHTML = '<div class="triage-diff-placeholder">No match on Open Library — '
        + (cached.tried ? cached.tried + ' variants tried' : 'try editing the title') + '.</div>';
      return;
    }
    book._enrich = { current: cached.current, suggested: cached.suggested };
    book._candidates = cached.candidates || [];
    book._candidateIdx = 0;
    slot.innerHTML = '';
    slot.appendChild(buildDiffElement(book, () => { slot.innerHTML = ''; }));
    return;
  }

  if (triageEnrichInFlight.has(book.id)) return;
  triageEnrichInFlight.add(book.id);
  try {
    const r = await fetch(`/api/books/${book.id}/enrich`, { method: 'POST' }).then(r => r.json());
    if (!r.enriched) {
      triageEnrichDone.set(book.id, { noMatch: true, tried: (r.tried || []).length });
      slot.innerHTML = '<div class="triage-diff-placeholder">No match on Open Library — '
        + (r.tried ? r.tried.length + ' variants tried' : 'try editing the title') + '.</div>';
      return;
    }
    const current = r.current || {};
    const suggested = r.suggested || {};
    book._enrich = { current, suggested };
    book._candidates = r.candidates || [];
    book._candidateIdx = 0;
    triageEnrichDone.set(book.id, { current, suggested, candidates: r.candidates || [] });
    slot.innerHTML = '';

    const diff = buildDiffElement(book, () => { slot.innerHTML = ''; });
    slot.appendChild(diff);
  } catch (err) {
    slot.innerHTML = '<div class="triage-diff-placeholder">Enrich failed: ' + escapeHtml(err.message) + '</div>';
  } finally {
    triageEnrichInFlight.delete(book.id);
  }
}

function buildDiffElement(book, onDismiss) {
  const { current, suggested } = book._enrich;
  const candidates = book._candidates || [];
  const picks = {};
  for (const f of DIFF_FIELDS) {
    picks[f.key] = defaultPickFor(current[f.key], suggested[f.key]);
  }
  const diff = document.createElement('div');
  diff.className = 'diff';

  if (candidates.length >= 2) {
    const picker = buildCandidatePicker(book, diff, picks);
    diff.appendChild(picker);
  }

  const head = document.createElement('div');
  head.className = 'diff-head';
  head.innerHTML = `<span></span>
    <span class="src">Embedded <em>(current)</em></span>
    <span class="src">From <em>Open Library</em></span>`;
  diff.appendChild(head);
  for (const f of DIFF_FIELDS) {
    const emb = current[f.key];
    const sug = suggested[f.key];
    if ((emb == null || emb === '') && (sug == null || sug === '')) continue;
    const row = document.createElement('div');
    row.className = 'diff-row';
    row.dataset.field = f.key;
    const same = formatDiffValue(emb) === formatDiffValue(sug) && emb != null && emb !== '';
    row.innerHTML = `<div class="diff-key">${f.label}</div>`;
    const embCell = makeDiffCell(emb, 'embedded', picks[f.key] === 'embedded', same);
    const sugCell = makeDiffCell(sug, 'suggested', picks[f.key] === 'suggested', same);
    embCell.addEventListener('click', () => pickDiffSide(f.key, 'embedded', row, picks, diff));
    sugCell.addEventListener('click', () => { if (!same) pickDiffSide(f.key, 'suggested', row, picks, diff); });
    row.append(embCell, sugCell);
    diff.appendChild(row);
  }
  const apply = document.createElement('div');
  apply.className = 'diff-apply';
  apply.innerHTML = `<div class="diff-apply-info"></div>
    <div class="diff-apply-actions">
      <button type="button" class="ghost">Cancel</button>
      <button type="button" class="ghost" data-action="refresh" title="Skip cache and re-query Open Library">↻ Refresh</button>
      <button type="button" class="primary">Apply merge</button>
    </div>`;
  diff.appendChild(apply);
  updateDiffApplyInfo(diff, current, suggested, picks);
  const buttons = apply.querySelectorAll('button');
  const cancelBtn = buttons[0];
  const refreshBtn = buttons[1];
  const applyBtn = buttons[2];
  cancelBtn.addEventListener('click', () => { if (onDismiss) onDismiss(); else diff.remove(); });
  refreshBtn.addEventListener('click', () => refreshEnrich(book, refreshBtn));
  applyBtn.addEventListener('click', () => applyDiffMerge(book, current, suggested, picks, applyBtn, diff));

  book._diffPicks = picks;
  return diff;
}

function buildCandidatePicker(book, diff, picks) {
  const candidates = book._candidates || [];
  const wrap = document.createElement('div');
  wrap.className = 'candidate-picker';
  const head = document.createElement('div');
  head.className = 'candidate-picker-head';
  head.textContent = 'Wrong match? Try one of these:';
  wrap.appendChild(head);
  const strip = document.createElement('div');
  strip.className = 'candidate-strip';
  candidates.forEach((c, i) => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'candidate-card' + (book._candidateIdx === i ? ' is-on' : '');
    card.title = (c.title || '') + (c.year ? ' (' + c.year + ')' : '') + (c.author ? ' · ' + c.author : '');
    const cover = document.createElement('div');
    cover.className = 'candidate-cover';
    if (c.cover_url) {
      const img = document.createElement('img');
      img.src = c.cover_url + (c.cover_url.includes('?') ? '&' : '?') + 'default=false';
      img.alt = c.title || '';
      img.onerror = () => img.remove();
      cover.appendChild(img);
    }
    const meta = document.createElement('div');
    meta.className = 'candidate-meta';
    meta.innerHTML = `<div class="candidate-title">${escapeHtml(c.title || '(untitled)')}</div>` +
                     `<div class="candidate-sub">${escapeHtml(c.author || '')}${c.year ? ' · ' + c.year : ''}</div>`;
    card.append(cover, meta);
    card.addEventListener('click', () => pickCandidate(book, i));
    strip.appendChild(card);
  });
  wrap.appendChild(strip);
  return wrap;
}

function pickCandidate(book, idx) {
  const candidates = book._candidates || [];
  if (idx < 0 || idx >= candidates.length) return;
  const c = candidates[idx];
  book._candidateIdx = idx;
  book._enrich = { ...book._enrich, suggested: c.metadata || {} };

  if (c.work_key) book._work_key = c.work_key;
  openDiffEditor(book);
}

async function refreshEnrich(book, btn) {
  await withBusy(btn, '…', async () => {
    try {
      const r = await fetch(`/api/books/${book.id}/enrich?refresh=1`, { method: 'POST' }).then(r => r.json());

      const navigatedAway = state.currentBook?.id !== book.id;
      if (!r.enriched) {
        if (!navigatedAway) toast('No Open Library match after refresh', 'error');
        return;
      }
      const fresh = r.book;
      fresh._alt_covers = r.alt_covers || [];
      fresh._editions = r.editions || [];
      fresh._work_key = r.work_key || null;
      fresh._tried = r.tried || [];
      fresh._candidates = r.candidates || [];
      fresh._candidateIdx = 0;
      fresh._enrich = {
        current: r.current || {},
        suggested: r.suggested || {},
      };

      if (fresh._alt_covers.length > 0 && !(await hasAnyCover(fresh.id))) {
        try {
          const cr = await fetch(`/api/books/${fresh.id}/cover`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ url: fresh._alt_covers[0] }),
          });
          if (cr.ok) {
            fresh.has_cover_override = true;
            fresh.updated_at = Math.floor(Date.now() / 1000);
            toast('Refreshed — applied first OL cover (click another to override)');
          }
        } catch {}
      }

      if (!navigatedAway) {
        state.currentBook = fresh;
        renderDetail(fresh);
        openDiffEditor(fresh);
        if (!fresh.has_cover_override) toast('Refreshed from Open Library');
      } else {
        toast(`Refresh complete for "${book.title || book.path.split('/').pop()}"`);
      }
    } catch (err) {
      toast('Refresh failed: ' + err.message, 'error');
    }
  });
}

async function hasAnyCover(bookId) {
  try {
    const r = await fetch(`/api/books/${bookId}/cover?probe=1`, { method: 'GET' });
    return r.ok;
  } catch {
    return false;
  }
}

async function triageAction(action) {
  const queue = state.books || [];
  if (queue.length === 0) return;
  const idx = state.triageIdx || 0;
  switch (action) {
    case 'prev':
      state.triageIdx = Math.max(0, idx - 1);
      saveTriagePosition();
      render();
      break;
    case 'next':
      state.triageIdx = Math.min(queue.length - 1, idx + 1);
      saveTriagePosition();
      render();
      break;
    case 'skip': {

      const book = queue[idx];
      fetch(`/api/books/${book.id}/skip-triage`, { method: 'POST' }).catch(() => {});
      queue.splice(idx, 1);
      if (state.triageIdx >= queue.length) state.triageIdx = Math.max(0, queue.length - 1);
      saveTriagePosition();
      render();
      pollEnrichStatus();
      break;
    }
    case 'apply': {

      const applyBtn = document.querySelector('.triage-diff .diff-apply-actions .primary');
      if (applyBtn) applyBtn.click();

      setTimeout(() => {
        state.triageIdx = Math.min(queue.length - 1, idx + 1);
        saveTriagePosition();
        render();
      }, 300);
      break;
    }
  }
}

const CMDK_COMMANDS = [
  { id: 'view:all',         label: 'View all books',         hint: 'Library — every row', run: () => switchView('all') },
  { id: 'view:series',      label: 'View by series',         hint: 'Grouped',              run: () => switchView('series') },
  { id: 'view:variants',    label: 'View format variants',   hint: 'Same work, many files', run: () => switchView('variants') },
  { id: 'view:missing',     label: 'View missing metadata',  hint: 'Books without title/author', run: () => switchView('missing') },
  { id: 'view:unverified',  label: 'View unverified',        hint: 'Embedded only, not verified', run: () => switchView('unverified') },
  { id: 'view:duplicates',  label: 'View duplicates',        hint: 'SHA + fuzzy matches', run: () => switchView('duplicates') },
  { id: 'view:rename',      label: 'Open Rename preview',    hint: 'Canonical layout',     run: () => switchView('rename') },
  { id: 'view:triage',      label: 'Open Triage queue',      hint: 'One-by-one fix flow',  run: () => switchView('triage') },
  { id: 'view:stats',       label: 'Open reading dashboard', hint: 'Status counts, months finished, top authors', run: () => switchView('stats') },
  { id: 'enrich:start',     label: 'Fetch metadata (batch)', hint: 'Open Library lookup for every unverified book', run: () => openEnrichModal() },
  { id: 'enrich:missing',   label: 'Fetch metadata for missing only', hint: 'Limit to incomplete rows',  run: () => { switchView('missing'); openEnrichModal(); } },
  { id: 'add-books',        label: 'Add books from a folder', hint: 'Pick a folder of ebooks/comics/PDFs', run: () => ($('#add-books-btn') || $('#open-sources-btn'))?.click() },
  { id: 'sources:open',     label: 'Manage tracked folders', hint: 'Add or rescan a folder', run: () => $('#open-sources-btn')?.click() },
  { id: 'jobs:open',        label: 'Scheduled maintenance jobs', hint: 'Schedule rescans / backfills', run: () => $('#open-jobs-btn')?.click() },
  { id: 'sync:rescan-all',  label: 'Rescan all folders',     hint: 'Walk every tracked source for changes', run: () => $('#rescan-all-btn')?.click() },
  { id: 'import:library',   label: 'Import library metadata', hint: 'Upload a JSON file of catalog rows', run: () => openTransferModal('import') },
  { id: 'export:json',      label: 'Export library as JSON', hint: 'Download the full catalog (JSON)',    run: () => { openTransferModal('export'); triggerDownload('/api/export'); } },
  { id: 'export:csv',       label: 'Export library as CSV',  hint: 'Download the full catalog (CSV)',     run: () => { openTransferModal('export'); triggerDownload('/api/export?format=csv'); } },
  { id: 'backfill:paths',   label: 'Backfill series from filenames', hint: 'Parse series / index from path', run: () => $('#derive-paths-btn')?.click() },
  { id: 'view:standardize', label: 'Preview canonical rename', hint: 'Open the Rename lens',              run: () => switchView('rename') },
  { id: 'focus:search',     label: 'Focus search',           hint: '/ shortcut',           run: () => { $('#search')?.focus(); $('#search')?.select(); } },
  { id: 'sort:author',      label: 'Sort by Author',         hint: 'A → Z',                run: () => setSortFromCmdk('author') },
  { id: 'sort:added',       label: 'Sort by Added',          hint: 'newest first',         run: () => setSortFromCmdk('added') },
  { id: 'sort:year',        label: 'Sort by Year',           hint: 'newest first',         run: () => setSortFromCmdk('year') },
  { id: 'sort:size',        label: 'Sort by Size',           hint: 'largest first',        run: () => setSortFromCmdk('size') },
];

const cmdkState = { open: false, selectedIdx: 0, filtered: CMDK_COMMANDS };

function switchView(view) {
  const tab = $(`.tab[data-view="${view}"]`);
  if (tab) tab.click();
}

function setSortFromCmdk(key) {

  state.order = key;
  refresh();
}

function openCmdk() {
  cmdkState.open = true;
  cmdkState.selectedIdx = 0;
  cmdkState.filtered = CMDK_COMMANDS;
  const overlay = $('#cmdk-overlay');
  if (!overlay) return;
  overlay.hidden = false;
  const input = $('#cmdk-input');
  if (input) {
    input.value = '';
    input.focus();
  }
  renderCmdk();
}

function closeCmdk() {
  cmdkState.open = false;
  const overlay = $('#cmdk-overlay');
  if (overlay) overlay.hidden = true;
}

function filterCmdk(query) {
  const q = query.trim().toLowerCase();
  if (q.length === 0) { cmdkState.filtered = CMDK_COMMANDS; return; }
  cmdkState.filtered = CMDK_COMMANDS
    .map(c => ({ c, score: cmdkScore(c, q) }))
    .filter(x => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .map(x => x.c);
  cmdkState.selectedIdx = 0;
}

function cmdkScore(cmd, q) {
  const label = cmd.label.toLowerCase();
  const hint = (cmd.hint || '').toLowerCase();
  const id = cmd.id.toLowerCase();
  const exactAt = label.indexOf(q);
  if (exactAt >= 0) return 100 - exactAt;
  if (id.includes(q)) return 70;
  if (hint.includes(q)) return 25;

  let i = 0;
  for (const c of label) {
    if (c === q[i]) i++;
    if (i === q.length) return 20;
  }
  return 0;
}

function renderCmdk() {
  const list = $('#cmdk-list');
  if (!list) return;
  list.innerHTML = '';
  cmdkState.filtered.forEach((c, i) => {
    const li = document.createElement('li');
    li.className = 'cmdk-item' + (i === cmdkState.selectedIdx ? ' is-on' : '');
    li.innerHTML = `<span class="cmdk-label">${escapeHtml(c.label)}</span>` +
                   `<span class="cmdk-hint-text">${escapeHtml(c.hint || '')}</span>`;
    li.addEventListener('click', () => runCmdk(i));
    list.appendChild(li);
  });
  if (cmdkState.filtered.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'cmdk-empty';
    empty.textContent = 'No matching command';
    list.appendChild(empty);
  }
}

function runCmdk(idx) {
  const cmd = cmdkState.filtered[idx];
  if (!cmd) return;
  closeCmdk();
  try { cmd.run(); } catch (err) { toast('command failed: ' + err.message, 'error'); }
}

document.addEventListener('keydown', (e) => {

  if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {

    e.preventDefault();
    if (cmdkState.open) closeCmdk(); else openCmdk();
    return;
  }
  if (!cmdkState.open) return;
  if (e.key === 'Escape') { e.preventDefault(); closeCmdk(); return; }
  if (e.key === 'ArrowDown') {
    e.preventDefault();
    cmdkState.selectedIdx = Math.min(cmdkState.filtered.length - 1, cmdkState.selectedIdx + 1);
    renderCmdk();
    return;
  }
  if (e.key === 'ArrowUp') {
    e.preventDefault();
    cmdkState.selectedIdx = Math.max(0, cmdkState.selectedIdx - 1);
    renderCmdk();
    return;
  }
  if (e.key === 'Enter') {
    e.preventDefault();
    runCmdk(cmdkState.selectedIdx);
    return;
  }
});

$('#cmdk-input')?.addEventListener('input', (e) => {
  filterCmdk(e.target.value);
  renderCmdk();
});

$('#cmdk-overlay .cmdk-backdrop')?.addEventListener('click', closeCmdk);

function saveTriagePosition() {
  try {
    const queue = state.books || [];
    const sig = queue.length > 0 ? `${queue.length}:${queue[0]?.id}` : '0:0';
    localStorage.setItem('triage.idx', String(state.triageIdx ?? 0));
    localStorage.setItem('triage.sig', sig);
  } catch {}
}

function restoreTriagePosition() {
  try {
    const queue = state.books || [];
    if (queue.length === 0) return;
    const savedSig = localStorage.getItem('triage.sig');
    const liveSig = `${queue.length}:${queue[0]?.id}`;
    if (savedSig !== liveSig) return;
    const savedIdx = parseInt(localStorage.getItem('triage.idx') || '0', 10);
    if (!isNaN(savedIdx) && savedIdx >= 0 && savedIdx < queue.length) {
      state.triageIdx = savedIdx;
    }
  } catch {}
}

document.addEventListener('keydown', (e) => {
  if (state.view !== 'triage') return;
  if (e.target.matches('input, textarea, select')) return;
  if (document.querySelector('#enrich-modal:not([hidden]), #sources-modal:not([hidden])')) return;
  let action = null;
  if (e.key === 'j' || e.key === 'J' || e.key === 'ArrowDown' || e.key === 'ArrowRight') action = 'next';
  else if (e.key === 'k' || e.key === 'K' || e.key === 'ArrowUp' || e.key === 'ArrowLeft') action = 'prev';
  else if (e.key === 's' || e.key === 'S') action = 'skip';
  else if (e.key === 'Enter') action = 'apply';
  if (action) {
    e.preventDefault();
    triageAction(action);
  }
});

function dupGroupEl(g) {
  const box = document.createElement('div');
  box.className = 'dup-group';
  const h = document.createElement('h3');
  h.textContent = `sha256 ${g.sha256.slice(0, 12)} · ${g.books.length} copies`;
  box.appendChild(h);
  const members = document.createElement('div');
  members.className = 'members';

  for (const b of g.books) members.appendChild(bookCard(b));
  box.appendChild(members);
  return box;
}

function toggleSelect(id) {
  if (state.selection.has(id)) state.selection.delete(id);
  else state.selection.add(id);
  $$(`.book-card[data-id="${id}"]`).forEach(c => {
    c.classList.toggle('selected', state.selection.has(id));
    const cb = c.querySelector('.cover-checkbox');
    if (cb) cb.innerHTML = state.selection.has(id) ? '✓' : '';
  });
  updateSelectionBar();
}

function clearSelection() {
  state.selection.clear();
  $$('.book-card.selected').forEach(c => {
    c.classList.remove('selected');
    const cb = c.querySelector('.cover-checkbox');
    if (cb) cb.innerHTML = '';
  });
  updateSelectionBar();
}

function updateSelectionBar() {
  const bar = $('#selection-bar');
  const n = state.selection.size;
  bar.hidden = n === 0;
  if (n > 0) $('#selection-count').textContent = `${n} selected`;
}

$('#bulk-clear').addEventListener('click', clearSelection);

$('#bulk-enrich').addEventListener('click', async () => {
  const ids = [...state.selection];
  const btn = $('#bulk-enrich');
  btn.disabled = true; btn.textContent = 'Enriching…';
  try {
    const r = await fetch('/api/books/bulk/enrich', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ids }),
    }).then(r => r.json());
    toast(`Enriched ${r.enriched}, no match ${r.no_match}, errors ${r.errors}`);
    clearSelection();
    await refresh();
    loadFacets();
  } catch (err) {
    toast('enrich failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Enrich all';
  }
});

async function bulkSetStatus(status, btn) {
  const ids = [...state.selection];
  btn.disabled = true;
  try {
    for (const id of ids) {
      await fetch(`/api/books/${id}/status`, {
        method: 'PATCH', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ status }),
      });
    }
    toast(`Marked ${ids.length} as ${status}`);
    clearSelection();
    await refresh();
  } catch (err) {
    toast('status update failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false;
  }
}
$('#bulk-status-reading').addEventListener('click', (e) => bulkSetStatus('reading', e.currentTarget));
$('#bulk-status-finished').addEventListener('click', (e) => bulkSetStatus('finished', e.currentTarget));

$('#bulk-delete').addEventListener('click', async () => {
  const ids = [...state.selection];
  if (!confirm(`Delete ${ids.length} book(s) from the catalog?\nFiles on disk will NOT be removed.`)) return;
  const btn = $('#bulk-delete');
  btn.disabled = true; btn.textContent = 'Deleting…';
  try {
    const r = await fetch('/api/books/bulk/delete', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ids, remove_files: false }),
    }).then(r => r.json());
    toast(`Deleted ${r.deleted} entries`);
    clearSelection();
    if (state.selectedId && ids.includes(state.selectedId)) closeDetail();
    await refresh();
    loadFacets();
  } catch (err) {
    toast('delete failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Delete…';
  }
});

function openBulkEditModal() {
    const ids = [...state.selection];
    if (ids.length === 0) return;
    const modal = $('#bulk-edit-modal');
    $('#bulk-edit-count').textContent = String(ids.length);
    $('#bulk-edit-apply-count').textContent = String(ids.length);
    $('#bulk-edit-error').hidden = true;

    for (const sel of modal.querySelectorAll('.bulk-edit-mode')) {
        sel.value = 'leave';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
    }
    for (const input of modal.querySelectorAll('.bulk-edit-row input[type="text"]')) {
        input.value = '';
    }
    modal.hidden = false;
    setTimeout(() => modal.querySelector('.bulk-edit-mode')?.focus(), 50);
    document.addEventListener('keydown', onBulkEditKey);
}
function closeBulkEditModal() {
    $('#bulk-edit-modal').hidden = true;
    document.removeEventListener('keydown', onBulkEditKey);
}
function onBulkEditKey(e) { if (e.key === 'Escape') closeBulkEditModal(); }

for (const sel of document.querySelectorAll('#bulk-edit-modal .bulk-edit-mode')) {
    sel.addEventListener('change', (e) => {
        const row = e.currentTarget.closest('.bulk-edit-row');
        const input = row.querySelector('input[type="text"]');
        if (!input) return;
        input.disabled = e.currentTarget.value !== 'set';
        if (input.disabled) input.value = '';
    });
}

$('#bulk-edit')?.addEventListener('click', openBulkEditModal);
$('#bulk-edit-cancel')?.addEventListener('click', closeBulkEditModal);
$('#bulk-edit-modal .modal-close')?.addEventListener('click', closeBulkEditModal);
$('#bulk-edit-modal')?.addEventListener('click', (e) => {
    if (e.target.id === 'bulk-edit-modal') closeBulkEditModal();
});

$('#bulk-edit-form')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const ids = [...state.selection];
    if (ids.length === 0) { closeBulkEditModal(); return; }
    const update = {};
    for (const sel of document.querySelectorAll('#bulk-edit-modal .bulk-edit-mode')) {
        const field = sel.dataset.field;
        const mode = sel.value;
        if (mode === 'leave') continue;
        const input = document.querySelector(`#bulk-edit-${field}`);
        if (mode === 'set') {
            const val = (input?.value || '').trim();
            if (!val) continue;
            update[field] = val;
        } else if (mode === 'clear') {
            update[field] = '';
        }
    }

    const subj = ($('#bulk-edit-subjects')?.value || '').trim();
    if (subj) update.subjects = subj;
    if (Object.keys(update).length === 0) {
        const err = $('#bulk-edit-error');
        err.textContent = 'Pick at least one field to change.';
        err.hidden = false;
        return;
    }
    const btn = $('#bulk-edit-apply');
    btn.disabled = true; btn.textContent = 'Applying…';
    try {
        const r = await fetch('/api/books/bulk/patch', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ ids, update, append_subjects: true }),
        }).then(r => r.json());
        const errCount = (r.errors || []).length;
        toast(
            errCount === 0
                ? `Updated ${r.updated} books`
                : `Updated ${r.updated}, ${errCount} error${errCount === 1 ? '' : 's'}`,
            errCount === 0 ? null : 'error',
        );
        closeBulkEditModal();
        clearSelection();
        await refresh();
        loadFacets();
    } catch (err) {
        const errEl = $('#bulk-edit-error');
        errEl.textContent = 'Bulk edit failed: ' + err.message;
        errEl.hidden = false;
    } finally {
        btn.disabled = false;
        btn.innerHTML = 'Apply to <span id="bulk-edit-apply-count">' + state.selection.size + '</span> books';
    }
});

async function selectBook(id) {
  state.selectedId = id;
  state.clusterIds = null;
  state.editing = false;
  $$('.book-card.active').forEach(r => r.classList.remove('active'));
  $$(`.book-card[data-id="${id}"]`).forEach(c => c.classList.add('active'));

  $('#detail').hidden = false;
  $('#detail-body').innerHTML = '<p style="color:var(--fg-dim)">loading…</p>';

  const b = await fetch(`/api/books/${id}`).then(r => r.json());
  state.currentBook = b;
  renderDetail(b);
}

async function selectClusterByIds(ids) {
  state.clusterIds = ids;
  state.editing = false;
  $$('.book-card.active').forEach(r => r.classList.remove('active'));

  const idSet = new Set(ids);
  $$('.book-card').forEach(c => {
    if (idSet.has(Number(c.dataset.id))) c.classList.add('active');
    const cl = (c.dataset.cluster || '').split(',').map(Number);
    if (cl.length > 1 && cl.every(id => idSet.has(id))) c.classList.add('active');
  });

  $('#detail').hidden = false;
  $('#detail-body').innerHTML = '<p style="color:var(--fg-dim)">loading…</p>';

  const members = await Promise.all(
    ids.map(id => fetch(`/api/books/${id}`).then(r => r.json())),
  );
  const primary = pickPrimary(members);
  state.currentBook = primary;
  state.selectedId = primary.id;
  renderClusterDetail(primary, members);
}

function renderClusterDetail(primary, members) {
  renderDetail(primary);
  const body = $('#detail-body');

  const section = document.createElement('div');
  section.className = 'rich-section variants-section';
  const h = document.createElement('h3');
  h.textContent = `Copies in your library (${members.length})`;
  section.appendChild(h);

  const list = document.createElement('div');
  list.className = 'variants-list';
  for (const m of members) list.appendChild(variantRow(m, primary.id === m.id));
  section.appendChild(list);

  body.appendChild(section);
}

function variantRow(m, isPrimary) {
  const row = document.createElement('div');
  row.className = 'variant-row' + (isPrimary ? ' is-primary' : '');

  const thumb = document.createElement('img');
  thumb.className = 'variant-thumb';
  thumb.loading = 'lazy';
  thumb.src = `/api/books/${m.id}/cover?t=${m.updated_at || ''}`;
  thumb.onerror = () => thumb.remove();
  row.appendChild(thumb);

  const info = document.createElement('div');
  info.className = 'variant-info';
  const top = document.createElement('div');
  top.className = 'variant-top';
  const fmt = document.createElement('span');
  fmt.className = 'chip chip-format';
  fmt.textContent = (m.format || '?').toUpperCase();
  top.appendChild(fmt);
  if (isPrimary) {
    const star = document.createElement('span');
    star.className = 'chip chip-primary';
    star.textContent = 'PRIMARY';
    star.title = 'Drives the title/cover for the cluster card';
    top.appendChild(star);
  }
  if (m.size) {
    const size = document.createElement('span');
    size.className = 'variant-size';
    size.textContent = formatBytes(m.size);
    top.appendChild(size);
  }
  info.appendChild(top);

  const path = document.createElement('div');
  path.className = 'variant-path';
  path.textContent = m.path;
  path.title = m.path;
  info.appendChild(path);

  row.appendChild(info);

  const actions = document.createElement('div');
  actions.className = 'variant-actions';
  if (m.format === 'epub') {
    const read = document.createElement('button');
    read.className = 'icon-btn';
    read.textContent = 'Read';
    read.onclick = (e) => { e.stopPropagation(); openReader(m); };
    actions.appendChild(read);
  }
  const dl = document.createElement('button');
  dl.className = 'icon-btn';
  dl.textContent = 'Download';
  dl.onclick = (e) => { e.stopPropagation(); window.location.href = `/api/books/${m.id}/file`; };
  actions.appendChild(dl);
  const del = document.createElement('button');
  del.className = 'icon-btn danger';
  del.textContent = 'Delete';
  del.title = 'Remove this copy from the catalog';
  del.onclick = (e) => { e.stopPropagation(); doDelete(m, del); };
  actions.appendChild(del);
  row.appendChild(actions);

  row.addEventListener('click', () => selectBook(m.id));
  return row;
}

function resumeLabel(b) {
  if (typeof b.read_percent === 'number' && b.read_percent > 0) {
    const pct = Math.max(1, Math.min(99, Math.round(b.read_percent * 100)));
    return `Resume (${pct}%)`;
  }
  return 'Read';
}

function formatBytes(n) {
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(0) + ' KB';
  return (n / (1024 * 1024)).toFixed(1) + ' MB';
}

function renderDetail(b) {
  const body = $('#detail-body');
  body.innerHTML = '';

  const coverWrap = document.createElement('div');
  coverWrap.className = 'detail-cover-wrap';
  const cover = document.createElement('img');
  cover.className = 'detail-cover clickable';
  cover.src = `/api/books/${b.id}/cover?t=${Date.now()}`;
  cover.alt = b.title || '';
  cover.title = 'Click to view full size';
  cover.onerror = () => { cover.style.display = 'none'; };
  cover.onclick = () => openMainCoverLightbox(b);
  coverWrap.appendChild(cover);
  if (b.has_cover_override) {
    const badge = document.createElement('div');
    badge.className = 'badge override';
    badge.textContent = b.format === 'epub'
      ? 'cover override · baked into EPUB'
      : 'cover override · file unchanged';
    badge.title = b.format === 'epub'
      ? 'A user-selected cover has been written into the EPUB file.'
      : 'A user-selected cover is being served from the booktool library; the source file is unchanged.';
    coverWrap.appendChild(badge);
  }
  body.appendChild(coverWrap);

  const info = document.createElement('div');
  info.className = 'detail-info';
  info.appendChild(state.editing ? editForm(b) : readonlyView(b));
  body.appendChild(info);

  if (!state.editing && b.description) {
    const desc = document.createElement('div');
    desc.className = 'description';
    desc.innerHTML = b.description;
    body.appendChild(desc);

    queueMicrotask(() => {
      if (desc.scrollHeight > desc.clientHeight + 4) {
        const toggle = document.createElement('button');
        toggle.className = 'description-toggle';
        toggle.textContent = 'Show more';
        toggle.onclick = () => {
          const expanded = desc.classList.toggle('expanded');
          toggle.textContent = expanded ? 'Show less' : 'Show more';
        };
        desc.insertAdjacentElement('afterend', toggle);
      }
    });
  }

  if (!state.editing && Array.isArray(b._alt_covers) && b._alt_covers.length > 0) {
    body.appendChild(altCoversSection(b));
  }
  if (!state.editing && Array.isArray(b._editions) && b._editions.length > 0) {
    body.appendChild(editionsSection(b));
  }

}

const coverPaginators = new Map();

function altCoversSection(b) {
  const section = document.createElement('div');
  section.className = 'rich-section';
  const h = document.createElement('h3');
  h.textContent = `Alternative covers (${b._alt_covers.length})`;
  section.appendChild(h);

  const strip = document.createElement('div');
  strip.className = 'cover-strip';
  for (const url of b._alt_covers) {
    strip.appendChild(buildCoverThumb(b, url));
  }
  section.appendChild(strip);

  if (b._work_key) {
    const pag = coverPaginators.get(b.id);
    const exhausted = pag?.exhausted === true;
    if (!exhausted) {
      const more = document.createElement('button');
      more.className = 'cover-strip-more';
      more.type = 'button';
      more.textContent = 'Show more covers';
      more.title = 'Walk OpenLibrary editions for additional covers';
      more.onclick = () => loadMoreCovers(b, more, strip);
      section.appendChild(more);
    }
  }
  return section;
}

function buildCoverThumb(b, url) {
  const img = document.createElement('img');
  img.src = url;
  img.loading = 'lazy';
  img.title = 'Click to preview / use this cover';
  img.classList.add('clickable');
  img.onerror = () => img.remove();
  img.onclick = () => openCoverPreview(b, url);
  return img;
}

async function loadMoreCovers(b, btn, strip) {
  if (!b._work_key) return;
  const pag = coverPaginators.get(b.id) ?? {
    offset: (b._alt_covers || []).length,
    exhausted: false,
  };
  const controller = new AbortController();
  pag.controller = controller;
  coverPaginators.set(b.id, pag);

  const want = 6;
  const placeholders = [];
  for (let i = 0; i < want; i++) {
    const p = document.createElement('div');
    p.className = 'cover-placeholder';
    strip.appendChild(p);
    placeholders.push(p);
  }

  await withBusy(btn, 'Fetching…', async () => {
    try {
      const seen = (b._alt_covers || []).slice(-12).join(',');
      const url = `/api/books/${b.id}/covers`
        + `?work_key=${encodeURIComponent(b._work_key)}`
        + `&offset=${pag.offset}`
        + `&limit=${want}`
        + (seen ? `&seen=${encodeURIComponent(seen)}` : '');
      const r = await fetch(url, { signal: controller.signal });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();

      for (let i = 0; i < placeholders.length; i++) {
        const u = data.urls?.[i];
        if (!u) { placeholders[i].remove(); continue; }
        placeholders[i].replaceWith(buildCoverThumb(b, u));
      }

      b._alt_covers = (b._alt_covers || []).concat(data.urls || []);
      pag.offset = data.next_offset;
      pag.exhausted = data.exhausted;
      coverPaginators.set(b.id, pag);

      const heading = strip.parentElement?.querySelector('h3');
      if (heading) heading.textContent = `Alternative covers (${b._alt_covers.length})`;

      if (pag.exhausted || (data.urls?.length ?? 0) === 0) {
        btn.remove();
        if ((data.urls?.length ?? 0) === 0 && !pag.exhausted) {
          toast('no more unique covers');
        }
      }
    } catch (err) {

      if (err.name === 'AbortError') return;
      placeholders.forEach(p => p.remove());
      toast("couldn't fetch more covers: " + err.message, 'error');
    }
  });
}

function openCoverPreview(b, url) {
  const overlay = document.createElement('div');
  overlay.className = 'lightbox';
  overlay.addEventListener('click', (e) => { if (e.target === overlay) overlay.remove(); });

  const card = document.createElement('div');
  card.className = 'lightbox-card';

  const img = document.createElement('img');
  img.src = url;
  card.appendChild(img);

  const actions = document.createElement('div');
  actions.className = 'lightbox-actions';

  const apply = document.createElement('button');
  apply.className = 'primary';
  apply.textContent = 'Use this as cover';
  apply.onclick = async () => {

    const pag = coverPaginators.get(b.id);
    if (pag?.controller) pag.controller.abort();
    coverPaginators.delete(b.id);

    apply.disabled = true;
    apply.textContent = 'Applying…';
    try {
      const r = await fetch(`/api/books/${b.id}/cover`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ url }),
      });
      if (!r.ok) {
        const err = await r.json().catch(() => ({}));
        throw new Error(err.error || `status ${r.status}`);
      }
      const result = await r.json().catch(() => ({}));
      toast(result.file_updated
        ? 'cover replaced and baked into the EPUB'
        : 'cover override stored (source file unchanged)');
      overlay.remove();

      if (state.currentBook?.id === b.id) selectBook(b.id);
      refresh();
    } catch (err) {
      apply.disabled = false;
      apply.textContent = 'Use this as cover';
      toast('cover swap failed: ' + err.message, 'error');
    }
  };

  const close = document.createElement('button');
  close.textContent = 'Close';
  close.onclick = () => overlay.remove();

  actions.append(apply, close);
  card.appendChild(actions);

  overlay.appendChild(card);
  document.body.appendChild(overlay);
}

function openMainCoverLightbox(b) {
  const overlay = document.createElement('div');
  overlay.className = 'lightbox';
  overlay.addEventListener('click', (e) => { if (e.target === overlay) overlay.remove(); });
  const card = document.createElement('div');
  card.className = 'lightbox-card';
  const img = document.createElement('img');
  img.src = `/api/books/${b.id}/cover?t=${Date.now()}`;
  card.appendChild(img);
  overlay.appendChild(card);
  document.body.appendChild(overlay);
  const onKey = (e) => {
    if (e.key === 'Escape') { overlay.remove(); document.removeEventListener('keydown', onKey); }
  };
  document.addEventListener('keydown', onKey);
}

function editionsSection(b) {
  const section = document.createElement('div');
  section.className = 'rich-section';
  const h = document.createElement('h3');
  h.textContent = `Other editions (${b._editions.length})`;
  section.appendChild(h);

  const table = document.createElement('table');
  table.className = 'editions-table';
  const thead = document.createElement('thead');
  thead.innerHTML = '<tr><th></th><th>Year</th><th>Publisher</th><th>ISBN</th><th>Lang</th><th>Pages</th></tr>';
  table.appendChild(thead);
  const tbody = document.createElement('tbody');
  for (const e of b._editions) {
    const tr = document.createElement('tr');
    if (b.isbn && e.isbn && normalizeIsbn(e.isbn) === normalizeIsbn(b.isbn)) {
      tr.classList.add('current-edition');
    }
    const cover = document.createElement('td');
    if (e.cover_url) {
      const img = document.createElement('img');
      img.src = e.cover_url;
      img.loading = 'lazy';
      img.className = 'edition-thumb';
      img.onerror = () => img.remove();
      cover.appendChild(img);
    }
    tr.appendChild(cover);
    tr.appendChild(td(e.year ?? ''));
    tr.appendChild(td(e.publisher ?? ''));
    const isbnCell = document.createElement('td');
    if (e.ol_key) {
      const a = document.createElement('a');
      a.href = `https://openlibrary.org${e.ol_key}`;
      a.target = '_blank';
      a.rel = 'noopener';
      a.textContent = e.isbn ?? '(ol)';
      isbnCell.appendChild(a);
    } else {
      isbnCell.textContent = e.isbn ?? '';
    }
    tr.appendChild(isbnCell);
    tr.appendChild(td(e.language ?? ''));
    tr.appendChild(td(e.pages ?? ''));
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  section.appendChild(table);
  return section;
}

function td(text) {
  const cell = document.createElement('td');
  cell.textContent = String(text);
  return cell;
}

function normalizeIsbn(s) {
  return String(s).replace(/[-\s]/g, '').toLowerCase();
}

function filenameTitleFallback(b) {
  if (!b.path) return '(untitled)';
  const base = b.path.split('/').pop() || b.path;
  return base.replace(/\.(epub|mobi|azw3|pdf|fb2|cbz)$/i, '');
}

function parentFolderName(b) {
  if (!b.path) return null;
  const parts = b.path.split('/').filter(Boolean);
  if (parts.length < 2) return null;
  return parts[parts.length - 2];
}

function readonlyView(b) {
  const wrap = document.createElement('div');

  const hero = document.createElement('div');
  hero.className = 'detail-hero';
  const title = document.createElement('h1');
  const hasTitle = !!b.title;
  const hasAuthor = (b.authors && b.authors.length > 0) || !!b.author_sort;

  title.textContent = hasTitle ? b.title : filenameTitleFallback(b);
  if (!hasTitle) title.classList.add('detail-title-fallback');
  hero.appendChild(title);

  const authorLine = document.createElement('div');
  authorLine.className = 'detail-author';
  if (hasAuthor) {
    authorLine.textContent = (b.authors || []).join('; ') || b.author_sort;
  } else {
    const folder = parentFolderName(b);
    authorLine.classList.add('detail-author-fallback');
    authorLine.textContent = folder ? `Folder: ${folder}` : 'unknown author';
  }
  hero.appendChild(authorLine);

  if (!hasTitle && !hasAuthor) {
    const noMeta = document.createElement('div');
    noMeta.className = 'detail-no-meta';
    noMeta.innerHTML = `
      <strong>No embedded metadata.</strong>
      <span>The title above is the file name; the author line is the
        parent folder. Use <em>Fetch info</em> below to look this book
        up online, or edit it manually.</span>
    `;
    hero.appendChild(noMeta);
  }

  if (b.series) {
    const sLine = document.createElement('div');
    sLine.className = 'detail-series';
    const link = document.createElement('a');
    link.href = '#';
    link.textContent = b.series + (b.series_index ? ' #' + b.series_index : '');
    link.title = `Filter to "${b.series}"`;
    link.addEventListener('click', (e) => { e.preventDefault(); setFilter('series', b.series); });
    sLine.appendChild(link);
    hero.appendChild(sLine);
  }

  const pubBits = [];
  if (b.year) pubBits.push(String(b.year));
  if (b.publisher) pubBits.push(b.publisher);
  if (pubBits.length > 0) {
    const pub = document.createElement('div');
    pub.className = 'detail-pub';
    pub.textContent = pubBits.join(' · ');
    hero.appendChild(pub);
  }
  wrap.appendChild(hero);

  const stateRow = document.createElement('div');
  stateRow.className = 'detail-row detail-row-state';
  stateRow.appendChild(statusToggle(b));
  wrap.appendChild(stateRow);

  const chipsRow = document.createElement('div');
  chipsRow.className = 'detail-row detail-row-chips';
  chipsRow.appendChild(trustChip(b));
  const fmtChip = document.createElement('span');
  fmtChip.className = 'chip chip-format';
  fmtChip.textContent = (b.format || 'unknown').toUpperCase();
  chipsRow.appendChild(fmtChip);
  wrap.appendChild(chipsRow);

  const banner = completenessBanner(b);
  if (banner) wrap.appendChild(banner);

  wrap.appendChild(actionBarSlim(b));

  const facts = document.createElement('div');
  facts.className = 'detail-facts';
  const factRow = (label, valueNode) => {
    const row = document.createElement('div');
    row.className = 'field';
    const lbl = document.createElement('b');
    lbl.textContent = label;
    row.append(lbl, valueNode);
    facts.appendChild(row);
  };
  const factText = (label, val) => {
    if (val == null || val === '') return;
    const v = document.createElement('span');
    v.textContent = String(val);
    factRow(label, v);
  };
  factText('Language', b.language);
  factText('ISBN', b.isbn);
  factText('SHA-256', b.sha256 ? b.sha256.slice(0, 16) + '…' : null);

  if (b.path) {
    const cell = document.createElement('div');
    cell.className = 'path-cell';
    cell.title = b.path;
    const txt = document.createElement('span');
    txt.className = 'path-text';

    txt.textContent = '\u202A' + b.path + '\u202C';
    const copy = document.createElement('button');
    copy.className = 'copy-btn';
    copy.type = 'button';
    copy.textContent = 'copy';
    copy.title = 'Copy full path to clipboard';
    copy.onclick = async (e) => {
      e.stopPropagation();
      try {
        await navigator.clipboard.writeText(b.path);
        copy.textContent = 'copied';
        copy.classList.add('copied');
        setTimeout(() => {
          copy.textContent = 'copy';
          copy.classList.remove('copied');
        }, 1200);
      } catch {
        toast('copy failed', 'error');
      }
    };
    cell.append(txt, copy);
    factRow('File', cell);

    if (b.original_path && b.original_path !== b.path) {
      const origCell = document.createElement('div');
      origCell.className = 'path-cell original-path';
      origCell.title = b.original_path;
      const orig = document.createElement('span');
      orig.className = 'path-text';
      orig.textContent = '\u202A' + b.original_path + '\u202C';
      origCell.appendChild(orig);
      factRow('Originally', origCell);
    }
  }

  if (Array.isArray(b.subjects) && b.subjects.length > 0) {
    const subjLabel = document.createElement('div');
    subjLabel.className = 'field-label';
    subjLabel.textContent = 'Subjects';
    facts.appendChild(subjLabel);
    const chips = document.createElement('div');
    chips.className = 'subject-chips';
    for (const s of b.subjects.slice(0, 12)) {
      const c = document.createElement('span');
      c.className = 'chip chip-subject';
      c.textContent = s;
      chips.appendChild(c);
    }
    facts.appendChild(chips);
  }
  wrap.appendChild(facts);
  return wrap;
}

async function withBusy(btn, busyLabel, fn) {
  if (!btn) return fn();
  const original = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = `<span class="spinner"></span>${escapeHtml(busyLabel)}`;
  try { return await fn(); }
  finally {
    btn.disabled = false;
    btn.innerHTML = original;
  }
}

function completenessBanner(b) {
  const level = trustLevel(b);
  if (level === 'high') return null;
  const wrap = document.createElement('div');
  wrap.className = 'completeness-banner ' +
    (level === 'med' ? 'partial' : 'unverified');

  const icon = document.createElement('div');
  icon.className = 'cb-icon';
  icon.textContent = level === 'med' ? 'ⓘ' : '⚠';
  wrap.appendChild(icon);

  const body = document.createElement('div');
  body.className = 'cb-body';
  const title = document.createElement('div');
  title.className = 'cb-title';
  title.textContent = level === 'med'
    ? 'Metadata is partial'
    : 'Embedded metadata only';
  body.appendChild(title);

  const sub = document.createElement('div');
  sub.className = 'cb-sub';
  const missing = [];
  if (!b.year) missing.push('year');
  if (!b.publisher) missing.push('publisher');
  if (!b.isbn) missing.push('ISBN');
  if (!b.description) missing.push('description');
  if (!Array.isArray(b.subjects) || b.subjects.length === 0) missing.push('subjects');
  sub.textContent = level === 'med'
    ? (missing.length > 0
        ? `From ${b.source || 'embedded'} · missing ${missing.slice(0, 3).join(', ')}`
        : `From ${b.source || 'embedded'}`)
    : "Most fields haven't been verified against a public catalog.";
  body.appendChild(sub);
  wrap.appendChild(body);

  const action = document.createElement('button');
  action.className = 'cb-action';
  action.textContent = level === 'med'
    ? 'Fetch info'
    : 'Fetch from Open Library';
  action.onclick = () => doEnrich(b, action);
  wrap.appendChild(action);

  return wrap;
}

function trustChip(b) {
  const level = trustLevel(b);
  const chip = document.createElement('span');
  chip.className = 'chip chip-trust trust-' + level;
  const src = b.source || 'embedded';
  const conf = (typeof b.confidence === 'number') ? b.confidence.toFixed(2) : '?';
  const labels = { high: 'verified', med: 'partial', low: 'unverified' };
  chip.textContent = `${labels[level]} · ${src}`;
  chip.title = `Source: ${src} · confidence ${conf}`;
  return chip;
}

function actionBarSlim(b) {
  const bar = document.createElement('div');
  bar.className = 'actions actions-slim';

  if (b.format !== 'unknown') {
    const read = document.createElement('button');
    read.className = 'primary';
    read.textContent = resumeLabel(b);
    read.onclick = () => openReader(b);
    bar.appendChild(read);
  }

  const promoteFetch = trustLevel(b) !== 'high';
  if (promoteFetch) {
    const fetchBtn = document.createElement('button');
    fetchBtn.className = 'secondary';
    fetchBtn.textContent = 'Fetch info';
    fetchBtn.title = 'Look this book up on Open Library and merge any missing fields';
    fetchBtn.onclick = () => doEnrich(b, fetchBtn);
    bar.appendChild(fetchBtn);
  }

  const dl = document.createElement('button');
  dl.textContent = 'Download';
  dl.onclick = () => { window.location.href = `/api/books/${b.id}/file`; };
  bar.appendChild(dl);

  const overflow = document.createElement('div');
  overflow.className = 'actions-overflow';
  const trigger = document.createElement('button');
  trigger.className = 'overflow-trigger';
  trigger.setAttribute('aria-haspopup', 'menu');
  trigger.title = 'More actions';
  trigger.textContent = '⋮';
  trigger.onclick = (e) => {
    e.stopPropagation();
    overflow.classList.toggle('open');
  };
  document.addEventListener('click', () => overflow.classList.remove('open'), { once: true });
  overflow.appendChild(trigger);

  const menu = document.createElement('div');
  menu.className = 'overflow-menu';
  const mkItem = (label, onClick, opts) => {
    const item = document.createElement('button');
    item.textContent = label;
    if (opts?.danger) item.classList.add('danger');
    item.onclick = (e) => { e.stopPropagation(); overflow.classList.remove('open'); onClick(item); };
    menu.appendChild(item);
  };
  mkItem('Edit metadata', () => { state.editing = true; renderDetail(b); });

  if (!promoteFetch) mkItem('Fetch info', (btn) => doEnrich(b, btn));
  mkItem('Change cover', () => uploadCover(b));

  if (b.format === 'mobi' || b.format === 'azw3') {
    mkItem('Convert to EPUB + open', (btn) => convertAndRead(b, btn));
  }
  if ((b.format === 'mobi' || b.format === 'azw3') && b.has_cover_override) {
    mkItem('Convert + apply cover (→ EPUB)', (btn) => bakeOverrideToEpub(b, btn));
  }

  menu.appendChild(convertMenu(b));

  if (typeof b.read_percent === 'number' && b.read_percent > 0) {
    mkItem('Start over', async (btn) => {
      btn.disabled = true;
      try {
        await fetch(`/api/books/${b.id}/location`, { method: 'DELETE' });
        toast('reading position cleared');

        if (state.currentBook?.id === b.id) selectBook(b.id);
        refresh();
      } catch (err) {
        toast('failed: ' + err.message, 'error');
      } finally { btn.disabled = false; }
    });
  }
  mkItem('Reset to embedded', (btn) => doReset(b, btn));
  mkItem('Delete', (btn) => doDelete(b, btn), { danger: true });
  overflow.appendChild(menu);

  bar.appendChild(overflow);
  return bar;
}

function statusToggle(b) {
  const wrap = document.createElement('div');
  wrap.className = 'status-toggle';
  for (const s of ['unread', 'reading', 'finished']) {
    const btn = document.createElement('button');
    btn.textContent = s;
    if ((b.read_status || 'unread') === s) btn.classList.add('active');
    btn.addEventListener('click', async () => {
      const fresh = await fetch(`/api/books/${b.id}/status`, {
        method: 'PATCH', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ status: s }),
      }).then(r => r.json());
      state.currentBook = fresh;
      renderDetail(fresh);

      $$(`.book-card[data-id="${b.id}"]`).forEach(c => {
        c.classList.remove('status-unread', 'status-reading', 'status-finished');
        c.classList.add('status-' + fresh.read_status);

        const frame = c.querySelector('.cover-frame');
        const existing = c.querySelector('.cover-status');
        if (existing) existing.remove();
        if (frame) {
          const flag = qualityFlag(fresh, trustLevel(fresh));
          if (flag) {
            const pill = document.createElement('div');
            pill.className = 'cover-status status-' + flag.kind;
            pill.textContent = flag.text;
            if (flag.title) pill.title = flag.title;
            frame.appendChild(pill);
          }
        }
      });
    });
    wrap.appendChild(btn);
  }
  return wrap;
}

function editForm(b) {
  const wrap = document.createElement('div');
  const title = document.createElement('h1');
  title.textContent = 'Edit metadata';
  wrap.appendChild(title);

  const textFields = [
    ['title', 'Title', b.title || ''],
    ['author', 'Author', b.author_sort || ''],
    ['series', 'Series', b.series || ''],
    ['series_index', 'Series #', b.series_index ?? ''],
    ['year', 'Year', b.year ?? ''],
    ['publisher', 'Publisher', b.publisher || ''],
    ['language', 'Language', b.language || ''],
    ['isbn', 'ISBN', b.isbn || ''],
    ['subjects', 'Subjects', (b.subjects || []).join(', ')],
  ];

  const form = document.createElement('div');
  form.className = 'edit-form';
  const inputs = {};
  for (const [key, label, value] of textFields) {
    const lbl = document.createElement('label');
    lbl.textContent = label;
    lbl.htmlFor = `edit-${key}`;
    const input = document.createElement('input');
    input.id = `edit-${key}`;
    input.type = 'text';
    input.value = value;
    form.append(lbl, input);
    inputs[key] = input;
  }

  {
    const lbl = document.createElement('label');
    lbl.textContent = 'Description';
    lbl.htmlFor = 'edit-description';
    const ta = document.createElement('textarea');
    ta.id = 'edit-description';
    ta.rows = 5;
    ta.value = (b.description || '').replace(/<[^>]+>/g, '').trim();
    form.append(lbl, ta);
    inputs.description = ta;
  }

  {
    const lbl = document.createElement('label');
    lbl.textContent = 'Cover';
    const wrap2 = document.createElement('div');
    wrap2.className = 'cover-edit-row';
    const thumb = document.createElement('img');
    thumb.src = `/api/books/${b.id}/cover?t=${Date.now()}`;
    thumb.className = 'cover-edit-thumb';
    thumb.onerror = () => { thumb.style.visibility = 'hidden'; };
    const picker = document.createElement('input');
    picker.type = 'file';
    picker.accept = 'image/jpeg,image/png';
    picker.id = 'edit-cover-file';
    wrap2.append(thumb, picker);
    form.append(lbl, wrap2);
  }
  wrap.appendChild(form);

  const actions = document.createElement('div');
  actions.className = 'actions';

  const save = document.createElement('button');
  save.className = 'primary';
  save.textContent = 'Save';
  save.onclick = () => withBusy(save, 'Saving…', async () => {
    try {

      const file = $('#edit-cover-file')?.files?.[0];
      if (file) {
        const bytes = await file.arrayBuffer();
        const b64 = arrayBufferToBase64(bytes);
        const cr = await fetch(`/api/books/${b.id}/cover`, {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ data_base64: b64 }),
        });
        if (!cr.ok) {
          const err = await cr.json().catch(() => ({}));
          throw new Error('cover: ' + (err.error || cr.status));
        }
      }

      const update = {};
      for (const [k, inp] of Object.entries(inputs)) {
        const current = (k === 'subjects' ? (b.subjects || []).join(', ') : String(b[k] ?? ''));
        if (inp.value !== current && inp.value !== '') update[k] = inp.value;
      }
      let fresh = b;
      if (Object.keys(update).length > 0) {
        fresh = await fetch(`/api/books/${b.id}`, {
          method: 'PATCH', headers: { 'content-type': 'application/json' },
          body: JSON.stringify(update),
        }).then(r => r.json());
      } else if (!file) {
        toast('nothing changed');
      }
      state.currentBook = fresh;
      state.editing = false;

      selectBook(b.id);
      refresh();
      loadFacets();
      toast('saved');
    } catch (err) {
      toast('save failed: ' + err.message, 'error');
    }
  });

  const cancel = document.createElement('button');
  cancel.textContent = 'Cancel';
  cancel.onclick = () => { state.editing = false; renderDetail(b); };
  actions.append(save, cancel);
  wrap.appendChild(actions);
  return wrap;
}

function actionBar(b) {
  const actions = document.createElement('div');
  actions.className = 'actions';

  if (b.format !== 'unknown') {
    const read = document.createElement('button');
    read.className = 'primary';
    read.textContent = resumeLabel(b);
    read.onclick = () => openReader(b);
    actions.appendChild(read);
  }

  const dl = document.createElement('button');
  dl.textContent = 'Download';
  dl.onclick = () => { window.location.href = `/api/books/${b.id}/file`; };
  actions.appendChild(dl);

  const edit = document.createElement('button');
  edit.textContent = 'Edit';
  edit.onclick = () => { state.editing = true; renderDetail(b); };
  actions.appendChild(edit);

  const enrich = document.createElement('button');
  enrich.textContent = 'Fetch info';
  enrich.onclick = () => doEnrich(b, enrich);
  actions.appendChild(enrich);

  const cov = document.createElement('button');
  cov.textContent = 'Change cover';
  cov.onclick = () => uploadCover(b);
  actions.appendChild(cov);

  if ((b.format === 'mobi' || b.format === 'azw3') && b.has_cover_override) {
    const bake = document.createElement('button');
    bake.textContent = 'Convert + apply';
    bake.title = 'Convert to EPUB so the override cover is embedded in the file itself';
    bake.onclick = () => bakeOverrideToEpub(b, bake);
    actions.appendChild(bake);
  }

  actions.appendChild(convertMenu(b));

  const reset = document.createElement('button');
  reset.textContent = 'Reset to embedded';
  reset.title = 'Discard all manual edits + enriched data; re-read the file';
  reset.onclick = () => doReset(b, reset);
  actions.appendChild(reset);

  const del = document.createElement('button');
  del.style.cssText = 'border-color:var(--danger);color:var(--danger)';
  del.textContent = 'Delete';
  del.onclick = () => doDelete(b, del);
  actions.appendChild(del);
  return actions;
}

async function bakeOverrideToEpub(b, btn) {
  btn.disabled = true;
  await withBusy(btn, 'Converting…', async () => {
    try {
      const r = await fetch(`/api/books/${b.id}/convert`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ to: 'epub' }),
      }).then(r => r.json());
      if (!r.ok) throw new Error(r.error || 'convert failed');
      toast(`converted to EPUB · cover baked in (${r.path.split('/').pop()})`);
      refresh();
    } catch (err) {
      toast('convert failed: ' + err.message, 'error');
    }
  });
}

async function convertAndRead(b, btn) {
  await withBusy(btn, 'Converting…', async () => {
    try {
      const r = await fetch(`/api/books/${b.id}/convert`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ to: 'epub' }),
      }).then(r => r.json());
      if (!r.ok) throw new Error(r.error || 'convert failed');

      await fetch('/api/books').then(x => x.json());
      const list = await fetch('/api/books').then(x => x.json());
      const fresh = list.find(x => x.path === r.path);
      if (!fresh) {
        toast('converted, but not yet in catalog — run scan and try again');
      } else {
        openReader(fresh);
      }
    } catch (err) {
      toast('convert failed: ' + err.message, 'error');
    }
  });
}

async function doReset(b, btn) {
  if (!confirm(`Reset metadata for "${b.title || b.path}" to the file's embedded values?\n\nManual edits and Open Library data on this row will be discarded.`)) return;
  await withBusy(btn, 'Resetting…', async () => {
    try {
      const fresh = await fetch(`/api/books/${b.id}/reset`, { method: 'POST' }).then(r => r.json());
      state.currentBook = fresh;
      state.editing = false;
      renderDetail(fresh);
      refresh();
      loadFacets();
      toast('reset to embedded metadata');
    } catch (err) {
      toast('reset failed: ' + err.message, 'error');
    }
  });
}

function convertMenu(b) {
  const menu = document.createElement('div');
  menu.className = 'convert-menu';
  const trigger = document.createElement('button');
  trigger.textContent = 'Convert ▾';
  trigger.onclick = (e) => { e.stopPropagation(); menu.classList.toggle('open'); };
  document.addEventListener('click', () => menu.classList.remove('open'), { once: true });
  menu.appendChild(trigger);

  const list = document.createElement('div');
  list.className = 'convert-menu-list';
  for (const fmt of ['epub', 'mobi', 'azw3', 'pdf']) {
    if (fmt === b.format) continue;
    const opt = document.createElement('button');
    opt.textContent = `to ${fmt}`;
    opt.onclick = async (e) => {
      e.stopPropagation();
      menu.classList.remove('open');
      await withBusy(trigger, `Converting → ${fmt}…`, async () => {
        try {
          const r = await fetch(`/api/books/${b.id}/convert`, {
            method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ to: fmt }),
          }).then(r => r.json());
          if (r.ok) toast(`converted → ${r.path}`);
          else toast(r.error || 'convert failed', 'error');
        } catch (err) {
          toast('convert failed: ' + err.message, 'error');
        }
      });
    };
    list.appendChild(opt);
  }
  menu.appendChild(list);
  return menu;
}

async function doEnrich(b, btn) {
  await withBusy(btn, 'Fetching…', async () => {
    try {
      const r = await fetch(`/api/books/${b.id}/enrich`, { method: 'POST' }).then(r => r.json());

      const navigatedAway = state.currentBook?.id !== b.id;
      if (r.enriched) {

        const book = r.book;
        book._alt_covers = r.alt_covers || [];
        book._editions = r.editions || [];
        book._work_key = r.work_key || null;
        book._tried = r.tried || [];
        book._candidates = r.candidates || [];
        book._candidateIdx = 0;
        book._enrich = {
          current: r.current || {},
          suggested: r.suggested || {},
          derived_series: r.derived_series || null,
          derived_series_index: r.derived_series_index ?? null,
        };
        if (!navigatedAway) {
          state.currentBook = book;
          renderDetail(book);

          openDiffEditor(book);
        }
        refresh();
        loadFacets();
        pollEnrichStatus();
        const triedTail = r.tried && r.tried.length > 1
          ? ` (took ${r.tried.length} tries)` : '';
        const cacheTail = r.from_cache
          ? ` (cached ${relTime(r.cached_at)})`
          : '';
        const navTail = navigatedAway ? ' — open the book to see suggestions' : '';
        toast(`Open Library match · ${enrichedFieldCount(r)} fields${triedTail}${cacheTail}${navTail}`.trim());
      } else {
        pollEnrichStatus();
        if (!navigatedAway) showEnrichNoMatchDialog(r);
        else toast(`No Open Library match for "${b.title || b.path.split('/').pop()}"`);
      }
    } catch (err) {
      toast('enrich failed: ' + err.message, 'error');
    }
  });
}

function enrichedFieldCount(resp) {
  const s = resp.suggested || {};
  let n = 0;
  for (const k of ['title','author','series','series_index','year','publisher','language','isbn','description']) {
    if (s[k] != null && s[k] !== '') n++;
  }
  if (Array.isArray(s.subjects) && s.subjects.length > 0) n++;
  return n;
}

const DIFF_FIELDS = [
  { key: 'title',        label: 'Title' },
  { key: 'author',       label: 'Author' },
  { key: 'series',       label: 'Series' },
  { key: 'series_index', label: 'Series #' },
  { key: 'year',         label: 'Year' },
  { key: 'publisher',    label: 'Publisher' },
  { key: 'isbn',         label: 'ISBN' },
  { key: 'language',     label: 'Language' },
  { key: 'description',  label: 'Description' },
];

function defaultPickFor(emb, sug) {
  if (emb == null || emb === '') return sug == null || sug === '' ? 'embedded' : 'suggested';
  if (sug == null || sug === '') return 'embedded';
  if (String(emb) === String(sug)) return 'embedded';
  if (String(sug).length > String(emb).length * 1.2) return 'suggested';
  return 'embedded';
}

function formatDiffValue(v) {
  if (v == null || v === '') return null;
  if (Array.isArray(v)) return v.join(', ');
  return String(v);
}

function openDiffEditor(book) {
  if (!book._enrich) return;
  const host = $('#detail-body');
  if (!host) return;

  let existing = host.querySelector('.diff');
  if (existing) existing.remove();
  const diff = buildDiffElement(book);
  host.insertBefore(diff, host.firstChild);
}

function makeDiffCell(value, side, picked, same) {
  const cell = document.createElement('div');
  cell.className = 'diff-cell';
  if (picked) cell.classList.add('is-picked');
  if (same) cell.classList.add('same');
  const formatted = formatDiffValue(value);
  if (formatted == null) {
    cell.classList.add('empty');
    cell.textContent = '—';
  } else {
    cell.textContent = formatted.length > 200 ? formatted.slice(0, 200) + '…' : formatted;
    cell.title = formatted;
  }
  return cell;
}

function pickDiffSide(field, side, row, picks, diff) {
  picks[field] = side;
  for (const cell of row.querySelectorAll('.diff-cell')) cell.classList.remove('is-picked');
  const target = side === 'embedded' ? row.children[1] : row.children[2];
  target.classList.add('is-picked');

  const book = state.currentBook;
  if (book && book._enrich) {
    updateDiffApplyInfo(diff, book._enrich.current, book._enrich.suggested, picks);
  }
}

function updateDiffApplyInfo(diff, current, suggested, picks) {
  let changes = 0;
  for (const f of DIFF_FIELDS) {
    if (picks[f.key] !== 'suggested') continue;
    const emb = formatDiffValue(current[f.key]);
    const sug = formatDiffValue(suggested[f.key]);
    if (emb !== sug && sug != null) changes++;
  }
  const info = diff.querySelector('.diff-apply-info');
  if (info) {
    if (changes === 0) info.innerHTML = 'No changes selected.';
    else info.innerHTML = `<b>${changes}</b> change${changes === 1 ? '' : 's'} will be written to file + catalog.`;
  }
}

async function applyDiffMerge(book, current, suggested, picks, btn, diff) {

  const body = {};
  for (const f of DIFF_FIELDS) {
    if (picks[f.key] !== 'suggested') continue;
    const sug = suggested[f.key];
    const emb = current[f.key];
    if (sug == null || sug === '') continue;
    if (formatDiffValue(sug) === formatDiffValue(emb)) continue;
    if (Array.isArray(sug)) {
      body[f.key] = sug.join(', ');
    } else {
      body[f.key] = String(sug);
    }
  }

  if (Object.keys(body).length === 0) { diff.remove(); return; }
  await withBusy(btn, 'Applying…', async () => {
    try {
      const r = await fetch(`/api/books/${book.id}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!r.ok) { toast('apply failed (' + r.status + ')', 'error'); return; }
      const fresh = await r.json();

      fresh._alt_covers = book._alt_covers || [];
      fresh._editions = book._editions || [];
      fresh._work_key = book._work_key || null;
      state.currentBook = fresh;
      renderDetail(fresh);
      refresh();
      loadFacets();
      diff.remove();
      toast('Applied ' + Object.keys(body).length + ' change' + (Object.keys(body).length === 1 ? '' : 's'));
    } catch (err) {
      toast('apply failed: ' + err.message, 'error');
    }
  });
}

function showEnrichNoMatchDialog(r) {
  const q = r.query || {};
  const tried = r.tried || [];
  if (tried.length === 0) {
    toast('no match on Open Library');
    return;
  }
  const rows = tried.map((a, i) => {
    const label = `#${i + 1}`;
    const title = escapeHtml(a.title || '∅');
    const author = a.author ? escapeHtml(a.author) : '<i>no author</i>';
    const docs = `${a.num_docs} doc${a.num_docs === 1 ? '' : 's'}`;
    const score = a.num_docs > 0 ? ` · score ${a.score}` : '';
    const chosen = a.chosen_title
      ? `<div class="enrich-tried-chosen">→ ${escapeHtml(a.chosen_title)}</div>` : '';
    return `<li><div class="enrich-tried-head">${label} <code>${title}</code> · ${author} · ${docs}${score}</div>${chosen}</li>`;
  }).join('');
  const queryLine = [
    q.isbn ? `ISBN: ${escapeHtml(q.isbn)}` : '',
    q.title ? `title: ${escapeHtml(q.title)}` : '',
    q.author ? `author: ${escapeHtml(q.author)}` : '',
  ].filter(Boolean).join(' · ');
  const dialog = document.createElement('div');
  dialog.className = 'modal';
  dialog.innerHTML = `
    <div class="modal-backdrop"></div>
    <div class="modal-body enrich-nomatch">
      <h3>No match on Open Library</h3>
      <div class="enrich-nomatch-query"><b>Catalog says:</b> ${queryLine || '<i>no usable query fields</i>'}</div>
      <p>Tried ${tried.length} variant${tried.length === 1 ? '' : 's'}:</p>
      <ol class="enrich-tried">${rows}</ol>
      <p class="enrich-nomatch-hint">Tip: edit the title/author on this book to a cleaner form (no subtitle, no series parens) and click <b>Fetch info</b> again.</p>
      <div class="modal-actions"><button class="btn">Close</button></div>
    </div>`;
  document.body.appendChild(dialog);
  const close = () => dialog.remove();
  dialog.querySelector('.modal-backdrop').addEventListener('click', close);
  dialog.querySelector('button').addEventListener('click', close);
}

async function doDelete(b, btn) {
  if (!confirm(`Delete "${b.title || b.path}" from the catalog?`)) return;
  const alsoFile = confirm('Also delete the file on disk?');
  await withBusy(btn, 'Deleting…', async () => {
    try {
      const url = `/api/books/${b.id}` + (alsoFile ? '?file=1' : '');
      await fetch(url, { method: 'DELETE' });
      closeDetail();
      refresh();
      loadFacets();
      toast(alsoFile ? 'deleted (catalog + file)' : 'deleted from catalog');
    } catch (err) {
      toast('delete failed: ' + err.message, 'error');
    }
  });
}

let pendingCoverBookId = null;
const coverInput = $('#cover-file-input');
function uploadCover(b) {
  pendingCoverBookId = b.id;
  coverInput.value = '';
  coverInput.click();
}
coverInput.addEventListener('change', async () => {
  const file = coverInput.files?.[0];
  if (!file || pendingCoverBookId == null) return;
  const id = pendingCoverBookId;
  pendingCoverBookId = null;
  try {
    const bytes = await file.arrayBuffer();
    const b64 = arrayBufferToBase64(bytes);
    const r = await fetch(`/api/books/${id}/cover`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ data_base64: b64 }),
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      throw new Error(err.error || `status ${r.status}`);
    }
    toast('cover updated');
    if (state.currentBook?.id === id) renderDetail(state.currentBook);
    refresh();
  } catch (err) {
    toast('cover upload failed: ' + err.message, 'error');
  }
});

function arrayBufferToBase64(buf) {
  const bytes = new Uint8Array(buf);
  let bin = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

$('#detail-close').addEventListener('click', closeDetail);
function closeDetail() {
  $('#detail').hidden = true;
  state.selectedId = null;
  state.editing = false;
  state.currentBook = null;
  $$('.book-card.active').forEach(r => r.classList.remove('active'));
}

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const FOLIATE_VIEW_URL = 'https://esm.sh/gh/johnfactotum/foliate-js/view.js?bundle';
const PDFJS_LIB_URL    = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.6.82/pdf.min.mjs';
const PDFJS_WORKER_URL = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.6.82/pdf.worker.min.mjs';

let currentReaderHandle = null;
let pendingLocationTimer = null;
let pendingLocationBookId = null;
let pendingLocationPayload = null;

async function openReader(book) {
  $('#reader-overlay').hidden = false;
  const area = $('#reader-area');
  area.innerHTML = '';
  area.classList.add('reader-loading');
  document.addEventListener('keydown', readerKeys);
  try {
    const saved = await fetchSavedLocation(book.id);
    if (book.format === 'pdf') {
      await openPdfReader(book, area, saved);
    } else if (book.format === 'cbz' || book.format === 'cbr' || book.format === 'cb7' || book.format === 'cbt') {

      await openComicReader(book, area, saved);
    } else {
      await openFoliateReader(book, area, saved);
    }
    autoMarkReading(book);
  } catch (err) {
    area.innerHTML = '';
    const msg = document.createElement('div');
    msg.className = 'reader-error';
    msg.innerHTML = '<h3>Couldn\'t open this book</h3>'
      + '<p>' + escapeHtml(err && err.message ? err.message : String(err)) + '</p>'
      + '<p class="reader-error-hint">If this keeps happening, click Download to open the file in your OS reader.</p>';
    area.appendChild(msg);
  } finally {
    area.classList.remove('reader-loading');
  }
}

function closeReader() {

  flushPendingLocation();
  $('#reader-overlay').hidden = true;

  $('#reader-area').innerHTML = '';
  currentReaderHandle = null;
  document.removeEventListener('keydown', readerKeys);
}

function readerKeys(e) {
  if (e.key === 'Escape') return closeReader();
  if (e.key === 'ArrowLeft' || e.key === 'PageUp') return readerPrev();
  if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') {
    e.preventDefault();
    return readerNext();
  }
}

function readerPrev() {
  if (!currentReaderHandle) return;
  if (currentReaderHandle.kind === 'foliate') currentReaderHandle.view?.prev?.();
  else if (currentReaderHandle.kind === 'pdf') pdfStepPage(-1);
  else if (currentReaderHandle.kind === 'comic') comicStepPage(-1);
}
function readerNext() {
  if (!currentReaderHandle) return;
  if (currentReaderHandle.kind === 'foliate') currentReaderHandle.view?.next?.();
  else if (currentReaderHandle.kind === 'pdf') pdfStepPage(1);
  else if (currentReaderHandle.kind === 'comic') comicStepPage(1);
}

$('#reader-close').addEventListener('click', closeReader);
$('#reader-prev').addEventListener('click', readerPrev);
$('#reader-next').addEventListener('click', readerNext);

async function openFoliateReader(book, area, saved) {

  if (!customElements.get('foliate-view')) {
    await import(FOLIATE_VIEW_URL);
  }
  const view = document.createElement('foliate-view');
  view.style.width = '100%';
  view.style.height = '100%';
  view.style.display = 'block';
  area.appendChild(view);

  const res = await fetch(`/api/books/${book.id}/file`);
  if (!res.ok) throw new Error(`server returned ${res.status}`);
  const blob = await res.blob();
  const filename = (book.path || '').split('/').pop() || `book.${book.format}`;
  const file = new File([blob], filename, { type: blob.type });

  await view.open(file);

  try {
    if (saved?.location?.startsWith('frac:')) {
      const f = parseFloat(saved.location.slice(5)) || 0;
      await view.goToFraction(f);
    } else if (saved?.location) {
      await view.goTo(saved.location);
    } else {
      await view.goToFraction(0);
    }
  } catch {

    try { await view.goToFraction(0); } catch {  }
  }

  view.addEventListener('relocate', (e) => {
    const d = e.detail || {};

    const location = d.cfi || (typeof d.fraction === 'number' ? `frac:${d.fraction.toFixed(6)}` : null);
    const percent = (typeof d.fraction === 'number') ? d.fraction : null;
    if (!location) return;
    scheduleLocationSave(book.id, { location, percent });
  });

  currentReaderHandle = { kind: 'foliate', view, bookId: book.id };
}

async function openPdfReader(book, area, saved) {

  if (!window._pdfjs) {
    const mod = await import(PDFJS_LIB_URL);
    mod.GlobalWorkerOptions.workerSrc = PDFJS_WORKER_URL;
    window._pdfjs = mod;
  }
  const pdfjs = window._pdfjs;

  area.classList.add('pdf-area');
  const canvas = document.createElement('canvas');
  canvas.className = 'pdf-canvas';
  area.appendChild(canvas);

  const pdf = await pdfjs.getDocument(`/api/books/${book.id}/file`).promise;
  const startPage = Math.max(1, Math.min(pdf.numPages, Number(saved?.location) || 1));

  currentReaderHandle = {
    kind: 'pdf',
    pdf,
    page: startPage,
    total: pdf.numPages,
    canvas,
    bookId: book.id,
  };
  await renderPdfPage();
}

async function renderPdfPage() {
  const h = currentReaderHandle;
  if (!h || h.kind !== 'pdf') return;
  const page = await h.pdf.getPage(h.page);

  const dpr = window.devicePixelRatio || 1;
  const containerH = $('#reader-area').clientHeight - 48;
  const viewportNatural = page.getViewport({ scale: 1 });
  const scale = (containerH / viewportNatural.height) * dpr;
  const viewport = page.getViewport({ scale });
  h.canvas.width = viewport.width;
  h.canvas.height = viewport.height;
  h.canvas.style.width  = (viewport.width  / dpr) + 'px';
  h.canvas.style.height = (viewport.height / dpr) + 'px';
  const ctx = h.canvas.getContext('2d');
  await page.render({ canvasContext: ctx, viewport }).promise;

  scheduleLocationSave(h.bookId, {
    location: String(h.page),
    percent: h.page / h.total,
  });
}

function pdfStepPage(delta) {
  const h = currentReaderHandle;
  if (!h || h.kind !== 'pdf') return;
  const next = h.page + delta;
  if (next < 1 || next > h.total) return;
  h.page = next;
  renderPdfPage().catch((err) => {
    console.warn('pdf render failed', err);
  });
}

function comicPrefs(bookId) {
  try {
    const raw = localStorage.getItem(`booktool.comic.prefs.${bookId}`);
    if (raw) return Object.assign({ rtl: false, spread: false }, JSON.parse(raw));
  } catch {}
  return { rtl: false, spread: false };
}
function setComicPrefs(bookId, prefs) {
  try {
    localStorage.setItem(`booktool.comic.prefs.${bookId}`, JSON.stringify(prefs));
  } catch {}
}

async function openComicReader(book, area, saved) {
  area.innerHTML = '';
  const pages = await fetch(`/api/books/${book.id}/comic-pages`).then(r => r.json());
  if (pages.count === 0) {
    throw new Error('this comic archive has no readable image pages');
  }

  let startPage = 0;
  if (saved && saved.location) {
    const n = parseInt(saved.location, 10);
    if (Number.isFinite(n) && n >= 0 && n < pages.count) startPage = n;
  }

  const prefs = comicPrefs(book.id);

  const stage = document.createElement('div');
  stage.className = 'comic-stage' + (prefs.spread ? ' spread' : '') + (prefs.rtl ? ' rtl' : '');
  const imgLeft = document.createElement('img');
  imgLeft.className = 'comic-page-img';
  imgLeft.alt = '';
  const imgRight = document.createElement('img');
  imgRight.className = 'comic-page-img secondary';
  imgRight.alt = '';
  imgRight.hidden = !prefs.spread;

  stage.appendChild(imgLeft);
  stage.appendChild(imgRight);
  area.appendChild(stage);

  const counter = document.createElement('div');
  counter.className = 'comic-counter';
  area.appendChild(counter);

  const toolbar = document.createElement('div');
  toolbar.className = 'comic-toolbar';
  const rtlBtn = document.createElement('button');
  rtlBtn.type = 'button';
  rtlBtn.className = 'comic-toggle';
  rtlBtn.title = 'Right-to-left page progression (manga)';
  const spreadBtn = document.createElement('button');
  spreadBtn.type = 'button';
  spreadBtn.className = 'comic-toggle';
  spreadBtn.title = 'Two-page spread layout';
  const refreshToolbar = () => {
    rtlBtn.textContent = prefs.rtl ? 'RTL ✓' : 'LTR';
    rtlBtn.classList.toggle('active', prefs.rtl);
    spreadBtn.textContent = prefs.spread ? 'Spread ✓' : 'Single';
    spreadBtn.classList.toggle('active', prefs.spread);
  };
  refreshToolbar();
  rtlBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    prefs.rtl = !prefs.rtl;
    stage.classList.toggle('rtl', prefs.rtl);
    setComicPrefs(book.id, prefs);
    refreshToolbar();
    renderComicPage();
  });
  spreadBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    prefs.spread = !prefs.spread;
    stage.classList.toggle('spread', prefs.spread);
    imgRight.hidden = !prefs.spread;
    setComicPrefs(book.id, prefs);
    refreshToolbar();
    renderComicPage();
  });
  toolbar.appendChild(rtlBtn);
  toolbar.appendChild(spreadBtn);
  area.appendChild(toolbar);

  stage.addEventListener('click', (e) => {
    if (e.target.closest('.comic-toolbar')) return;
    const rect = stage.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const leftHalf = x < rect.width / 2;
    const step = prefs.rtl ? (leftHalf ? +1 : -1) : (leftHalf ? -1 : +1);
    comicStepPage(step);
  });

  currentReaderHandle = {
    kind: 'comic',
    book,
    page: startPage,
    total: pages.count,
    imgLeft,
    imgRight,
    counter,
    prefs,

    prefetched: {},
  };
  renderComicPage();
}

function renderComicPage() {
  const h = currentReaderHandle;
  if (!h || h.kind !== 'comic') return;
  const pageUrl = (n) => `/api/books/${h.book.id}/comic-page/${n}`;

  h.imgLeft.src = pageUrl(h.page);
  if (h.prefs.spread && h.page + 1 < h.total) {
    h.imgRight.src = pageUrl(h.page + 1);
    h.imgRight.hidden = false;
  } else {
    h.imgRight.hidden = true;
  }

  if (h.prefs.spread && h.page + 1 < h.total) {
    h.counter.textContent = `${h.page + 1}-${h.page + 2} / ${h.total}`;
  } else {
    h.counter.textContent = `${h.page + 1} / ${h.total}`;
  }

  const percent = h.total > 0 ? (h.page + 1) / h.total : 0;
  scheduleLocationSave(h.book.id, { location: String(h.page), percent });

  const step = h.prefs.spread ? 2 : 1;
  for (let i = 1; i <= 2; i++) {
    const ahead = h.page + step * i;
    if (ahead >= h.total || h.prefetched[ahead]) continue;
    const p = new Image();
    p.src = pageUrl(ahead);
    h.prefetched[ahead] = p;
  }
}

function comicStepPage(delta) {
  const h = currentReaderHandle;
  if (!h || h.kind !== 'comic') return;

  const step = h.prefs && h.prefs.spread ? 2 : 1;
  const next = h.page + delta * step;
  if (next < 0 || next >= h.total) return;
  h.page = next;
  renderComicPage();
}

async function fetchSavedLocation(bookId) {
  try {
    const r = await fetch(`/api/books/${bookId}/location`);
    if (!r.ok) return null;
    return await r.json();
  } catch {
    return null;
  }
}

function scheduleLocationSave(bookId, payload) {
  pendingLocationBookId = bookId;
  pendingLocationPayload = payload;
  if (pendingLocationTimer) clearTimeout(pendingLocationTimer);
  pendingLocationTimer = setTimeout(flushPendingLocation, 800);
}

function flushPendingLocation() {
  if (pendingLocationTimer) { clearTimeout(pendingLocationTimer); pendingLocationTimer = null; }
  if (!pendingLocationBookId || !pendingLocationPayload) return;
  const id = pendingLocationBookId;
  const payload = pendingLocationPayload;
  pendingLocationBookId = null;
  pendingLocationPayload = null;

  fetch(`/api/books/${id}/location`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
    keepalive: true,
  }).catch((err) => console.warn('location save:', err));
}

async function autoMarkReading(book) {
  if (book.read_status !== 'unread') return;
  try {
    await fetch(`/api/books/${book.id}/status`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'reading' }),
    });
  } catch (err) {
    console.warn('auto-mark reading:', err);
  }
}

$('#library-grid').addEventListener('click', onLibraryClick);
loadFacets();
refresh();
