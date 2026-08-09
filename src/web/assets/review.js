// shelve review — renders the Plan from /api/plan, sends edit ops to
// /api/edit, applies via /api/apply. The server is the source of truth:
// every edit re-renders from the Plan it returns.

let plan = null;
const app = document.getElementById("app");
const summary = document.getElementById("summary");

function dirOf(p) { return p.slice(0, p.lastIndexOf("/")); }
function baseOf(p) { return p.slice(p.lastIndexOf("/") + 1); }

async function load() {
  plan = await (await fetch("/api/plan")).json();
  render();
}

async function edit(op) {
  const res = await fetch("/api/edit", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(op),
  });
  if (res.ok) { plan = await res.json(); render(); }
}

function roleSelect(it, gi, ii) {
  const sel = document.createElement("select");
  for (const [v, l] of [["primary", "keep"], ["skip", "skip"], ["trash", "trash"]]) {
    const o = document.createElement("option");
    o.value = v; o.textContent = l;
    if (it.role === "primary" && v === "primary") o.selected = true;
    sel.appendChild(o);
  }
  sel.onchange = () => edit({ op: "set-role", group: gi, item: ii, role: sel.value });
  return sel;
}

function render() {
  app.innerHTML = "";
  let moves = 0, trash = 0, dup = 0;
  const groups = plan.groups || [];
  groups.forEach((g, gi) => {
    const sec = document.createElement("section");
    sec.className = "group";
    const first = (g.items || []).find((it) => it.dst);
    const h = document.createElement("h2");
    h.textContent = g.title + (first ? "  →  " + dirOf(first.dst) + "/" : "");
    sec.appendChild(h);

    (g.items || []).forEach((it, ii) => {
      const row = document.createElement("div");
      row.className = "row role-" + it.role;
      if (it.role === "primary" || it.role === "sidecar") {
        moves++;
        const name = document.createElement("span");
        name.className = "name";
        name.textContent = baseOf(it.dst || "?");
        if (it.media) {
          const parts = [];
          if (it.media.codec) parts.push(it.media.codec);
          if (it.media.height) parts.push(it.media.height + "p");
          if (it.media.duration_s) parts.push(Math.round(it.media.duration_s / 60) + "m");
          if (parts.length) {
            const m = document.createElement("span");
            m.className = "media";
            m.textContent = "  · " + parts.join(" ");
            name.appendChild(m);
          }
        }
        row.appendChild(name);
        row.appendChild(roleSelect(it, gi, ii));
      } else if (it.role === "duplicate") {
        dup++;
        row.textContent = "[dup] " + baseOf(it.src) + "  (left in place)";
      } else if (it.role === "junk") {
        trash++;
        row.textContent = "[junk] " + baseOf(it.src);
      }
      sec.appendChild(row);
    });
    app.appendChild(sec);
  });

  const warns = groups.flatMap((g) => (g.warnings || []).map((w) => [g.title, w]));
  if (warns.length) {
    const wsec = document.createElement("section");
    wsec.className = "warnings";
    const h = document.createElement("h2"); h.textContent = "Warnings"; wsec.appendChild(h);
    warns.forEach(([t, w]) => {
      const d = document.createElement("div"); d.className = "warn";
      d.textContent = "[" + t + "] " + w; wsec.appendChild(d);
    });
    app.appendChild(wsec);
  }

  summary.textContent = `move=${moves} · trash=${trash} · dup=${dup}`;
}

document.getElementById("apply").onclick = async () => {
  const r = await (await fetch("/api/apply", { method: "POST" })).json();
  document.getElementById("result").textContent =
    `applied: moved=${r.moved} trashed=${r.trashed} skipped=${r.skipped} — run 'shelve undo' to revert`;
};

load();
