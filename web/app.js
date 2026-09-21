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

    const installed = Boolean(robot.installed);
    const stateLabel = installed
      ? "ACOPLADO LOCALMENTE"
      : robot.installable
        ? "PRONTO PARA ACOPLAR"
        : "NÃO DISPONÍVEL";

    card.innerHTML = `
      <div class="robot-top">
        <div class="robot-identity">
          <div class="robot-icon" aria-hidden="true">${escapeHtml(robot.symbol || ">_")}</div>
          <div>
            <span class="robot-code">:: ${escapeHtml(robot.id).toUpperCase()}</span>
            <h4>${escapeHtml(robot.name)}</h4>
          </div>
        </div>
        <span class="robot-badge">${escapeHtml(robot.category || "AUTOMACAO")}</span>
      </div>
      <p>${escapeHtml(robot.description || "Automação local.")}</p>
      <div class="robot-footer">
        <div class="availability ${available ? "" : "offline"}">
          <i></i>
          <span>${stateLabel}</span>
        </div>
        <button class="run-btn" ${available && !busy ? "" : "disabled"}>
          ${busy ? (installed ? "INICIANDO..." : "ACOPLANDO...") : "EXECUTAR"}
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

    try {
      const catalog = await api("/api/robots");
      state.robots = Array.isArray(catalog.robots) ? catalog.robots : state.robots;
    } catch (_) {}
  } catch (error) {
    terminal(error.message, "error");
    toast(error.message, true);
  } finally {
    state.busy.delete(robot.id);
    renderRobots();
  }
}

function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (!value) return "";
  if (value < 1024 * 1024) return Math.max(1, Math.round(value / 1024)) + " KB";
  return (value / (1024 * 1024)).toFixed(1).replace(".", ",") + " MB";
}

async function loadResources() {
  const card = $("scaleDownloadCard");
  if (!card) return;

  try {
    const resources = await api("/api/resources");
    const scale = resources.scale || {};
    const description = $("scaleDownloadDescription");
    const action = $("scaleDownloadAction");

    if (scale.available) {
      card.classList.remove("resource-disabled");
      card.setAttribute("aria-disabled", "false");
      card.href = scale.downloadUrl || "/download/escala-folgas";
      description.textContent = "Arquivo Excel com macros" + (scale.sizeBytes ? " • " + formatBytes(scale.sizeBytes) : "") + ".";
      action.textContent = "BAIXAR";
    } else {
      card.classList.add("resource-disabled");
      card.setAttribute("aria-disabled", "true");
      card.href = "#";
      description.textContent = "Arquivo Excel com macros. Adicione Escala de Folgas.xlsm à pasta downloads.";
      action.textContent = "INDISPONÍVEL";
    }

    const adherence = resources.adherence || {};
    const adherenceCard = $("adherenceAppCard");
    const adherenceDescription = $("adherenceAppDescription");
    const adherenceAction = $("adherenceAppAction");

    if (adherenceCard) {
      adherenceCard.href = adherence.openUrl || "/apps/aderencia-escala/";
      adherenceCard.classList.remove("resource-disabled");
      adherenceCard.setAttribute("aria-disabled", "false");

      if (adherence.installed) {
        adherenceDescription.textContent = "Aplicação local acoplada • análise de ponto × escala.";
        adherenceAction.textContent = "ABRIR";
      } else {
        adherenceDescription.textContent = "Cruza ponto × escala. Primeiro acesso fará o acoplamento local.";
        adherenceAction.textContent = "ACOPLAR";
      }
    }
  } catch (error) {
    card.classList.add("resource-disabled");
    card.setAttribute("aria-disabled", "true");
    card.href = "#";
    $("scaleDownloadAction").textContent = "INDISPONÍVEL";

    const adherenceCard = $("adherenceAppCard");
    if (adherenceCard) {
      adherenceCard.classList.add("resource-disabled");
      adherenceCard.setAttribute("aria-disabled", "true");
      adherenceCard.href = "#";
      $("adherenceAppAction").textContent = "INDISPONÍVEL";
    }
  }
}

function setSidePanel(panelId, open) {
  const panel = $(panelId);
  const backdrop = $("sidePanelBackdrop");
  if (!panel || !backdrop) return;

  document.querySelectorAll(".side-panel.open").forEach((item) => {
    if (item !== panel) {
      item.classList.remove("open");
      item.setAttribute("aria-hidden", "true");
    }
  });

  panel.classList.toggle("open", open);
  panel.setAttribute("aria-hidden", open ? "false" : "true");

  const handleId = panelId === "leftArchivePanel" ? "leftArchiveHandle" : "rightArchiveHandle";
  const handle = $(handleId);
  if (handle) handle.setAttribute("aria-expanded", open ? "true" : "false");

  const anyOpen = Boolean(document.querySelector(".side-panel.open"));
  backdrop.classList.toggle("show", anyOpen);
  backdrop.setAttribute("aria-hidden", anyOpen ? "false" : "true");
}

function closeSidePanels() {
  document.querySelectorAll(".side-panel.open").forEach((panel) => {
    panel.classList.remove("open");
    panel.setAttribute("aria-hidden", "true");
  });

  ["leftArchiveHandle", "rightArchiveHandle"].forEach((id) => {
    const handle = $(id);
    if (handle) handle.setAttribute("aria-expanded", "false");
  });

  const backdrop = $("sidePanelBackdrop");
  if (backdrop) {
    backdrop.classList.remove("show");
    backdrop.setAttribute("aria-hidden", "true");
  }
}

function initSidePanels() {
  const leftHandle = $("leftArchiveHandle");
  const rightHandle = $("rightArchiveHandle");
  const backdrop = $("sidePanelBackdrop");

  if (leftHandle) leftHandle.addEventListener("click", () => setSidePanel("leftArchivePanel", true));
  if (rightHandle) rightHandle.addEventListener("click", () => setSidePanel("rightArchivePanel", true));
  if (backdrop) backdrop.addEventListener("click", closeSidePanels);

  document.querySelectorAll("[data-close-panel]").forEach((button) => {
    button.addEventListener("click", () => closeSidePanels());
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeSidePanels();
  });
}

async function boot() {
  initSidePanels();

  const scaleCard = $("scaleDownloadCard");
  if (scaleCard) {
    scaleCard.addEventListener("click", (event) => {
      if (scaleCard.classList.contains("resource-disabled")) {
        event.preventDefault();
        toast("Escala de Folgas.xlsm ainda não está no pacote local.", true);
      }
    });
  }

  try {
    const health = await api("/api/health");
    $("nodeStatus").textContent = health.ok ? "NODE ONLINE" : "NODE DEGRADED";

    const catalog = await api("/api/robots");
    $("title").textContent = catalog.title || "CENTRAL RPA";
    $("subtitle").textContent = catalog.subtitle || "LOCAL AUTOMATION NODE // 127.0.0.1";
    state.robots = Array.isArray(catalog.robots) ? catalog.robots : [];
    renderRobots();
    await loadResources();

    terminal("catálogo carregado: " + state.robots.length + " módulo(s).");
  } catch (error) {
    $("nodeStatus").textContent = "NODE ERROR";
    terminal(error.message, "error");
    toast(error.message, true);
  }
}

window.addEventListener("focus", () => {
  loadResources().catch(() => {});
});

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
    drops[i] += .24 + Math.random() * .07;
  }

  requestAnimationFrame(drawMatrix);
}
requestAnimationFrame(drawMatrix);

boot();
