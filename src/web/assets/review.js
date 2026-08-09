fetch('/api/plan').then(r=>r.json()).then(p=>{
  document.getElementById('app').textContent = (p.groups||[]).length + ' groups';
});
