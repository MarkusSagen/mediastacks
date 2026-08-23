// shelve — organizer web app (slice 1: shell + Organize flow).
"use strict";
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

let currentPlan = null;

// ── theme ──────────────────────────────────────────────────────────
(function initTheme() {
  let t = null;
  try { t = localStorage.getItem("shelve-theme"); } catch {}
  if (t === "graphite") document.documentElement.setAttribute("data-theme", "graphite");
})();
$("#theme-toggle").addEventListener("click", () => {
  const el = document.documentElement;
  const dark = el.getAttribute("data-theme") === "graphite";
  if (dark) el.removeAttribute("data-theme"); else el.setAttribute("data-theme", "graphite");
  try { localStorage.setItem("shelve-theme", dark ? "paper" : "graphite"); } catch {}
});

// ── tabs ───────────────────────────────────────────────────────────
$$(".tab").forEach((tab) => tab.addEventListener("click", () => {
  const v = tab.dataset.view;
  $$(".tab").forEach((t) => t.classList.toggle("active", t === tab));
  $$(".view").forEach((s) => s.classList.toggle("active", s.dataset.view === v));
  $("#apply-bar").hidden = !(v === "organize" && currentPlan && hasWork(currentPlan));
}));

// ── toast ──────────────────────────────────────────────────────────
let toastTimer = null;
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg; el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3200);
}

// ── config → header + settings ─────────────────────────────────────
async function loadConfig() {
  try {
    const c = await (await fetch("/api/config")).json();
    $("#stats").textContent = "library: " + c.library_root;
    const rows = [
      ["library_root", c.library_root],
      ["write_tags (default)", String(c.write_tags)],
      ["write_nfo (default)", String(c.write_nfo)],
      ["id_suffix", String(c.id_suffix)],
      ["MusicBrainz", c.musicbrainz ? "on" : "off"],
      ["TMDB key", c.tmdb ? "set" : "—"],
    ];
    $("#settings").innerHTML = rows.map(([k, v]) =>
      `<div class="row"><span class="k">${esc(k)}</span><span class="v">${esc(v)}</span></div>`).join("") +
      `<p class="hint">Edit these in <code>$XDG_CONFIG_HOME/stacks/config.toml</code>. In-app editing lands in a later slice.</p>`;
  } catch {}
}

// ── organize ───────────────────────────────────────────────────────
$("#preview-btn").addEventListener("click", preview);
$("#dir").addEventListener("keydown", (e) => { if (e.key === "Enter") preview(); });

async function preview() {
  const dir = $("#dir").value.trim();
  if (!dir) { toast("Enter a folder first"); return; }
  const to = $("#to").value.trim();
  const noProbe = $("#opt-no-probe").checked;
  const btn = $("#preview-btn"); btn.disabled = true; btn.textContent = "Scanning…";
  let q = "/api/organize?dir=" + encodeURIComponent(dir);
  if (to) q += "&to=" + encodeURIComponent(to);
  if (noProbe) q += "&no_probe=1";
  try {
    const res = await fetch(q);
    if (!res.ok) { toast((await res.text()).trim() || "Scan failed"); return; }
    currentPlan = await res.json();
    renderPlan();
  } catch (e) { toast("Scan failed"); }
  finally { btn.disabled = false; btn.textContent = "Preview"; }
}

const KINDS = ["movie", "tv", "music", "audiobook", "comic", "unknown"];
function kindClass(k) { return KINDS.includes(k) ? "k-" + k : "k-unknown"; }

function hasWork(plan) {
  return plan.groups && plan.groups.some((g) => g.items && g.items.some((it) => it.op === "move" || it.op === "trash"));
}

function renderPlan() {
  const plan = currentPlan;
  const host = $("#plan");
  $("#organize-empty").hidden = true;
  if (!plan.groups || plan.groups.length === 0) {
    host.innerHTML = "";
    $("#organize-empty").hidden = false;
    $("#organize-empty").innerHTML = "Nothing to organize in that folder.";
    $("#apply-bar").hidden = true;
    return;
  }
  host.innerHTML = plan.groups.map((g, gi) => groupHtml(g, gi)).join("");

  // inline retitle
  $$(".group-title[contenteditable]").forEach((el) => {
    el.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); el.blur(); } });
    el.addEventListener("blur", () => {
      const gi = +el.closest(".group").dataset.gi;
      const title = el.textContent.trim();
      if (title && title !== plan.groups[gi].title) edit({ op: "retitle", group: gi, title });
    });
  });
  // role selects
  $$(".role-select").forEach((sel) => sel.addEventListener("change", () => {
    const item = sel.closest(".item");
    edit({ op: "set-role", group: +item.dataset.gi, item: +item.dataset.ii, role: sel.value });
  }));
  // lazy thumbs
  $$("img.thumb[data-src]").forEach((img) => {
    img.src = img.dataset.src;
    img.addEventListener("error", () => { img.remove(); });
  });

  // apply bar
  const moves = plan.groups.reduce((n, g) => n + g.items.filter((it) => it.op === "move").length, 0);
  const trashes = plan.groups.reduce((n, g) => n + g.items.filter((it) => it.op === "trash").length, 0);
  $("#apply-summary").textContent = `${moves} file(s) → library · ${trashes} to trash · ${plan.groups.length} group(s)`;
  $("#apply-bar").hidden = !hasWork(plan);
}

function groupHtml(g, gi) {
  const editable = g.kind === "tv"; // retitle currently re-parents series for tv
  const warns = (g.warnings || []).map((w) => `<div class="warn-line">⚠ ${esc(w)}</div>`).join("");
  const meta = g.year ? String(g.year) : "";
  return `<div class="group" data-gi="${gi}">
    <div class="group-head">
      <span class="kind-badge ${kindClass(g.kind)}">${esc(g.kind)}</span>
      <span class="group-title"${editable ? " contenteditable=\"true\"" : ""}>${esc(g.title)}</span>
      <span class="group-meta">${esc(meta)}</span>
    </div>
    ${warns ? `<div class="warnings">${warns}</div>` : ""}
    <div class="items">${g.items.map((it, ii) => itemHtml(it, gi, ii)).join("")}</div>
  </div>`;
}

function itemHtml(it, gi, ii) {
  const cls = it.op === "skip" ? "skip" : it.op === "trash" ? "trash" : "";
  const dst = it.dst || "(not kept)";
  const roleVal = it.role === "primary" ? "keep" : it.role === "junk" ? "trash" : it.role === "duplicate" ? "skip" : null;
  const editableRole = it.role === "primary" || it.role === "duplicate" || it.role === "junk";
  let media = "";
  if (it.media) {
    const m = it.media;
    const parts = [m.codec, m.height ? m.height + "p" : null, m.duration_s ? Math.round(m.duration_s / 60) + "m" : null].filter(Boolean);
    if (parts.length) media = `<div class="media-info">${esc(parts.join(" · "))}</div>`;
  }
  const showThumb = it.role === "primary" && it.dst;
  const thumb = showThumb
    ? `<img class="thumb" data-src="/api/thumb?src=${encodeURIComponent(it.src)}" alt="">`
    : `<div class="thumb"></div>`;
  const roleSel = editableRole
    ? `<select class="role-select">
         <option value="keep"${roleVal === "keep" ? " selected" : ""}>keep</option>
         <option value="skip"${roleVal === "skip" ? " selected" : ""}>skip</option>
         <option value="trash"${roleVal === "trash" ? " selected" : ""}>trash</option>
       </select>`
    : `<span class="hint">${esc(it.role)}</span>`;
  return `<div class="item ${cls}" data-gi="${gi}" data-ii="${ii}">
    ${thumb}
    <div class="item-body">
      <div class="dst">${esc(basename(dst))}</div>
      <div class="src">${esc(it.src)}</div>
      ${media}
    </div>
    ${roleSel}
  </div>`;
}

async function edit(op) {
  try {
    const res = await fetch("/api/edit", { method: "POST", body: JSON.stringify(op) });
    if (!res.ok) { toast("Edit rejected"); return; }
    currentPlan = await res.json();
    renderPlan();
  } catch { toast("Edit failed"); }
}

// ── apply ──────────────────────────────────────────────────────────
$("#apply-btn").addEventListener("click", async () => {
  const btn = $("#apply-btn"); btn.disabled = true; btn.textContent = "Applying…";
  let q = "/api/apply?write_tags=" + ($("#opt-write-tags").checked ? "1" : "0") +
          "&write_nfo=" + ($("#opt-write-nfo").checked ? "1" : "0");
  try {
    const res = await fetch(q, { method: "POST" });
    const r = await res.json();
    toast(`Applied — moved ${r.moved}, trashed ${r.trashed}, skipped ${r.skipped}. Undo: shelve undo`);
    currentPlan = null;
    $("#plan").innerHTML = "";
    $("#apply-bar").hidden = true;
    $("#organize-empty").hidden = false;
    $("#organize-empty").innerHTML = "Done. Enter another folder to organize.";
  } catch { toast("Apply failed"); }
  finally { btn.disabled = false; btn.textContent = "Apply"; }
});

// ── util ───────────────────────────────────────────────────────────
function basename(p) { const i = p.lastIndexOf("/"); return i < 0 ? p : p.slice(i + 1); }
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }

loadConfig();
