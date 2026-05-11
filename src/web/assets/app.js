// booktool web UI — vanilla JS, no build step.
//
// Fetches /api/books (or /missing, /duplicates), renders a covers
// gallery (default) or a list, and shows a detail panel with cover,
// metadata, and download/read actions on selection.

const $ = (sel) => document.querySelector(sel);

const state = {
  view: 'all',        // 'all' | 'missing' | 'duplicates'
  layout: 'gallery',  // 'gallery' | 'list'
  query: '',
  books: [],          // flat list of currently visible books
  groups: [],         // duplicate groups (when view === 'duplicates')
  selectedId: null,
};

// ---- View / layout switches -------------------------------------------

document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.view = btn.dataset.view;
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
  card.dataset.id = b.id;

  const frame = document.createElement('div');
  frame.className = 'cover-frame';
  const img = document.createElement('img');
  img.className = 'thumb';
  img.loading = 'lazy';
  img.alt = b.title || '';
  img.src = `/api/books/${b.id}/cover`;
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
  // Duplicates listing always renders as a flat list for clarity, even
  // when the gallery layout is active.
  members.dataset.layout = 'list';
  members.style.cssText = 'display:flex;flex-direction:column;gap:2px';
  for (const b of g.books) members.appendChild(bookCard(b));
  box.appendChild(members);
  return box;
}

// ---- Detail panel -----------------------------------------------------

async function selectBook(id) {
  state.selectedId = id;
  document.querySelectorAll('.book-card.active').forEach(r => r.classList.remove('active'));
  document.querySelectorAll(`.book-card[data-id="${id}"]`).forEach(c => c.classList.add('active'));

  const detail = $('#detail');
  detail.hidden = false;
  const body = $('#detail-body');
  body.innerHTML = '<p style="color:var(--fg-dim)">loading…</p>';

  const b = await fetch(`/api/books/${id}`).then(r => r.json());
  body.innerHTML = '';

  const cover = document.createElement('img');
  cover.className = 'detail-cover';
  cover.src = `/api/books/${id}/cover`;
  cover.alt = b.title || '';
  cover.onerror = () => { cover.style.display = 'none'; };
  body.appendChild(cover);

  const info = document.createElement('div');
  info.className = 'detail-info';

  const title = document.createElement('h1');
  title.textContent = b.title || '(untitled)';
  const authorLine = document.createElement('div');
  authorLine.className = 'author-line';
  authorLine.textContent = (b.authors || []).join('; ') || b.author_sort || 'unknown author';
  info.append(title, authorLine);

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
    row.innerHTML = `<b>${label}</b>${escapeHtml(String(val))}`;
    fields.appendChild(row);
  }
  info.appendChild(fields);

  const actions = document.createElement('div');
  actions.className = 'actions';
  if (b.format === 'epub') {
    const readBtn = document.createElement('button');
    readBtn.className = 'primary';
    readBtn.textContent = 'Read';
    readBtn.onclick = () => openReader(b);
    actions.appendChild(readBtn);
  }
  const dlBtn = document.createElement('button');
  dlBtn.textContent = 'Download';
  dlBtn.onclick = () => { window.location.href = `/api/books/${id}/file`; };
  actions.appendChild(dlBtn);
  info.appendChild(actions);

  body.appendChild(info);

  if (b.description) {
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

$('#detail-close').addEventListener('click', () => {
  $('#detail').hidden = true;
  state.selectedId = null;
  document.querySelectorAll('.book-card.active').forEach(r => r.classList.remove('active'));
});

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
