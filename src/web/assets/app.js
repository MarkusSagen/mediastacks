// booktool web UI — vanilla JS, no build.
// Data flow: fetch /api/books or /api/missing or /api/duplicates,
// render a list on the left, click a row to populate the detail pane,
// click "Read" to open the embedded epub.js reader overlay.

const state = {
  view: 'all',          // 'all' | 'missing' | 'duplicates'
  query: '',
  books: [],            // current list
  selectedId: null,
};

const $ = (sel) => document.querySelector(sel);

// ---- View routing ------------------------------------------------------

document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.view = btn.dataset.view;
    refresh();
  });
});

$('#search').addEventListener('input', (e) => {
  state.query = e.target.value.trim().toLowerCase();
  renderList();
});

async function refresh() {
  const list = $('#list');
  list.classList.add('loading');
  list.innerHTML = '';
  try {
    if (state.view === 'duplicates') {
      const groups = await fetch('/api/duplicates').then(r => r.json());
      state.books = [];
      renderDuplicates(groups);
    } else {
      const url = state.view === 'missing' ? '/api/missing' : '/api/books';
      state.books = await fetch(url).then(r => r.json());
      renderList();
    }
    $('#stats').textContent = `${state.books.length} book${state.books.length === 1 ? '' : 's'}`;
  } catch (err) {
    list.innerHTML = `<p class="hint">failed to load: ${err.message}</p>`;
  } finally {
    list.classList.remove('loading');
  }
}

// ---- Rendering ---------------------------------------------------------

function renderList() {
  const list = $('#list');
  list.innerHTML = '';
  const q = state.query;
  const filtered = q
    ? state.books.filter(b =>
        (b.title || '').toLowerCase().includes(q) ||
        (b.author_sort || '').toLowerCase().includes(q))
    : state.books;
  for (const b of filtered) list.appendChild(rowEl(b));
}

function rowEl(b) {
  const row = document.createElement('div');
  row.className = 'book-row';
  if (b.id === state.selectedId) row.classList.add('active');

  const img = document.createElement('img');
  img.className = 'thumb';
  img.loading = 'lazy';
  img.src = `/api/books/${b.id}/cover`;
  img.onerror = () => { img.style.visibility = 'hidden'; };

  const meta = document.createElement('div');
  meta.className = 'meta';

  const title = document.createElement('div');
  title.className = 'title';
  title.textContent = b.title || b.path.split('/').pop();

  const author = document.createElement('div');
  author.className = 'author';
  author.textContent = b.author_sort || '(unknown author)';

  const badges = document.createElement('div');
  badges.className = 'badges';
  badges.appendChild(badge(b.format));
  if (b.year) badges.appendChild(badge(String(b.year)));
  if (!b.isbn) badges.appendChild(badge('no isbn', 'warn'));
  if (b.series) badges.appendChild(badge(`${b.series}${b.series_index ? ' #' + b.series_index : ''}`));

  meta.append(title, author, badges);
  row.append(img, meta);
  row.addEventListener('click', () => selectBook(b.id));
  return row;
}

function badge(text, kind) {
  const el = document.createElement('span');
  el.className = 'badge' + (kind ? ' ' + kind : '');
  el.textContent = text;
  return el;
}

function renderDuplicates(groups) {
  const list = $('#list');
  list.innerHTML = '';
  if (groups.length === 0) {
    list.innerHTML = '<p class="hint" style="padding:20px">No duplicates.</p>';
    return;
  }
  for (const g of groups) {
    const box = document.createElement('div');
    box.className = 'dup-group';
    const h = document.createElement('h3');
    h.textContent = `sha256 ${g.sha256.slice(0, 12)} · ${g.books.length} copies`;
    box.append(h);
    for (const b of g.books) box.appendChild(rowEl(b));
    list.appendChild(box);
  }
}

// ---- Detail pane -------------------------------------------------------

async function selectBook(id) {
  state.selectedId = id;
  document.querySelectorAll('.book-row.active').forEach(r => r.classList.remove('active'));
  // Find and highlight the row.
  for (const r of document.querySelectorAll('.book-row')) {
    const title = r.querySelector('.title')?.textContent;
    if (title && state.books.find(b => b.id === id && (b.title || '').includes(title))) {
      r.classList.add('active');
      break;
    }
  }

  const detail = $('#detail');
  detail.classList.remove('empty');
  detail.innerHTML = '<p class="hint">loading…</p>';

  const b = await fetch(`/api/books/${id}`).then(r => r.json());

  detail.innerHTML = '';
  const head = document.createElement('div');
  head.className = 'detail-head';

  const cover = document.createElement('img');
  cover.className = 'detail-cover';
  cover.src = `/api/books/${id}/cover`;
  cover.onerror = () => { cover.style.visibility = 'hidden'; };

  const info = document.createElement('div');
  info.className = 'detail-info';

  const title = document.createElement('h1');
  title.textContent = b.title || '(untitled)';

  const authorLine = document.createElement('div');
  authorLine.className = 'author-line';
  authorLine.textContent = (b.authors || []).join('; ') || b.author_sort || 'unknown author';

  const fields = document.createElement('div');
  for (const [label, val] of [
    ['Series', b.series ? `${b.series}${b.series_index ? ' #' + b.series_index : ''}` : null],
    ['Year', b.year],
    ['Publisher', b.publisher],
    ['Language', b.language],
    ['ISBN', b.isbn],
    ['Format', b.format],
    ['SHA-256', b.sha256?.slice(0, 16) + '…'],
    ['Source', b.source ? `${b.source} (confidence ${b.confidence})` : null],
  ]) {
    if (val == null || val === '') continue;
    const row = document.createElement('div');
    row.className = 'field';
    row.innerHTML = `<b>${label}</b>${val}`;
    fields.appendChild(row);
  }

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

  info.append(title, authorLine, fields, actions);
  head.append(cover, info);
  detail.appendChild(head);

  if (b.description) {
    const desc = document.createElement('div');
    desc.className = 'description';
    desc.innerHTML = b.description;
    detail.appendChild(desc);
  }

  const pathLine = document.createElement('div');
  pathLine.className = 'path-line';
  pathLine.textContent = b.path;
  detail.appendChild(pathLine);
}

// ---- Reader overlay ----------------------------------------------------

let currentRendition = null;

function openReader(book) {
  const overlay = $('#reader-overlay');
  overlay.hidden = false;
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

refresh();
