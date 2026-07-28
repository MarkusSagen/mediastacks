// Tiny Playwright smoke test for the booktool web UI.
//
// Runs against a `booktool serve` already listening on $BOOKTOOL_TEST_URL
// (defaults to http://127.0.0.1:8899). The shell script
// scripts/smoke-ui.sh starts the server, runs this, and cleans up.
//
// What it verifies:
//   • SPA loads with zero console errors.
//   • The Library card + Add books / Import / Export buttons exist.
//   • The ⌘K palette opens and renders >= 15 commands.
//   • The first /api/books row is fetchable.
//   • If a CBZ exists, the comic reader opens and renders a page.
//
// Intentionally NOT pixel-perfect — that's foliate's job. The goal is
// to catch wiring regressions (missing endpoint, JS exception, layout
// blowing up) that the curl-level smokes miss.

import { chromium } from 'playwright';

const URL = process.env.BOOKTOOL_TEST_URL || 'http://127.0.0.1:8899';
const HEADLESS = process.env.HEADLESS !== '0';

const errors = [];
const failures = [];
let passed = 0;

function check(label, ok, detail) {
  if (ok) {
    console.log(`  PASS  ${label}`);
    passed++;
  } else {
    console.log(`  FAIL  ${label}${detail ? ' — ' + detail : ''}`);
    failures.push(label);
  }
}

const browser = await chromium.launch({ headless: HEADLESS });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const page = await ctx.newPage();
page.on('pageerror', (err) => errors.push('pageerror: ' + err.message));
page.on('console', (msg) => {
  if (msg.type() === 'error') errors.push('console: ' + msg.text());
});

console.log(`== smoke-ui against ${URL} ==`);

await page.goto(URL, { waitUntil: 'networkidle' });

const title = await page.title();
check('page title is "booktool"', title === 'booktool', `got "${title}"`);

check('zero console errors after load', errors.length === 0, errors.slice(0, 2).join(' | '));

// Library card present + the 4 primary buttons.
check('Library card rendered', await page.locator('.library-card').count() > 0);
check('Add books button present', await page.locator('#add-books-btn').count() > 0);
check('Import button present', await page.locator('#import-btn').count() > 0);
check('Export button present', await page.locator('#export-btn').count() > 0);
check('Rescan-all button present', await page.locator('#rescan-all-btn').count() > 0);

// ⌘K palette.
const cmdkInfo = await page.evaluate(() => {
  openCmdk();
  const items = Array.from(document.querySelectorAll('#cmdk-list li'));
  const out = { count: items.length, hasImport: items.some(li => /Import library/.test(li.textContent)) };
  closeCmdk();
  return out;
});
check('⌘K palette renders >= 15 commands', cmdkInfo.count >= 15, `got ${cmdkInfo.count}`);
check('⌘K has "Import library" command', cmdkInfo.hasImport);

// /api/books reachable.
const booksRes = await page.evaluate(async () => {
  const r = await fetch('/api/books');
  return { status: r.status, count: (await r.json()).length };
});
check('GET /api/books returns 200', booksRes.status === 200);
check('catalog has at least 1 book', booksRes.count > 0, `got ${booksRes.count}`);

// Comic reader: only if a CBZ is in the catalog.
const cbz = await page.evaluate(async () => {
  const list = await fetch('/api/books?format=cbz').then(r => r.json());
  return list[0] || null;
});
if (cbz) {
  const comicResult = await page.evaluate(async (id) => {
    const list = await fetch('/api/books?format=cbz').then(r => r.json());
    const book = list.find(b => b.id === id);
    // Clean prefs so test is reproducible.
    localStorage.removeItem(`booktool.comic.prefs.${id}`);
    await openReader(book);
    await new Promise(r => setTimeout(r, 600));
    const counter = document.querySelector('.comic-counter');
    const toolbar = document.querySelector('.comic-toolbar');
    const out = {
      counter: counter ? counter.textContent : null,
      hasToolbar: !!toolbar,
    };
    closeReader();
    return out;
  }, cbz.id);
  check('Comic reader renders page counter', /^1 \/ \d+$/.test(comicResult.counter || ''),
    `got "${comicResult.counter}"`);
  check('Comic reader toolbar (RTL/spread) present', comicResult.hasToolbar);
}

// Responsive — narrow viewport surfaces the hamburger.
await page.setViewportSize({ width: 390, height: 844 });
await page.waitForTimeout(100);
const hamburgerVisible = await page.evaluate(() => {
  const btn = document.querySelector('#sidebar-toggle');
  return btn && getComputedStyle(btn).display !== 'none';
});
check('Mobile hamburger visible at 390px', !!hamburgerVisible);

await page.setViewportSize({ width: 1400, height: 900 });
await page.waitForTimeout(100);
const hamburgerHidden = await page.evaluate(() => {
  const btn = document.querySelector('#sidebar-toggle');
  return btn && getComputedStyle(btn).display === 'none';
});
check('Hamburger hidden at 1400px', !!hamburgerHidden);

await browser.close();

console.log(`\n  ${passed} passed, ${failures.length} failed`);
if (errors.length > 0) {
  console.log(`  (${errors.length} console/page errors)`);
  for (const e of errors.slice(0, 5)) console.log('    - ' + e);
}
if (failures.length > 0) process.exit(1);
