const state = {
  data: null,
  selectedId: null,
  selectedCategory: null,
  query: '',
  config: {},
  expanded: {},
  rootExpanded: true,
  heartbeatId: null
};

const els = {};
function $(id) { return document.getElementById(id); }

function initEls() {
  [
    'loading', 'loadingText', 'appTitle', 'appSubtitle', 'headerTitle', 'headerSubtitle',
    'problemChip', 'generatedAt', 'summaryGrid', 'searchInput', 'categories', 'infoGrid',
    'gpuList', 'diskList', 'driverDetail', 'errorBanner', 'refreshBtn', 'fullscreenBtn',
    'driverUpdateBtn', 'logoImage', 'wallpaperPreview', 'wallpaperPlaceholder'
  ].forEach(id => els[id] = $(id));
}

function esc(v) {
  return String(v ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function safe(v, fallback = '-') {
  const s = String(v ?? '').replace(/\0/g, '').trim();
  return s || fallback;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function apiUrl(path) {
  return new URL(path, window.location.origin).toString();
}

function showLoading(text) {
  els.loading.classList.remove('hidden');
  if (text) els.loadingText.textContent = text;
}

function hideLoading() {
  els.loading.classList.add('hidden');
}

function showBanner(message, type = 'error') {
  els.errorBanner.classList.remove('hidden', 'success', 'warning');
  if (type === 'success') {
    els.errorBanner.classList.add('success');
  } else if (type === 'warning') {
    els.errorBanner.classList.add('warning');
  }
  els.errorBanner.textContent = message;
}

function showError(message) {
  showBanner(message, 'error');
}

function showSuccess(message) {
  showBanner(message, 'success');
}

function hideError() {
  els.errorBanner.classList.add('hidden');
  els.errorBanner.classList.remove('success', 'warning');
  els.errorBanner.textContent = '';
}

async function loadConfig() {
  try {
    const res = await fetch(apiUrl('/config/ui-config.json?_=' + Date.now()), { cache: 'no-store' });
    if (!res.ok) throw new Error('Falha ao carregar configuração.');
    state.config = await res.json();
  } catch {
    state.config = {};
  }

  els.appTitle.textContent = safe(state.config.title, 'Controle de Qualidade');
  els.appSubtitle.textContent = safe(state.config.subtitle, 'Diagnóstico visual do sistema, discos e drivers');
  els.headerTitle.textContent = safe(state.config.headerTitle, 'Painel de Diagnóstico');

  const subtitle = String(state.config.headerSubtitle ?? '').trim();
  if (subtitle) {
    els.headerSubtitle.textContent = subtitle;
    els.headerSubtitle.classList.remove('hidden');
  } else {
    els.headerSubtitle.textContent = '';
    els.headerSubtitle.classList.add('hidden');
  }

  if (state.config.logo) {
    els.logoImage.src = state.config.logo;
  }
}

async function fetchJsonWithRetry(path, retries = 2) {
  let lastErr = null;

  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const res = await fetch(apiUrl(path + (path.includes('?') ? '&' : '?') + '_=' + Date.now()), {
        cache: 'no-store',
        headers: { 'Accept': 'application/json' }
      });

      const text = await res.text();
      let parsed;
      try {
        parsed = JSON.parse(text);
      } catch {
        throw new Error('A API retornou um JSON inválido.');
      }

      if (!res.ok || parsed.Error) {
        throw new Error(parsed.Message || 'Falha ao coletar os dados.');
      }

      return parsed;
    } catch (err) {
      lastErr = err;
      if (attempt < retries) {
        await sleep(500 * (attempt + 1));
      }
    }
  }

  throw lastErr || new Error('Falha de comunicação com o serviço local.');
}

async function postJson(path, body) {
  const res = await fetch(apiUrl(path), {
    method: 'POST',
    cache: 'no-store',
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8'
    },
    body: JSON.stringify(body || {})
  });

  const text = await res.text();
  let parsed = {};
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    throw new Error('A API retornou uma resposta inválida.');
  }

  if (!res.ok || parsed.Error) {
    throw new Error(parsed.Message || 'Falha ao executar a operação.');
  }

  return parsed;
}

function humanizeNetworkError(err) {
  const raw = String(err?.message || err || '');
  if (/Failed to fetch/i.test(raw) || /NetworkError/i.test(raw)) {
    return 'Falha de comunicação com o serviço local. O servidor do app não respondeu a tempo. Feche e abra o aplicativo se isso voltar a acontecer.';
  }
  return raw || 'Falha ao atualizar os dados.';
}

async function loadData() {
  showLoading('Coletando informações de hardware e drivers...');
  hideError();
  els.refreshBtn.disabled = true;

  try {
    state.data = await fetchJsonWithRetry('/api/data', 2);
    syncExpandedState(true);
    ensureSelectedDriver();
    renderAll();
    await loadWallpaperPreview(false);
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    els.refreshBtn.disabled = false;
    hideLoading();
  }
}

async function runDriverUpdate() {
  hideError();
  els.driverUpdateBtn.disabled = true;
  showLoading('Iniciando atualização de drivers...');

  try {
    const result = await postJson('/api/run-driver-update', {});
    showSuccess(result.Message || 'Atualizador de drivers iniciado.');
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    els.driverUpdateBtn.disabled = false;
    hideLoading();
  }
}

async function copySelectedDriverId() {
  const item = selectedDriver();
  if (!item) {
    showError('Selecione um driver com problema para copiar o Hardware ID.');
    return;
  }

  const hardwareIds = extractHardwareIds(item);

  if (!item.HasProblemUI) {
    showError('O botão Copiar ID aparece apenas para drivers com problema.');
    return;
  }

  if (!hardwareIds.length) {
    showError('Hardware ID não encontrado para este dispositivo.');
    return;
  }

  const copyBtn = els.driverDetail.querySelector('#copySelectedIdBtn');
  if (copyBtn) copyBtn.disabled = true;

  try {
    const payload = {
      DeviceName: safe(item.DeviceName),
      InstanceId: safe(item.InstanceId),
      Category: safe(item.Category),
      HardwareIds: hardwareIds
    };

    const result = await postJson('/api/copy-driver-id', payload);

    try {
      await navigator.clipboard.writeText(hardwareIds.join('\r\n'));
    } catch {}

    showSuccess(result.Message || 'Hardware ID salvo com sucesso.');
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    if (copyBtn) copyBtn.disabled = false;
  }
}

async function copyAllProblemDriverIds() {
  const drivers = problemDrivers();
  if (!drivers.length) {
    showError('Nenhum driver com problema foi encontrado para copiar.');
    return;
  }

  const payloadDrivers = drivers.map(item => ({
    DeviceName: safe(item.DeviceName),
    InstanceId: safe(item.InstanceId),
    Category: safe(item.Category),
    HardwareIds: extractHardwareIds(item)
  })).filter(item => item.HardwareIds.length > 0);

  if (!payloadDrivers.length) {
    showError('Nenhum Hardware ID foi encontrado entre os drivers com problema.');
    return;
  }

  const copyAllBtn = els.driverDetail.querySelector('#copyAllIdsBtn');
  if (copyAllBtn) copyAllBtn.disabled = true;

  try {
    const result = await postJson('/api/copy-driver-id-all', { Drivers: payloadDrivers });

    const clipText = payloadDrivers.map(item => {
      return [
        '=== ' + item.DeviceName + ' ===',
        'Categoria: ' + item.Category,
        'Instance ID: ' + item.InstanceId,
        ...item.HardwareIds,
        ''
      ].join('\r\n');
    }).join('\r\n');

    try {
      await navigator.clipboard.writeText(clipText.trim());
    } catch {}

    showSuccess(result.Message || 'Hardware IDs salvos com sucesso.');
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    if (copyAllBtn) copyAllBtn.disabled = false;
  }
}

async function keepServerAlive() {
  try {
    await fetch(apiUrl('/api/ping?_=' + Date.now()), { cache: 'no-store' });
  } catch {}
}

function startHeartbeat() {
  if (state.heartbeatId) clearInterval(state.heartbeatId);
  keepServerAlive();
  state.heartbeatId = setInterval(keepServerAlive, 15000);
}

async function loadWallpaperPreview(showBusyText = true) {
  if (showBusyText) {
    els.wallpaperPlaceholder.textContent = 'Lendo wallpaper atual...';
    els.wallpaperPlaceholder.classList.remove('hidden');
    els.wallpaperPreview.classList.add('hidden');
  }

  return new Promise(resolve => {
    const img = els.wallpaperPreview;
    const placeholder = els.wallpaperPlaceholder;

    img.onload = () => {
      img.classList.remove('hidden');
      placeholder.classList.add('hidden');
      resolve(true);
    };

    img.onerror = () => {
      img.classList.add('hidden');
      placeholder.textContent = 'Wallpaper não encontrado.';
      placeholder.classList.remove('hidden');
      resolve(false);
    };

    img.src = apiUrl('/api/wallpaper?_=' + Date.now());
  });
}

function categoryIcon(category) {
  const name = safe(category).toLowerCase();
  const entries = [
    [/adaptadores de video/, '🖵'],
    [/adaptadores de rede/, '🌐'],
    [/controladores de armazenamento|unidades de disco/, '💽'],
    [/controladores de som|entradas e saidas de audio|audio/, '🔊'],
    [/usb/, '🔌'],
    [/dispositivos de seguranca/, '🔒'],
    [/dispositivos de sistema|componentes de software|dispositivos do software/, '⚙'],
    [/firmware/, '◫'],
    [/monitores/, '🖥'],
    [/mouse/, '🖱'],
    [/teclados/, '⌨'],
    [/processadores/, '◌'],
    [/portas/, '⇄'],
    [/impressao/, '🖨'],
    [/interface humana/, '✋'],
    [/computador/, '🖳'],
    [/portateis/, '📱']
  ];

  for (const [pattern, icon] of entries) {
    if (pattern.test(name)) return icon;
  }
  return '▣';
}

function normalizeCategoryName(name) {
  return safe(name, 'Outros dispositivos');
}

function rootLabel() {
  const hw = state.data?.Hardware || {};
  return safe(hw.BoardModel, 'Este computador');
}

function buildGroups() {
  const drivers = state.data?.Drivers || [];
  const query = (state.query || '').toLowerCase().trim();
  const map = new Map();

  drivers.forEach(driver => {
    const category = normalizeCategoryName(driver.Category);
    const blob = [
      driver.Category,
      driver.DeviceName,
      driver.Manufacturer,
      driver.Provider,
      driver.DriverVersion,
      driver.InfName,
      driver.InstanceId,
      driver.ProblemDescription,
      driver.Status
    ].join(' ').toLowerCase();

    if (query && !blob.includes(query)) return;

    if (!map.has(category)) map.set(category, []);
    map.get(category).push(driver);
  });

  const groups = Array.from(map.entries()).map(([name, items]) => {
    const sorted = items.slice().sort((a, b) => safe(a.DeviceName).localeCompare(safe(b.DeviceName), 'pt-BR'));
    return {
      name,
      icon: categoryIcon(name),
      items: sorted,
      problemCount: sorted.filter(item => !!item.HasProblemUI).length
    };
  });

  groups.sort((a, b) => {
    if (a.problemCount !== b.problemCount) return b.problemCount - a.problemCount;
    if (a.name === 'Adaptadores de video') return -1;
    if (b.name === 'Adaptadores de video') return 1;
    return a.name.localeCompare(b.name, 'pt-BR');
  });

  return groups;
}

function syncExpandedState(alwaysOpenProblems) {
  const groups = buildGroups();
  const validNames = new Set(groups.map(group => group.name));

  Object.keys(state.expanded).forEach(name => {
    if (!validNames.has(name)) delete state.expanded[name];
  });

  groups.forEach(group => {
    const hasSelectedInside = group.items.some(item => safe(item.InstanceId, item.DeviceName) === state.selectedId);
    const shouldOpenByDefault = group.problemCount > 0 || group.name === 'Adaptadores de video' || hasSelectedInside;

    if (typeof state.expanded[group.name] === 'undefined') {
      state.expanded[group.name] = shouldOpenByDefault;
      return;
    }

    if (alwaysOpenProblems && shouldOpenByDefault) {
      state.expanded[group.name] = true;
    }
  });
}

function ensureSelectedDriver() {
  const drivers = state.data?.Drivers || [];
  if (!drivers.length) {
    state.selectedId = null;
    state.selectedCategory = null;
    return;
  }

  const exists = drivers.some(item => safe(item.InstanceId, item.DeviceName) === state.selectedId);
  if (exists) return;

  const firstProblem = drivers.find(item => !!item.HasProblemUI);
  const firstVideo = drivers.find(item => normalizeCategoryName(item.Category) === 'Adaptadores de video');
  const chosen = firstProblem || firstVideo || drivers[0];

  state.selectedId = safe(chosen.InstanceId, chosen.DeviceName);
  state.selectedCategory = normalizeCategoryName(chosen.Category);
}

function selectedDriver() {
  const drivers = state.data?.Drivers || [];
  return drivers.find(item => safe(item.InstanceId, item.DeviceName) === state.selectedId) || null;
}

function problemDrivers() {
  const drivers = state.data?.Drivers || [];
  return drivers.filter(item => !!item.HasProblemUI);
}

function extractHardwareIds(item) {
  return Array.isArray(item?.HardwareIds)
    ? item.HardwareIds.map(v => safe(v, '')).filter(Boolean)
    : [];
}

function warningText(item) {
  if (!item || !item.HasProblemUI) return 'OK';
  const code = Number(item.ProblemCode || 0);
  if (code > 0) return 'Código ' + code;
  const text = safe(item.ProblemDescription, 'Verificar driver');
  return text === '-' ? 'Verificar driver' : text;
}

function renderSummary() {
  const summary = state.data?.Summary || {};
  const cards = [
    { label: 'Drivers detectados', value: summary.TotalDrivers || 0, caption: 'Itens lidos do sistema' },
    { label: 'Com problema', value: summary.DriversComProblema || 0, caption: 'Mouse e teclado ignorados' },
    { label: 'GPUs', value: summary.TotalGPUs || 0, caption: 'Adaptadores de vídeo' },
    { label: 'Discos', value: summary.TotalDiscos || 0, caption: 'Unidades físicas' }
  ];

  els.summaryGrid.innerHTML = cards.map(card => `
    <div class="stat-card">
      <div class="label">${esc(card.label)}</div>
      <div class="value">${esc(card.value)}</div>
      <div class="caption">${esc(card.caption)}</div>
    </div>
  `).join('');

  const problems = summary.DriversComProblema || 0;
  els.problemChip.innerHTML = problems > 0
    ? `<span class="status-wrap"><span class="status-triangle">⚠</span><span class="badge badge-warning">${esc(problems)} alerta(s)</span></span>`
    : `<span class="badge badge-success">Tudo certo</span>`;

  els.generatedAt.textContent = 'Atualizado em: ' + safe(state.data?.GeneratedAt);
}

function renderInfo() {
  const hw = state.data?.Hardware || {};
  const items = [
    ['Processador', hw.CPU],
    ['RAM instalada', hw.RAMExibicao || hw.RAMInstalada],
    ['Placa-mãe', hw.BoardModel],
    ['Serial', hw.BoardSerial],
    ['BIOS', `${safe(hw.BIOSManufacturer)} - ${safe(hw.BIOSVersion)}`],
    ['Windows', `${safe(hw.SistemaOperacional)} | Build ${safe(hw.BuildSO)} | Versão ${safe(hw.VersaoSO)}`]
  ];

  els.infoGrid.innerHTML = items.map(([label, value]) => `
    <div class="info-row">
      <div class="info-key">${esc(label)}</div>
      <div class="info-value">${esc(safe(value))}</div>
    </div>
  `).join('');
}

function renderGpus() {
  const gpus = state.data?.Hardware?.GPUs || [];
  els.gpuList.innerHTML = gpus.length
    ? gpus.map((gpu, index) => `
      <div class="mini-card">
        <div class="mini-card-title">GPU ${index + 1}</div>
        <div class="mini-card-text">${esc(gpu)}</div>
      </div>
    `).join('')
    : '<div class="empty-note">Nenhuma GPU encontrada.</div>';
}

function renderDisks() {
  const disks = state.data?.Hardware?.Discos || [];
  els.diskList.innerHTML = disks.length
    ? disks.map(disk => `
      <div class="mini-card">
        <div class="mini-card-title">Disco ${esc(disk.Numero)} - ${esc(disk.Nome)}</div>
        <div class="mini-card-text">${esc(safe(disk.Tamanho))} | ${esc(safe(disk.Interface))}</div>
        <div class="mini-card-sub">Serial: ${esc(safe(disk.Serial))}</div>
        <div class="mini-card-sub">Partições: ${esc(safe(disk.Particoes))} | Volumes: ${esc(safe(disk.Volumes))}</div>
      </div>
    `).join('')
    : '<div class="empty-note">Nenhum disco encontrado.</div>';
}

function renderCategories() {
  const groups = buildGroups();
  if (!groups.length) {
    els.categories.innerHTML = '<div class="empty-note">Nenhum dispositivo encontrado com esse filtro.</div>';
    return;
  }

  const totalProblems = groups.reduce((sum, group) => sum + group.problemCount, 0);
  const rootOpen = state.rootExpanded;

  els.categories.innerHTML = `
    <section class="tree-root ${rootOpen ? 'open' : ''}">
      <button class="tree-root-head" data-root-toggle="1">
        <span class="tree-group-left">
          <span class="tree-caret">${rootOpen ? '▾' : '▸'}</span>
          <span class="tree-computer-icon">🖳</span>
          <span class="tree-group-name">${esc(rootLabel())}</span>
        </span>
        <span class="tree-group-right">
          <span class="tree-group-count">${esc(groups.length)} categoria(s)</span>
          ${totalProblems > 0 ? `<span class="badge badge-warning">${esc(totalProblems)} alerta(s)</span>` : '<span class="badge badge-success">Tudo certo</span>'}
        </span>
      </button>
      <div class="tree-root-body">
        ${groups.map(group => {
          const isOpen = !!state.expanded[group.name];
          return `
            <section class="tree-group ${isOpen ? 'open' : ''}">
              <button class="tree-group-head" data-group-name="${esc(group.name)}">
                <span class="tree-group-left">
                  <span class="tree-caret">${isOpen ? '▾' : '▸'}</span>
                  <span class="tree-category-icon ${group.problemCount > 0 ? 'warn' : ''}">${esc(group.icon)}</span>
                  <span class="tree-group-name">${esc(group.name)}</span>
                </span>
                <span class="tree-group-right">
                  <span class="tree-group-count">${esc(group.items.length)} item(ns)</span>
                  ${group.problemCount > 0 ? `<span class="badge badge-warning">${esc(group.problemCount)} alerta(s)</span>` : '<span class="badge badge-neutral">OK</span>'}
                </span>
              </button>
              <div class="tree-group-body">
                ${group.items.map(item => {
                  const id = safe(item.InstanceId, item.DeviceName);
                  const isActive = state.selectedId === id;
                  const hasProblem = !!item.HasProblemUI;
                  return `
                    <button class="tree-device ${isActive ? 'active' : ''} ${hasProblem ? 'problem' : ''}" data-device-id="${esc(id)}" data-category-name="${esc(group.name)}">
                      <span class="tree-device-indent"></span>
                      <span class="tree-device-icon ${hasProblem ? 'icon-problem' : 'icon-ok'}">${hasProblem ? '⚠' : '•'}</span>
                      <span class="tree-device-main">
                        <span class="tree-device-name">${esc(safe(item.DeviceName))}</span>
                        <span class="tree-device-meta">${esc(safe(item.Manufacturer))} | ${esc(safe(item.Provider))}</span>
                      </span>
                      <span class="tree-device-state ${hasProblem ? 'state-problem' : 'state-ok'}">${esc(warningText(item))}</span>
                    </button>
                  `;
                }).join('')}
              </div>
            </section>
          `;
        }).join('')}
      </div>
    </section>
  `;

  bindTreeEvents();
}

function detailCard(title, value, compact = true) {
  return `
    <div class="detail-card ${compact ? 'detail-card-compact' : ''}">
      <h4>${esc(title)}</h4>
      <pre>${esc(safe(value))}</pre>
    </div>
  `;
}

function renderDriverDetail() {
  const item = selectedDriver();
  if (!item) {
    els.driverDetail.innerHTML = '<div class="driver-empty">Selecione um dispositivo para ver os detalhes.</div>';
    return;
  }

  const hasProblem = !!item.HasProblemUI;
  const statusText = warningText(item);
  const hardwareIds = extractHardwareIds(item);
  const allProblemDrivers = problemDrivers();
  const copyAllAvailable = allProblemDrivers.some(problemItem => extractHardwareIds(problemItem).length > 0);
  const selectedCopyAvailable = hasProblem && hardwareIds.length > 0;

  const copyBlock = allProblemDrivers.length ? `
    <div class="driver-tool-row">
      <button id="copyAllIdsBtn" class="btn btn-copy-id" ${copyAllAvailable ? '' : 'disabled'}>Copiar ID de todos</button>
      <button id="copySelectedIdBtn" class="btn btn-copy-id btn-copy-id-secondary" ${selectedCopyAvailable ? '' : 'disabled'}>Copiar ID do selecionado</button>
      <div class="driver-tool-help">
        ${hasProblem
          ? 'Os dois botões geram arquivos .txt na pasta DriversID.'
          : 'Selecione um driver com problema para habilitar o botão do selecionado. O botão de todos gera um .txt consolidado.'}
      </div>
    </div>
  ` : '';

  els.driverDetail.innerHTML = `
    <div class="driver-head">
      <div>
        <h3 class="driver-name">${esc(safe(item.DeviceName))}</h3>
        <div class="driver-sub">${esc(normalizeCategoryName(item.Category))} | ${esc(safe(item.Status))}</div>
      </div>
      ${hasProblem ? '<span class="badge badge-warning">Problema</span>' : '<span class="badge badge-success">OK</span>'}
    </div>

    <div class="driver-alert ${hasProblem ? 'problem' : 'ok'}">
      <span class="driver-alert-icon">${hasProblem ? '⚠' : '✓'}</span>
      <div>
        <strong>${hasProblem ? 'Aviso de driver detectado' : 'Driver lido sem alertas'}</strong>
        <div>${esc(hasProblem ? statusText : 'Nenhum problema reportado para este dispositivo.')}</div>
      </div>
    </div>

    ${copyBlock}

    <div class="detail-grid">
      ${detailCard('Fabricante', item.Manufacturer)}
      ${detailCard('Provedor', item.Provider)}
      ${detailCard('Versão do driver', item.DriverVersion)}
      ${detailCard('Data do driver', item.DriverDate)}
      ${detailCard('INF', item.InfName)}
      ${detailCard('Assinado', item.Signed)}
      ${detailCard('Assinante', item.Signer)}
      ${detailCard('Serviço', item.Service)}
      ${detailCard('Código do problema', item.ProblemCode)}
      ${detailCard('Descrição do problema', item.ProblemDescription)}
      ${detailCard('Status', item.Status)}
      ${detailCard('Presente', item.Present)}
      ${detailCard('Classe', item.CategoryCode)}
      ${detailCard('Instance ID', item.InstanceId, false)}
      ${detailCard('Hardware IDs', hardwareIds.length ? hardwareIds.join('\n') : 'Não encontrado', false)}
    </div>

    <div class="footer-note">Mouse e teclado continuam ignorados nos alertas, como você pediu.</div>
  `;

  const copyAllBtn = els.driverDetail.querySelector('#copyAllIdsBtn');
  if (copyAllBtn) {
    copyAllBtn.addEventListener('click', copyAllProblemDriverIds);
  }

  const copySelectedBtn = els.driverDetail.querySelector('#copySelectedIdBtn');
  if (copySelectedBtn) {
    copySelectedBtn.addEventListener('click', copySelectedDriverId);
  }
}

function renderAll() {
  if (!state.data) return;
  renderSummary();
  renderInfo();
  renderGpus();
  renderDisks();
  renderCategories();
  renderDriverDetail();
}

function bindTreeEvents() {
  const rootBtn = els.categories.querySelector('[data-root-toggle]');
  if (rootBtn) {
    rootBtn.addEventListener('click', () => {
      state.rootExpanded = !state.rootExpanded;
      renderCategories();
    });
  }

  els.categories.querySelectorAll('[data-group-name]').forEach(btn => {
    btn.addEventListener('click', () => {
      const groupName = btn.getAttribute('data-group-name');
      state.expanded[groupName] = !state.expanded[groupName];
      renderCategories();
    });
  });

  els.categories.querySelectorAll('[data-device-id]').forEach(btn => {
    btn.addEventListener('click', () => {
      state.selectedId = btn.getAttribute('data-device-id');
      state.selectedCategory = btn.getAttribute('data-category-name');
      syncExpandedState(true);
      renderCategories();
      renderDriverDetail();
    });
  });
}

function bindEvents() {
  els.refreshBtn.addEventListener('click', loadData);
  els.driverUpdateBtn.addEventListener('click', runDriverUpdate);

  els.fullscreenBtn.addEventListener('click', async () => {
    if (!document.fullscreenElement) {
      try { await document.documentElement.requestFullscreen(); } catch {}
    } else {
      try { await document.exitFullscreen(); } catch {}
    }
  });

  els.searchInput.addEventListener('input', event => {
    state.query = event.target.value || '';
    syncExpandedState(true);
    ensureSelectedDriver();
    renderCategories();
    renderDriverDetail();
  });
}

window.addEventListener('DOMContentLoaded', async () => {
  initEls();
  bindEvents();
  startHeartbeat();
  await loadConfig();
  await loadWallpaperPreview(true);
  await loadData();
});
