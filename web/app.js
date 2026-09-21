const $ = (id) => document.getElementById(id);

const state = {
  robots: [],
  busy: new Set()
};

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function terminal(message, kind = "ok") {
  const box = $("terminal");
  const p = document.createElement("p");
  const marker = kind === "error" ? "[ERR]" : kind === "wait" ? "[ ..]" : "[ OK ]";
  p.innerHTML = '<span class="' + (kind === "error" ? "" : "ok") + '">' + marker + '</span> ' + escapeHtml(message);
  box.appendChild(p);
  box.scrollTop = box.scrollHeight;
}

let toastTimer;
function toast(message, error = false) {
  const el = $("toast");
  el.textContent = message;
  el.className = "toast show" + (error ? " error" : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.className = "toast"; }, 3200);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options
  });

  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.message || "Falha de comunicação com a Central.");
  return data;
}

function renderRobots() {
  const root = $("robots");
  const empty = $("emptyState");
  root.innerHTML = "";
  $("robotCount").textContent = state.robots.length;

  if (!state.robots.length) {
    empty.hidden = false;
    return;
  }

  empty.hidden = true;

  for (const robot of state.robots) {
    const card = document.createElement("article");
    card.className = "robot-card";

    const available = Boolean(robot.enabled && robot.available);
    const busy = state.busy.has(robot.id);

    card.innerHTML = `
      <div class="robot-top">
        <span class="robot-code">:: ${escapeHtml(robot.id).toUpperCase()}</span>
        <span class="robot-badge">${escapeHtml(robot.category || "AUTOMACAO")}</span>
      </div>
      <h4>${escapeHtml(robot.name)}</h4>
      <p>${escapeHtml(robot.description || "Automação local.")}</p>
      <div class="robot-footer">
        <div class="availability ${available ? "" : "offline"}">
          <i></i>
          <span>${available ? "EXECUTÁVEL LOCALIZADO" : "NÃO CONECTADO"}</span>
        </div>
        <button class="run-btn" ${available && !busy ? "" : "disabled"}>
          ${busy ? "INICIANDO..." : "EXECUTAR"}
        </button>
      </div>
    `;

    card.querySelector(".run-btn").addEventListener("click", () => runRobot(robot));
    root.appendChild(card);
  }
}

async function runRobot(robot) {
  if (state.busy.has(robot.id)) return;

  state.busy.add(robot.id);
  renderRobots();
  terminal("executando " + robot.id + "...", "wait");

  try {
    const result = await api("/api/run", {
      method: "POST",
      body: JSON.stringify({ id: robot.id })
    });

    terminal((result.name || robot.name) + " iniciado em janela local.");
    toast(robot.name + " iniciado.");
  } catch (error) {
    terminal(error.message, "error");
    toast(error.message, true);
  } finally {
    state.busy.delete(robot.id);
    renderRobots();
  }
}

async function boot() {
  try {
    const health = await api("/api/health");
    $("nodeStatus").textContent = health.ok ? "NODE ONLINE" : "NODE DEGRADED";

    const catalog = await api("/api/robots");
    $("title").textContent = catalog.title || "CENTRAL RPA";
    $("subtitle").textContent = catalog.subtitle || "LOCAL AUTOMATION NODE // 127.0.0.1";
    state.robots = Array.isArray(catalog.robots) ? catalog.robots : [];
    renderRobots();

    terminal("catálogo carregado: " + state.robots.length + " módulo(s).");
  } catch (error) {
    $("nodeStatus").textContent = "NODE ERROR";
    terminal(error.message, "error");
    toast(error.message, true);
  }
}

function tick() {
  const now = new Date();
  $("clock").textContent = now.toLocaleTimeString("pt-BR");
  $("footerTime").textContent = now.toLocaleString("pt-BR");
}
tick();
setInterval(tick, 1000);

const canvas = $("matrix");
const ctx = canvas.getContext("2d");
const glyphs = "01アイウエオカキクケコサシスセソABCDEFGHIJKLMNOPQRSTUVWXYZ#$%&*+-";
let drops = [];
const fontSize = 15;

function resizeMatrix() {
  const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
  canvas.width = Math.floor(innerWidth * dpr);
  canvas.height = Math.floor(innerHeight * dpr);
  canvas.style.width = innerWidth + "px";
  canvas.style.height = innerHeight + "px";
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  drops = new Array(Math.ceil(innerWidth / fontSize)).fill(0).map(() => Math.random() * -80);
}
window.addEventListener("resize", resizeMatrix);
resizeMatrix();

function drawMatrix() {
  ctx.fillStyle = "rgba(2,5,3,.09)";
  ctx.fillRect(0, 0, innerWidth, innerHeight);
  ctx.fillStyle = "#39ff73";
  ctx.font = fontSize + "px Consolas";

  for (let i = 0; i < drops.length; i++) {
    const char = glyphs[Math.floor(Math.random() * glyphs.length)];
    const y = drops[i] * fontSize;
    ctx.fillText(char, i * fontSize, y);
    if (y > innerHeight && Math.random() > .975) drops[i] = Math.random() * -20;
    drops[i] += .72 + Math.random() * .22;
  }

  requestAnimationFrame(drawMatrix);
}
requestAnimationFrame(drawMatrix);

boot();
