/*
 * PAINEL DE DIAGNÓSTICO — COMPORTAMENTO DA INTERFACE
 *
 * Este arquivo conecta o HTML à API do servidor local. O fluxo é:
 * localizar elementos → registrar eventos → manter a conexão ativa →
 * carregar configurações → coletar dados → desenhar os painéis.
 *
 * As seções abaixo seguem a ordem original do programa. Dados recebidos,
 * seleção, filtro e categorias abertas ficam centralizados em state.
 */

// ============================================================================
// 1. ESTADO DA TELA E REFERÊNCIAS AOS ELEMENTOS DO HTML
// ============================================================================

const state = {
  // Última resposta da API, com hardware, drivers e totais do diagnóstico.
  data: null,
  // Identificador e categoria do dispositivo exibido no painel de detalhes.
  selectedId: null,
  selectedCategory: null,
  // Texto digitado na busca de dispositivos.
  query: '',
  // Personalização carregada de config/ui-config.json.
  config: {},
  // Cada chave guarda se uma categoria da árvore está aberta ou fechada.
  expanded: {},
  // Controla a abertura do nó principal, que representa o computador.
  rootExpanded: true,
  // Identificador do intervalo usado para enviar sinais de atividade à API.
  heartbeatId: null
};

// Cache dos elementos: evita procurá-los novamente a cada atualização da tela.
const els = {};

// Atalho para encontrar um elemento pelo atributo id.
function $(id) { return document.getElementById(id); }

// Preenche o cache depois que o navegador termina de montar o HTML.
function initEls() {
  [
    'loading', 'loadingText', 'appTitle', 'appSubtitle', 'headerTitle', 'headerSubtitle',
    'problemChip', 'generatedAt', 'summaryGrid', 'searchInput', 'categories', 'infoGrid',
    'gpuList', 'diskList', 'driverDetail', 'errorBanner', 'refreshBtn', 'fullscreenBtn',
    'driverUpdateBtn', 'biosBtn', 'rebootBtn', 'logoImage'
  ].forEach(id => els[id] = $(id));
}

// ============================================================================
// 2. TRATAMENTO DE TEXTO E REGRAS DE CLASSIFICAÇÃO DOS DRIVERS
// ============================================================================

// Escapa caracteres especiais antes de inserir valores em trechos de HTML.
function esc(v) {
  return String(v ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Remove caracteres nulos e espaços nas pontas; usa o padrão se nada sobrar.
function safe(v, fallback = '-') {
  const s = String(v ?? '').replace(/\0/g, '').trim();
  return s || fallback;
}

// Uniformiza acentos, maiúsculas e espaços para as comparações de diagnóstico.
function normalizeText(v) {
  return String(v ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .trim();
}

// Reconhece nomes de categorias de vídeo em português ou no padrão Display.
function isVideoCategoryName(category) {
  const c = normalizeText(category);
  return c.includes('adaptadores de video') || c === 'display' || c.includes('video');
}

// Detecta referências ao driver básico de vídeo da Microsoft em vários nomes.
function isMicrosoftBasicVideoText(value) {
  const s = normalizeText(value);
  if (!s) return false;
  const hasMicrosoft = s.includes('microsoft');
  const hasBasicVideo =
    s.includes('basic display adapter') ||
    s.includes('microsoft basic display') ||
    s.includes('adaptador de video basico') ||
    s.includes('adaptador grafico basico') ||
    s.includes('adaptador basico de video') ||
    s.includes('video basico da microsoft') ||
    s.includes('grafico basico da microsoft') ||
    (s.includes('basic') && s.includes('display')) ||
    (s.includes('basico') && (s.includes('video') || s.includes('grafico')));
  return hasMicrosoft && hasBasicVideo;
}

// Confere a categoria e os campos do dispositivo para identificar vídeo básico.
function isMicrosoftBasicVideoDriver(item) {
  if (!item) return false;
  const category = normalizeCategoryName(item.Category);
  const blob = [
    item.DeviceName,
    item.Manufacturer,
    item.Provider,
    item.DriverVersion,
    item.InfName,
    item.Status,
    item.ProblemDescription,
    item.Category,
    item.CategoryCode
  ].join(' ');
  return isVideoCategoryName(category) && isMicrosoftBasicVideoText(blob);
}

// Exceções de identificadores ACPI que não devem gerar alerta na interface.
const IGNORED_DRIVER_ID_PATTERNS = [
  'acpi\\ven_mbid&dev_0005',
  'acpi\\mbid0005',
  'ven_mbid&dev_0005',
  'mbid0005',
  'acpi\\ven_mbad&dev_0002',
  'acpi\\mbad0002',
  'ven_mbad&dev_0002',
  'mbad0002'
];

// Procura as exceções nos nomes, identificadores e demais campos do dispositivo.
function isIgnoredDriverAlert(item) {
  if (!item) return false;
  const values = [
    item.DeviceName,
    item.Manufacturer,
    item.Provider,
    item.InfName,
    item.InstanceId,
    item.PnpDeviceId,
    item.ProblemDescription,
    item.Status,
    Array.isArray(item.HardwareIds) ? item.HardwareIds.join(' ') : '',
    Array.isArray(item.CompatibleIds) ? item.CompatibleIds.join(' ') : ''
  ].join(' ');
  const normalized = normalizeText(values);
  return IGNORED_DRIVER_ID_PATTERNS.some(pattern => normalized.includes(pattern));
}

// Considera válido um dispositivo de vídeo que não use o driver básico Microsoft.
function isInstalledVideoDriver(item) {
  if (!item) return false;
  if (!isVideoCategoryName(normalizeCategoryName(item.Category))) return false;
  if (isMicrosoftBasicVideoDriver(item)) return false;
  return true;
}

// Centraliza a regra dos alertas para manter contadores e detalhes consistentes.
function driverHasProblem(item) {
  if (isIgnoredDriverAlert(item)) return false;
  return !!item?.HasProblemUI || isMicrosoftBasicVideoDriver(item);
}

// Aprova somente quando não há alertas e existe vídeo válido sem driver básico.
function qualityStatus() {
  const drivers = state.data?.Drivers || [];
  const gpuNames = state.data?.Hardware?.GPUs || [];
  const problemCount = drivers.filter(driverHasProblem).length;
  const basicVideoByDriver = drivers.some(isMicrosoftBasicVideoDriver);
  const basicVideoByGpu = gpuNames.some(isMicrosoftBasicVideoText);
  const hasInstalledVideo = drivers.some(isInstalledVideoDriver) || (gpuNames.length > 0 && !basicVideoByGpu);
  const videoOk = hasInstalledVideo && !basicVideoByDriver && !basicVideoByGpu;

  return {
    approved: problemCount <= 0 && videoOk,
    problemCount,
    videoOk,
    hasBasicVideo: basicVideoByDriver || basicVideoByGpu
  };
}

// ============================================================================
// 3. UTILITÁRIOS DE REDE, CARREGAMENTO E MENSAGENS DA INTERFACE
// ============================================================================

// Pausa assíncrona usada no intervalo entre tentativas de consulta à API.
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Resolve cada endereço usando a mesma origem do servidor que abriu o painel.
function apiUrl(path) {
  return new URL(path, window.location.origin).toString();
}

// Exibe a camada de carregamento e, se informado, atualiza seu texto.
function showLoading(text) {
  els.loading.classList.remove('hidden');
  if (text) els.loadingText.textContent = text;
}

// Libera a visualização da tela ao final de uma operação.
function hideLoading() {
  els.loading.classList.add('hidden');
}

// Reutiliza o mesmo aviso para erros, sucessos e advertências.
function showBanner(message, type = 'error') {
  els.errorBanner.classList.remove('hidden', 'success', 'warning');
  if (type === 'success') {
    els.errorBanner.classList.add('success');
  } else if (type === 'warning') {
    els.errorBanner.classList.add('warning');
  }
  els.errorBanner.textContent = message;
}

// Atalho para apresentar uma falha no aviso da tela.
function showError(message) {
  showBanner(message, 'error');
}

// Atalho para apresentar a confirmação de uma operação.
function showSuccess(message) {
  showBanner(message, 'success');
}

// Limpa tanto o conteúdo quanto as classes de um aviso anterior.
function hideError() {
  els.errorBanner.classList.add('hidden');
  els.errorBanner.classList.remove('success', 'warning');
  els.errorBanner.textContent = '';
}

// Carrega a personalização visual; mantém os valores padrão se a leitura falhar.
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

// Consulta JSON sem cache e repete falhas com espera crescente entre tentativas.
// retries conta as repetições além da primeira tentativa de consulta.
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

// Envia comandos à API local e transforma falhas HTTP ou da API em exceções.
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

// Troca erros conhecidos de conexão por uma orientação legível para o usuário.
function humanizeNetworkError(err) {
  const raw = String(err?.message || err || '');
  if (/Failed to fetch/i.test(raw) || /NetworkError/i.test(raw)) {
    return 'Falha de comunicação com o serviço local. O servidor do app não respondeu a tempo. Feche e abra o aplicativo se isso voltar a acontecer.';
  }
  return raw || 'Falha ao atualizar os dados.';
}

// ============================================================================
// 4. AÇÕES DO PAINEL E COMUNICAÇÃO COM O SERVIDOR LOCAL
// ============================================================================

// Atualiza o diagnóstico, ajusta a árvore e redesenha todos os dados recebidos.
// O finally libera o botão e remove o carregamento mesmo quando a consulta falha.
async function loadData() {
  showLoading('Coletando informações de hardware e drivers...');
  hideError();
  els.refreshBtn.disabled = true;

  try {
    state.data = await fetchJsonWithRetry('/api/data', 2);
    syncExpandedState(true);
    ensureSelectedDriver();
    renderAll();
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    els.refreshBtn.disabled = false;
    hideLoading();
  }
}

// Solicita ao servidor a execução do atualizador de drivers configurado.
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

// Confirma com o usuário antes de solicitar o reinício para a BIOS/UEFI.
async function runBios() {
  hideError();
  const confirmed = window.confirm('O computador vai reiniciar agora e entrar na BIOS/UEFI. Deseja continuar?');
  if (!confirmed) { return; }

  els.biosBtn.disabled = true;
  showLoading('Reiniciando para a BIOS...');

  try {
    const result = await postJson('/api/run-bios', {});
    showSuccess(result.Message || 'Reiniciando para a BIOS...');
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    els.biosBtn.disabled = false;
    hideLoading();
  }
}

// Confirma com o usuário antes de solicitar o reinício normal do computador.
async function runReboot() {
  hideError();
  const confirmed = window.confirm('O computador vai reiniciar agora. Deseja continuar?');
  if (!confirmed) { return; }

  els.rebootBtn.disabled = true;
  showLoading('Reiniciando o computador...');

  try {
    const result = await postJson('/api/run-reboot', {});
    showSuccess(result.Message || 'Reiniciando o computador...');
  } catch (err) {
    showError(humanizeNetworkError(err));
  } finally {
    els.rebootBtn.disabled = false;
    hideLoading();
  }
}

// Salva os IDs do dispositivo selecionado pela API, quando ele possui alerta.
// Também tenta copiar os IDs no navegador; essa cópia pode falhar sem impedir
// a confirmação do salvamento realizado pelo servidor.
async function copySelectedDriverId() {
  const item = selectedDriver();
  if (!item) {
    showError('Selecione um driver com problema para copiar o Hardware ID.');
    return;
  }

  const hardwareIds = extractHardwareIds(item);

  if (!driverHasProblem(item)) {
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

// Reúne somente drivers com alerta e IDs disponíveis para gerar um arquivo
// consolidado pela API e tentar copiar o mesmo conteúdo para a área de transferência.
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

// Sinaliza atividade ao serviço local; uma falha isolada não interrompe a tela.
async function keepServerAlive() {
  try {
    await fetch(apiUrl('/api/ping?_=' + Date.now()), { cache: 'no-store' });
  } catch {}
}

// Envia um sinal imediatamente e a cada 15 segundos, sem duplicar intervalos.
function startHeartbeat() {
  if (state.heartbeatId) clearInterval(state.heartbeatId);
  keepServerAlive();
  state.heartbeatId = setInterval(keepServerAlive, 15000);
}

// ============================================================================
// 5. PREPARAÇÃO DOS DADOS, FILTRO, EXPANSÃO DA ÁRVORE E SELEÇÃO
// ============================================================================

// Escolhe o símbolo visual da categoria usando os nomes conhecidos de dispositivos.
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

// Garante um nome de categoria mesmo para dispositivos sem essa informação.
function normalizeCategoryName(name) {
  return safe(name, 'Outros dispositivos');
}

// Usa o modelo da placa-mãe como nome do nó principal da árvore.
function rootLabel() {
  const hw = state.data?.Hardware || {};
  return safe(hw.BoardModel, 'Este computador');
}

// Filtra os drivers pelos campos pesquisáveis e os reúne por categoria.
// Dentro de cada grupo, ordena por nome; entre grupos, prioriza alertas e vídeo.
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
      problemCount: sorted.filter(driverHasProblem).length
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

// Remove categorias que saíram do resultado e define a abertura das restantes.
// Categorias com alerta, vídeo ou o dispositivo selecionado podem abrir sozinhas.
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

// Preserva uma seleção ainda existente; caso contrário, escolhe primeiro um
// driver com problema, depois um de vídeo e, por último, o primeiro da lista.
function ensureSelectedDriver() {
  const drivers = state.data?.Drivers || [];
  if (!drivers.length) {
    state.selectedId = null;
    state.selectedCategory = null;
    return;
  }

  const exists = drivers.some(item => safe(item.InstanceId, item.DeviceName) === state.selectedId);
  if (exists) return;

  const firstProblem = drivers.find(driverHasProblem);
  const firstVideo = drivers.find(item => normalizeCategoryName(item.Category) === 'Adaptadores de video');
  const chosen = firstProblem || firstVideo || drivers[0];

  state.selectedId = safe(chosen.InstanceId, chosen.DeviceName);
  state.selectedCategory = normalizeCategoryName(chosen.Category);
}

// Localiza o objeto completo do dispositivo atualmente selecionado.
function selectedDriver() {
  const drivers = state.data?.Drivers || [];
  return drivers.find(item => safe(item.InstanceId, item.DeviceName) === state.selectedId) || null;
}

// Retorna os dispositivos que atendem à mesma regra de alerta usada na tela.
function problemDrivers() {
  const drivers = state.data?.Drivers || [];
  return drivers.filter(driverHasProblem);
}

// Extrai os Hardware IDs, descartando valores vazios e preservando a ordem.
function extractHardwareIds(item) {
  return Array.isArray(item?.HardwareIds)
    ? item.HardwareIds.map(v => safe(v, '')).filter(Boolean)
    : [];
}

// Produz o resumo do estado mostrado na árvore e nos detalhes do dispositivo.
function warningText(item) {
  if (!item || !driverHasProblem(item)) return 'OK';
  if (isMicrosoftBasicVideoDriver(item)) return 'Driver de vídeo Microsoft Básico instalado';
  const code = Number(item.ProblemCode || 0);
  if (code > 0) return 'Código ' + code;
  const text = safe(item.ProblemDescription, 'Verificar driver');
  return text === '-' ? 'Verificar driver' : text;
}

// ============================================================================
// 6. RENDERIZAÇÃO DOS CARTÕES, DA ÁRVORE E DOS DETALHES DO DIAGNÓSTICO
// ============================================================================

// Atualiza os totais laterais, o aviso de problemas e o resultado da aprovação.
function renderSummary() {
  const summary = state.data?.Summary || {};
  const quality = qualityStatus();
  const cards = [
    { label: 'Drivers detectados', value: summary.TotalDrivers || 0, caption: 'Itens lidos do sistema' },
    { label: 'Com problema', value: quality.problemCount, caption: 'Mouse e teclado ignorados' },
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

  const problems = quality.problemCount;
  els.problemChip.innerHTML = problems > 0
    ? `<span class="status-wrap"><span class="status-triangle">⚠</span><span class="badge badge-warning">${esc(problems)} alerta(s)</span></span>`
    : (quality.videoOk ? `<span class="badge badge-success">Tudo certo</span>` : `<span class="status-wrap"><span class="status-triangle">⚠</span><span class="badge badge-warning">Verificar vídeo</span></span>`);

  const approved = quality.approved;
  els.generatedAt.textContent = approved ? 'APROVADO' : 'REPROVADO';
  els.generatedAt.classList.toggle('chip-approved', approved);
  els.generatedAt.classList.toggle('chip-reproved', !approved);
  els.generatedAt.title = safe(state.data?.GeneratedAt) ? ('Ultima leitura: ' + safe(state.data?.GeneratedAt)) : '';
}

// Monta as linhas de processador, memória, placa-mãe, BIOS e Windows.
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

// Cria um cartão por GPU ou informa que nenhuma foi encontrada.
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

// Exibe identificação, capacidade, interface, serial, partições e volumes.
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

// Reconstrói os três níveis da árvore: computador, categorias e dispositivos.
// Os atributos data-* ligam cada botão à seleção e aos eventos registrados depois.
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
                  const hasProblem = driverHasProblem(item);
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

// Gera o HTML de um campo dos detalhes, com opção de usar toda a largura.
function detailCard(title, value, compact = true) {
  return `
    <div class="detail-card ${compact ? 'detail-card-compact' : ''}">
      <h4>${esc(title)}</h4>
      <pre>${esc(safe(value))}</pre>
    </div>
  `;
}

// Mostra o estado e os campos do driver selecionado. Quando há alertas, também
// apresenta os controles de cópia e registra os eventos dos botões recém-criados.
function renderDriverDetail() {
  const item = selectedDriver();
  if (!item) {
    els.driverDetail.innerHTML = '<div class="driver-empty">Selecione um dispositivo para ver os detalhes.</div>';
    return;
  }

  const hasProblem = driverHasProblem(item);
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

// Ponto único de atualização visual após receber um conjunto de dados da API.
function renderAll() {
  if (!state.data) return;
  renderSummary();
  renderInfo();
  renderGpus();
  renderDisks();
  renderCategories();
  renderDriverDetail();
}

// ============================================================================
// 7. EVENTOS DOS BOTÕES, BUSCA E INICIALIZAÇÃO DA APLICAÇÃO
// ============================================================================

// Reassocia os cliques após cada reconstrução da árvore: seus elementos antigos
// são substituídos por renderCategories ao expandir, recolher ou selecionar itens.
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

// Registra os eventos dos controles fixos apenas uma vez na inicialização.
function bindEvents() {
  els.refreshBtn.addEventListener('click', loadData);
  els.driverUpdateBtn.addEventListener('click', runDriverUpdate);

  els.biosBtn.addEventListener('click', runBios);
  els.rebootBtn.addEventListener('click', runReboot);

  // Alterna a tela cheia pelo recurso nativo do navegador.
  els.fullscreenBtn.addEventListener('click', async () => {
    if (!document.fullscreenElement) {
      try { await document.documentElement.requestFullscreen(); } catch {}
    } else {
      try { await document.exitFullscreen(); } catch {}
    }
  });

  // Atualiza a árvore conforme a digitação, preservando a seleção válida.
  els.searchInput.addEventListener('input', event => {
    state.query = event.target.value || '';
    syncExpandedState(true);
    ensureSelectedDriver();
    renderCategories();
    renderDriverDetail();
  });
}

// Inicia somente com o HTML disponível. A configuração termina de carregar
// antes da primeira consulta de hardware e drivers.
window.addEventListener('DOMContentLoaded', async () => {
  initEls();
  bindEvents();
  startHeartbeat();
  await loadConfig();
  await loadData();
});
