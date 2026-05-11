// booktool web UI — vanilla JS, no build step.
//
// State shape:
//   view: 'all' | 'missing' | 'unverified' | 'duplicates'
//   layout: 'gallery' | 'list'
//   filters: server-side filter set, mirrored to /api/books query params
//   order: sort key (matches catalog.Order)
//   books, groups, selection, selectedId, editing, currentBook

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

const state = {
  view: 'all',
  layout: 'gallery',
  filters: {
    q: '', author: null, series: null, genre: null, status: null,
    format: null, year_from: null, year_to: null,
    has_isbn: null, has_cover: null, has_series: null,
  },
  order: 'author',
  books: [],
  groups: [],
  selectedId: null,
  selection: new Set(),
  editing: false,
  currentBook: null,
};

// ---- Toasts ------------------------------------------------------------

let toastTimer = null;
function toast(msg, kind) {
  const el = $('#toast');
  el.textContent = msg;
  el.classList.toggle('error', kind === 'error');
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
}

// ---- Tabs / layout / sort / search ------------------------------------

$$('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    $$('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.view = btn.dataset.view;
    clearSelection();
    refresh();
  });
});

$$('.layout').forEach(btn => {
  btn.addEventListener('click', () => {
    $$('.layout').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.layout = btn.dataset.layout;
    $('#library').dataset.layout = state.layout;
    render();
  });
});

$('#sort-select').addEventListener('change', (e) => {
  state.order = e.target.value;
  refresh();
});

let searchTimer = null;
$('#search').addEventListener('input', (e) => {
  const raw = e.target.value;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    parseSearchInto(raw, state.filters);
    refresh();
  }, 180);
});

/// Parse `text author:foo year:2010-2020 status:reading has:isbn format:epub`.
/// Plain words go into `q`; the rest set typed filters. Quote values
/// containing spaces: `author:"Last, First"`.
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

// ---- Filter helpers ---------------------------------------------------

function buildQuery() {
  const params = new URLSearchParams();
  const f = state.filters;
  if (f.q) params.set('q', f.q);
  if (f.author) params.set('author', f.author);
  if (f.series) params.set('series', f.series);
  if (f.genre) params.set('genre', f.genre);
  if (f.status) params.set('status', f.status);
  if (f.format) params.set('format', f.format);
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
    format: null, year_from: null, year_to: null,
    has_isbn: null, has_cover: null, has_series: null,
  };
  $('#search').value = '';
  refresh();
}

// ---- Data fetch -------------------------------------------------------

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
    } else {
      const qs = buildQuery().toString();
      state.books = await fetch('/api/books' + (qs ? '?' + qs : '')).then(r => r.json());
      state.groups = [];
    }
    $('#stats').textContent =
      `${state.books.length} book${state.books.length === 1 ? '' : 's'}`;
    render();
  } catch (err) {
    grid.innerHTML =
      `<p style="color:var(--danger);padding:24px">failed to load: ${err.message}</p>`;
  }
}

// ---- Facets -----------------------------------------------------------

async function loadFacets() {
  try {
    const [authors, series, genres] = await Promise.all([
      fetch('/api/authors').then(r => r.json()),
      fetch('/api/series').then(r => r.json()),
      fetch('/api/genres').then(r => r.json()),
    ]);
    renderFacetList('#facet-authors', authors, 'author');
    renderFacetList('#facet-series', series, 'series');
    renderFacetList('#facet-genres', genres, 'genre');
  } catch (err) {
    console.error('facet load failed', err);
  }
}

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
}

// ---- Active-filter chips ---------------------------------------------

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
  if (f.format) chips.push({ label: `format: ${f.format}`, clear: () => clearFilter('format') });
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

// ---- Render -----------------------------------------------------------

function render() {
  const grid = $('#library-grid');
  grid.innerHTML = '';
  $('#library-empty').hidden = state.books.length > 0;

  if (state.view === 'duplicates' && state.groups.length > 0) {
    for (const g of state.groups) grid.appendChild(dupGroupEl(g));
    return;
  }
  for (const b of state.books) grid.appendChild(bookCard(b));
}

function bookCard(b) {
  const card = document.createElement('div');
  card.className = 'book-card status-' + (b.read_status || 'unread');
  if (b.id === state.selectedId) card.classList.add('active');
  if (state.selection.has(b.id)) card.classList.add('selected');
  card.dataset.id = b.id;

  const checkbox = document.createElement('div');
  checkbox.className = 'select-checkbox';
  checkbox.innerHTML = state.selection.has(b.id) ? '✓' : '';
  checkbox.title = 'Select for bulk actions';
  checkbox.addEventListener('click', (e) => { e.stopPropagation(); toggleSelect(b.id); });
  card.appendChild(checkbox);

  const dot = document.createElement('div');
  dot.className = 'status-dot ' + (b.read_status || 'unread');
  dot.title = b.read_status || 'unread';
  card.appendChild(dot);

  const frame = document.createElement('div');
  frame.className = 'cover-frame';
  const img = document.createElement('img');
  img.className = 'thumb';
  img.loading = 'lazy';
  img.alt = b.title || '';
  img.src = `/api/books/${b.id}/cover?t=${b.updated_at || ''}`;
  img.onerror = () => {
    img.remove();
    const ph = document.createElement('span');
    ph.className = 'placeholder';
    ph.textContent = 'no cover';
    frame.appendChild(ph);
  };
  frame.appendChild(img);

  const meta = document.createElement('div');
  meta.className = 'meta';
  const title = document.createElement('div');
  title.className = 'title';
  title.textContent = b.title || b.path.split('/').pop();
  const author = document.createElement('div');
  author.className = 'author';
  author.textContent = b.author_sort || '(unknown author)';
  meta.append(title, author);

  const badges = document.createElement('div');
  badges.className = 'badges';
  badges.appendChild(badge(b.format));
  if (b.year) badges.appendChild(badge(String(b.year)));
  if (!b.isbn) badges.appendChild(badge('no isbn', 'warn'));
  if (b.series) badges.appendChild(badge(`${b.series}${b.series_index ? ' #' + b.series_index : ''}`));

  card.append(frame, meta, badges);
  card.addEventListener('click', () => selectBook(b.id));
  return card;
}

function badge(text, kind) {
  const el = document.createElement('span');
  el.className = 'badge' + (kind ? ' ' + kind : '');
  el.textContent = text;
  return el;
}

function dupGroupEl(g) {
  const box = document.createElement('div');
  box.className = 'dup-group';
  const h = document.createElement('h3');
  h.textContent = `sha256 ${g.sha256.slice(0, 12)} · ${g.books.length} copies`;
  box.appendChild(h);
  const members = document.createElement('div');
  members.className = 'members';
  members.dataset.layout = 'list';
  members.style.cssText = 'display:flex;flex-direction:column;gap:2px';
  for (const b of g.books) members.appendChild(bookCard(b));
  box.appendChild(members);
  return box;
}

// ---- Selection --------------------------------------------------------

function toggleSelect(id) {
  if (state.selection.has(id)) state.selection.delete(id);
  else state.selection.add(id);
  $$(`.book-card[data-id="${id}"]`).forEach(c => {
    c.classList.toggle('selected', state.selection.has(id));
    const cb = c.querySelector('.select-checkbox');
    if (cb) cb.innerHTML = state.selection.has(id) ? '✓' : '';
  });
  updateSelectionBar();
}

function clearSelection() {
  state.selection.clear();
  $$('.book-card.selected').forEach(c => {
    c.classList.remove('selected');
    const cb = c.querySelector('.select-checkbox');
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

// ---- Detail panel -----------------------------------------------------

async function selectBook(id) {
  state.selectedId = id;
  state.editing = false;
  $$('.book-card.active').forEach(r => r.classList.remove('active'));
  $$(`.book-card[data-id="${id}"]`).forEach(c => c.classList.add('active'));

  $('#detail').hidden = false;
  $('#detail-body').innerHTML = '<p style="color:var(--fg-dim)">loading…</p>';

  const b = await fetch(`/api/books/${id}`).then(r => r.json());
  state.currentBook = b;
  renderDetail(b);
}

function renderDetail(b) {
  const body = $('#detail-body');
  body.innerHTML = '';

  const cover = document.createElement('img');
  cover.className = 'detail-cover';
  cover.src = `/api/books/${b.id}/cover?t=${Date.now()}`;
  cover.alt = b.title || '';
  cover.onerror = () => { cover.style.display = 'none'; };
  body.appendChild(cover);

  const info = document.createElement('div');
  info.className = 'detail-info';
  info.appendChild(state.editing ? editForm(b) : readonlyView(b));
  body.appendChild(info);

  if (!state.editing && b.description) {
    const desc = document.createElement('div');
    desc.className = 'description';
    desc.innerHTML = b.description;
    body.appendChild(desc);
  }

  if (!state.editing && Array.isArray(b._alt_covers) && b._alt_covers.length > 0) {
    body.appendChild(altCoversSection(b));
  }
  if (!state.editing && Array.isArray(b._editions) && b._editions.length > 0) {
    body.appendChild(editionsSection(b));
  }

  const path = document.createElement('div');
  path.className = 'path-line';
  path.textContent = b.path;
  body.appendChild(path);
}

// Alternative covers strip. Click swaps the book's cover for EPUBs (the
// only format we can rewrite covers in today); non-EPUBs are read-only.
function altCoversSection(b) {
  const section = document.createElement('div');
  section.className = 'rich-section';
  const h = document.createElement('h3');
  h.textContent = `Alternative covers (${b._alt_covers.length})`;
  section.appendChild(h);

  const strip = document.createElement('div');
  strip.className = 'cover-strip';
  for (const url of b._alt_covers) {
    const img = document.createElement('img');
    img.src = url;
    img.loading = 'lazy';
    img.title = b.format === 'epub'
      ? 'Click to use this as the book cover'
      : 'Cover from Open Library (EPUB-only swap)';
    img.onerror = () => img.remove();
    if (b.format === 'epub') {
      img.classList.add('clickable');
      img.onclick = () => applyAltCover(b, url, img);
    }
    strip.appendChild(img);
  }
  section.appendChild(strip);
  return section;
}

async function applyAltCover(b, url, img) {
  img.classList.add('busy');
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`fetch cover: ${res.status}`);
    const blob = await res.blob();
    const bytes = await blob.arrayBuffer();
    const b64 = arrayBufferToBase64(bytes);
    const r = await fetch(`/api/books/${b.id}/cover`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ data_base64: b64 }),
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      throw new Error(err.error || `status ${r.status}`);
    }
    toast('cover replaced');
    refresh();
    if (state.currentBook?.id === b.id) renderDetail(state.currentBook);
  } catch (err) {
    toast('cover swap failed: ' + err.message, 'error');
  } finally {
    img.classList.remove('busy');
  }
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

function readonlyView(b) {
  const wrap = document.createElement('div');
  const title = document.createElement('h1');
  title.textContent = b.title || '(untitled)';
  const authorLine = document.createElement('div');
  authorLine.className = 'author-line';
  authorLine.textContent = (b.authors || []).join('; ') || b.author_sort || 'unknown author';
  wrap.append(title, authorLine);

  wrap.appendChild(statusToggle(b));

  const fields = document.createElement('div');
  for (const [label, val] of [
    ['Series', b.series ? `${b.series}${b.series_index ? ' #' + b.series_index : ''}` : null],
    ['Year', b.year],
    ['Publisher', b.publisher],
    ['Language', b.language],
    ['ISBN', b.isbn],
    ['Format', b.format],
    ['Subjects', (b.subjects || []).join(', ') || null],
    ['SHA-256', b.sha256?.slice(0, 16) + '…'],
    ['Source', b.source ? `${b.source} (conf ${b.confidence})` : null],
  ]) {
    if (val == null || val === '') continue;
    const row = document.createElement('div');
    row.className = 'field';
    row.innerHTML = `<b>${escapeHtml(label)}</b>${escapeHtml(String(val))}`;
    fields.appendChild(row);
  }
  wrap.appendChild(fields);
  wrap.appendChild(actionBar(b));
  return wrap;
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
      // Update the gallery card in place without a full reload.
      $$(`.book-card[data-id="${b.id}"]`).forEach(c => {
        c.classList.remove('status-unread', 'status-reading', 'status-finished');
        c.classList.add('status-' + fresh.read_status);
        const dot = c.querySelector('.status-dot');
        if (dot) {
          dot.classList.remove('unread', 'reading', 'finished');
          dot.classList.add(fresh.read_status);
          dot.title = fresh.read_status;
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

  const form = document.createElement('div');
  form.className = 'edit-form';
  const fields = [
    ['title', 'Title', b.title || ''],
    ['author', 'Author', b.author_sort || ''],
    ['series', 'Series', b.series || ''],
    ['series_index', 'Series #', b.series_index ?? ''],
    ['year', 'Year', b.year ?? ''],
  ];
  const inputs = {};
  for (const [key, label, value] of fields) {
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
  wrap.appendChild(form);

  const actions = document.createElement('div');
  actions.className = 'actions';
  const save = document.createElement('button');
  save.className = 'primary';
  save.textContent = 'Save';
  save.onclick = async () => {
    save.disabled = true;
    const update = {};
    for (const [k, inp] of Object.entries(inputs)) {
      if (inp.value !== '' && inp.value !== String(b[k] ?? '')) update[k] = inp.value;
    }
    if (Object.keys(update).length === 0) {
      toast('nothing changed');
      state.editing = false;
      renderDetail(b);
      return;
    }
    try {
      const fresh = await fetch(`/api/books/${b.id}`, {
        method: 'PATCH', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(update),
      }).then(r => r.json());
      state.currentBook = fresh;
      state.editing = false;
      renderDetail(fresh);
      refresh();
      loadFacets();
      toast('saved');
    } catch (err) {
      toast('save failed: ' + err.message, 'error');
    } finally {
      save.disabled = false;
    }
  };
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
  if (b.format === 'epub') {
    const read = document.createElement('button');
    read.className = 'primary';
    read.textContent = 'Read';
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

  if (b.format === 'epub') {
    const cov = document.createElement('button');
    cov.textContent = 'Change cover';
    cov.onclick = () => uploadCover(b);
    actions.appendChild(cov);
  }
  actions.appendChild(convertMenu(b));

  const del = document.createElement('button');
  del.style.cssText = 'border-color:var(--danger);color:var(--danger)';
  del.textContent = 'Delete';
  del.onclick = () => doDelete(b, del);
  actions.appendChild(del);
  return actions;
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
      trigger.disabled = true;
      trigger.textContent = `Converting → ${fmt}…`;
      try {
        const r = await fetch(`/api/books/${b.id}/convert`, {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ to: fmt }),
        }).then(r => r.json());
        if (r.ok) toast(`converted → ${r.path}`);
        else toast(r.error || 'convert failed', 'error');
      } catch (err) {
        toast('convert failed: ' + err.message, 'error');
      } finally {
        trigger.disabled = false;
        trigger.textContent = 'Convert ▾';
      }
    };
    list.appendChild(opt);
  }
  menu.appendChild(list);
  return menu;
}

async function doEnrich(b, btn) {
  btn.disabled = true; btn.textContent = 'Fetching…';
  try {
    const r = await fetch(`/api/books/${b.id}/enrich`, { method: 'POST' }).then(r => r.json());
    if (r.enriched) {
      // Underscore-prefixed fields are work-level extras returned by the
      // rich enrich path. They aren't persisted on the catalog row, just
      // attached here so renderDetail can surface them in this session.
      const enriched = r.book;
      enriched._alt_covers = r.alt_covers || [];
      enriched._editions = r.editions || [];
      enriched._work_key = r.work_key || null;
      state.currentBook = enriched;
      renderDetail(enriched);
      refresh();
      loadFacets();
      toast(`Open Library: ${enriched._alt_covers.length} covers, ${enriched._editions.length} editions`);
    } else {
      toast('no match on Open Library');
    }
  } catch (err) {
    toast('enrich failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Fetch info';
  }
}

async function doDelete(b, btn) {
  if (!confirm(`Delete "${b.title || b.path}" from the catalog?`)) return;
  const alsoFile = confirm('Also delete the file on disk?');
  btn.disabled = true; btn.textContent = 'Deleting…';
  try {
    const url = `/api/books/${b.id}` + (alsoFile ? '?file=1' : '');
    await fetch(url, { method: 'DELETE' });
    closeDetail();
    refresh();
    loadFacets();
    toast(alsoFile ? 'deleted (catalog + file)' : 'deleted from catalog');
  } catch (err) {
    toast('delete failed: ' + err.message, 'error');
    btn.disabled = false; btn.textContent = 'Delete';
  }
}

// ---- Cover upload -----------------------------------------------------

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

// ---- Detail close -----------------------------------------------------

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

// ---- Reader overlay ---------------------------------------------------

let currentRendition = null;
function openReader(book) {
  $('#reader-overlay').hidden = false;
  const area = $('#reader-area');
  area.innerHTML = '';
  const ebook = ePub(`/api/books/${book.id}/file`);
  currentRendition = ebook.renderTo(area, { width: '100%', height: '100%', flow: 'paginated' });
  currentRendition.display();
  document.addEventListener('keydown', readerKeys);
}
function closeReader() {
  $('#reader-overlay').hidden = true;
  currentRendition = null;
  document.removeEventListener('keydown', readerKeys);
}
function readerKeys(e) {
  if (e.key === 'Escape') closeReader();
  else if (e.key === 'ArrowLeft') currentRendition?.prev();
  else if (e.key === 'ArrowRight') currentRendition?.next();
}
$('#reader-close').addEventListener('click', closeReader);
$('#reader-prev').addEventListener('click', () => currentRendition?.prev());
$('#reader-next').addEventListener('click', () => currentRendition?.next());

// ---- Boot -------------------------------------------------------------

loadFacets();
refresh();
