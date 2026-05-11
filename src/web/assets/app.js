// booktool web UI — vanilla JS, no build step.
//
// State shape:
//   view: 'all' | 'missing' | 'duplicates'
//   layout: 'gallery' | 'list'
//   query: search term
//   books: visible array (or [] in duplicates view)
//   groups: duplicate groups
//   selectedId: focused book in the detail panel
//   selection: Set<id> for multi-select
//   editing: bool — detail panel is in edit mode

const $ = (sel) => document.querySelector(sel);

const state = {
  view: 'all',
  layout: 'gallery',
  query: '',
  books: [],
  groups: [],
  selectedId: null,
  selection: new Set(),
  editing: false,
  currentBook: null,
};

// ---- Toasts -----------------------------------------------------------

let toastTimer = null;
function toast(msg, kind) {
  const el = $('#toast');
  el.textContent = msg;
  el.classList.toggle('error', kind === 'error');
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
}

// ---- Tabs / layout / search ------------------------------------------

document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.view = btn.dataset.view;
    clearSelection();
    refresh();
  });
});

document.querySelectorAll('.layout').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.layout').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.layout = btn.dataset.layout;
    $('#library').dataset.layout = state.layout;
    render();
  });
});

$('#search').addEventListener('input', (e) => {
  state.query = e.target.value.trim().toLowerCase();
  render();
});

// ---- Data fetch -------------------------------------------------------

async function refresh() {
  const grid = $('#library-grid');
  grid.innerHTML = '<p style="color:var(--fg-dim);padding:24px">loading…</p>';
  try {
    if (state.view === 'duplicates') {
      state.groups = await fetch('/api/duplicates').then(r => r.json());
      state.books = state.groups.flatMap(g => g.books);
    } else {
      const url = state.view === 'missing' ? '/api/missing' : '/api/books';
      state.books = await fetch(url).then(r => r.json());
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

// ---- Render -----------------------------------------------------------

function render() {
  const grid = $('#library-grid');
  grid.innerHTML = '';
  $('#library-empty').hidden = state.books.length > 0;

  if (state.view === 'duplicates' && state.groups.length > 0) {
    for (const g of state.groups) grid.appendChild(dupGroupEl(g));
    return;
  }

  const q = state.query;
  const filtered = q
    ? state.books.filter(b =>
        (b.title || '').toLowerCase().includes(q) ||
        (b.author_sort || '').toLowerCase().includes(q))
    : state.books;

  for (const b of filtered) grid.appendChild(bookCard(b));
}

function bookCard(b) {
  const card = document.createElement('div');
  card.className = 'book-card';
  if (b.id === state.selectedId) card.classList.add('active');
  if (state.selection.has(b.id)) card.classList.add('selected');
  card.dataset.id = b.id;

  const checkbox = document.createElement('div');
  checkbox.className = 'select-checkbox';
  checkbox.innerHTML = state.selection.has(b.id) ? '✓' : '';
  checkbox.title = 'Select for bulk actions';
  checkbox.addEventListener('click', (e) => {
    e.stopPropagation();
    toggleSelect(b.id);
  });
  card.appendChild(checkbox);

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
  document.querySelectorAll(`.book-card[data-id="${id}"]`).forEach(c => {
    c.classList.toggle('selected', state.selection.has(id));
    const cb = c.querySelector('.select-checkbox');
    if (cb) cb.innerHTML = state.selection.has(id) ? '✓' : '';
  });
  updateSelectionBar();
}

function clearSelection() {
  state.selection.clear();
  document.querySelectorAll('.book-card.selected').forEach(c => {
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
    const result = await fetch('/api/books/bulk/enrich', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ids }),
    }).then(r => r.json());
    toast(`Enriched ${result.enriched}, no match ${result.no_match}, errors ${result.errors}`);
    clearSelection();
    await refresh();
  } catch (err) {
    toast('enrich failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Enrich all';
  }
});

$('#bulk-delete').addEventListener('click', async () => {
  const ids = [...state.selection];
  if (!confirm(`Delete ${ids.length} book(s) from the catalog?\nFiles on disk will NOT be removed.`)) return;
  const btn = $('#bulk-delete');
  btn.disabled = true; btn.textContent = 'Deleting…';
  try {
    const result = await fetch('/api/books/bulk/delete', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ids, remove_files: false }),
    }).then(r => r.json());
    toast(`Deleted ${result.deleted} entries`);
    clearSelection();
    if (state.selectedId && ids.includes(state.selectedId)) closeDetail();
    await refresh();
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
  document.querySelectorAll('.book-card.active').forEach(r => r.classList.remove('active'));
  document.querySelectorAll(`.book-card[data-id="${id}"]`).forEach(c => c.classList.add('active'));

  const body = $('#detail-body');
  $('#detail').hidden = false;
  body.innerHTML = '<p style="color:var(--fg-dim)">loading…</p>';

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

  if (state.editing) {
    info.appendChild(editForm(b));
  } else {
    info.appendChild(readonlyView(b));
  }
  body.appendChild(info);

  if (!state.editing && b.description) {
    const desc = document.createElement('div');
    desc.className = 'description';
    desc.innerHTML = b.description;
    body.appendChild(desc);
  }

  const path = document.createElement('div');
  path.className = 'path-line';
  path.textContent = b.path;
  body.appendChild(path);
}

function readonlyView(b) {
  const wrap = document.createElement('div');
  const title = document.createElement('h1');
  title.textContent = b.title || '(untitled)';
  const authorLine = document.createElement('div');
  authorLine.className = 'author-line';
  authorLine.textContent = (b.authors || []).join('; ') || b.author_sort || 'unknown author';
  wrap.append(title, authorLine);

  const fields = document.createElement('div');
  for (const [label, val] of [
    ['Series', b.series ? `${b.series}${b.series_index ? ' #' + b.series_index : ''}` : null],
    ['Year', b.year],
    ['Publisher', b.publisher],
    ['Language', b.language],
    ['ISBN', b.isbn],
    ['Format', b.format],
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
      if (inp.value !== '' && inp.value !== String(b[k] ?? '')) {
        update[k] = inp.value;
      }
    }
    if (Object.keys(update).length === 0) {
      toast('nothing changed');
      state.editing = false;
      renderDetail(b);
      return;
    }
    try {
      const fresh = await fetch(`/api/books/${b.id}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(update),
      }).then(r => r.json());
      state.currentBook = fresh;
      state.editing = false;
      renderDetail(fresh);
      refresh(); // pick up new fields in the gallery
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
  trigger.onclick = (e) => {
    e.stopPropagation();
    menu.classList.toggle('open');
  };
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
          method: 'POST',
          headers: { 'content-type': 'application/json' },
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
  btn.disabled = true;
  btn.textContent = 'Fetching…';
  try {
    const r = await fetch(`/api/books/${b.id}/enrich`, { method: 'POST' }).then(r => r.json());
    if (r.enriched) {
      state.currentBook = r.book;
      renderDetail(r.book);
      refresh();
      toast('updated from Open Library');
    } else {
      toast('no match on Open Library');
    }
  } catch (err) {
    toast('enrich failed: ' + err.message, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Fetch info';
  }
}

async function doDelete(b, btn) {
  if (!confirm(`Delete "${b.title || b.path}" from the catalog?`)) return;
  const alsoFile = confirm('Also delete the file on disk?');
  btn.disabled = true;
  btn.textContent = 'Deleting…';
  try {
    const url = `/api/books/${b.id}` + (alsoFile ? '?file=1' : '');
    await fetch(url, { method: 'DELETE' });
    closeDetail();
    refresh();
    toast(alsoFile ? 'deleted (catalog + file)' : 'deleted from catalog');
  } catch (err) {
    toast('delete failed: ' + err.message, 'error');
    btn.disabled = false;
    btn.textContent = 'Delete';
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
      method: 'POST',
      headers: { 'content-type': 'application/json' },
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
  document.querySelectorAll('.book-card.active').forEach(r => r.classList.remove('active'));
}

function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ---- Reader overlay ---------------------------------------------------

let currentRendition = null;

function openReader(book) {
  $('#reader-overlay').hidden = false;
  const area = $('#reader-area');
  area.innerHTML = '';

  const ebook = ePub(`/api/books/${book.id}/file`);
  currentRendition = ebook.renderTo(area, {
    width: '100%',
    height: '100%',
    flow: 'paginated',
  });
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

refresh();
