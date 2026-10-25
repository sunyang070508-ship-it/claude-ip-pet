/* Claude IP 桌宠 — 检测逻辑（按 ip.net.coffee/claude 的测试项逐项复刻） */
(() => {
  'use strict';

  // ───────────────────────── 基础工具 ─────────────────────────
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const row = (k, v) => '<div class="row"><span class="k">' + k + '</span><span class="v">' + v + '</span></div>';
  const pad = (n) => String(n).padStart(2, '0');

  const CLAUDE_RESTRICTED_CC = {
    CN: '中国大陆', HK: '香港', MO: '澳门', RU: '俄罗斯', KP: '朝鲜',
    IR: '伊朗', SY: '叙利亚', CU: '古巴', BY: '白俄罗斯', VE: '委内瑞拉'
  };

  function flag(cc) {
    const c = String(cc || '').toLowerCase();
    if (!/^[a-z]{2}$/.test(c)) return '';
    const base = 0x1F1E6;
    return String.fromCodePoint(base + c.charCodeAt(0) - 97, base + c.charCodeAt(1) - 97);
  }
  function scoreLabel(score) {
    if (score >= 95) return { text: '极度纯净', cls: 'tag-safe' };
    if (score >= 80) return { text: '纯净', cls: 'tag-safe' };
    if (score >= 50) return { text: '良好', cls: 'tag-info' };
    if (score >= 25) return { text: '中性', cls: 'tag-warn' };
    return { text: '可疑', cls: 'tag-danger' };
  }
  function boolTag(val, trueText, falseText) {
    if (val === true) return '<span class="tag tag-danger">' + esc(trueText || '是') + '</span>';
    if (val === false) return '<span class="tag tag-safe">' + esc(falseText || '否') + '</span>';
    return '<span class="tag tag-neutral">未知</span>';
  }
  function shortIP(ip) {
    if (!ip) return '';
    return ip.includes(':') && ip.length > 20 ? ip.slice(0, 18) + '…' : ip;
  }
  // 默认隐藏 IP：IPv4 只留第一段，IPv6 只留第一组（比原站更强，避免旁观者看到地址）
  function maskIP(ip) {
    if (!ip) return '';
    const t = String(ip).trim();
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(t)) {
      return t.split('.')[0] + '.***.***.***';
    }
    if (t.includes(':')) {
      return (t.split(':')[0] || '****') + ':****:****:****';
    }
    if (t.includes('…')) {
      const i = t.lastIndexOf('…');
      return t.slice(0, i + 1) + '*';
    }
    return t;
  }
  function ipText(ip) {
    if (!ip) return '';
    return state.mask ? maskIP(ip) : shortIP(ip);
  }
  // IP 是否有问题：失败 / 非 IPv4（出口 IPv4 卡）/ 受限 / VPN·代理·Tor·滥用 / 低信任分 → 红色
  function ipLevel(ip, isClaude) {
    if (!ip) return 'bad';
    if (!isClaude && String(ip).includes(':')) return 'bad';
    if (isClaude) {
      const r = state.risk || {};
      if (restrictedName(r)) return 'bad';
      if (r.is_vpn === true || r.is_proxy === true || r.is_tor === true ||
          r.is_abuser === true || r.is_crawler === true) return 'bad';
      if (typeof r.trust_score === 'number' && r.trust_score < 50) return 'bad';
    }
    // 出口 IP 出现中国 IP → 红色（Claude 风控重点地区）
    const g = state.geo[ip] || {};
    const cc = String(g.country_code || '').toLowerCase();
    const country = String(g.country || '').toLowerCase();
    if (cc === 'cn' || country.includes('china') || country.includes('中国')) return 'bad';
    return 'ok';
  }
  function ipLink(ip, level) {
    if (!ip) return '<span class="ip-bad">获取失败</span>';
    const cls = level === 'bad' ? 'ip-bad' : (level === 'ok' ? 'ip-ok' : '');
    return '<a class="ip-link ' + cls + '" data-ip="' + esc(ip) + '" title="查看 ' + esc(ip) + ' 详情">' + esc(ipText(ip)) + '</a>';
  }
  function restrictedName(risk) {
    const cc = String(risk && risk.countryCode || '').toUpperCase();
    return cc ? (CLAUDE_RESTRICTED_CC[cc] || null) : null;
  }

  // ───────────────────────── 原生桥 ─────────────────────────
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.api;
  let seq = 0;
  const pending = new Map();

  window.__bridgeResult = (p) => {
    const cb = pending.get(p.id);
    if (!cb) return;
    pending.delete(p.id);
    if (p.cmd === 'api' && p.ok === false) cb.reject(new Error(p.error || ('HTTP ' + p.status)));
    else cb.resolve(p);
  };

  function bridgeCall(payload) {
    return new Promise((resolve, reject) => {
      if (!bridge) { reject(new Error('bridge-unavailable')); return; }
      const id = ++seq;
      pending.set(id, { resolve, reject });
      bridge.postMessage(Object.assign({}, payload, { id }));
    });
  }
  async function api(url, opts) {
    opts = opts || {};
    const p = await bridgeCall({ cmd: 'api', url, method: opts.method || 'GET', timeout: opts.timeout || 10000, body: opts.body || null });
    return {
      ok: !!p.ok,
      status: p.status || 0,
      text: p.text || '',
      json() { return JSON.parse(p.text || 'null'); }
    };
  }
  const storeGet = (key) => bridgeCall({ cmd: 'store', op: 'get', key }).then((p) => p.value || '');
  const storeSet = (key, value) => bridgeCall({ cmd: 'store', op: 'set', key, value });
  const appCmd = (action, extra) => bridgeCall(Object.assign({ cmd: 'app', action }, extra || {})).catch(() => {});

  // ───────────────────────── 状态 ─────────────────────────
  const state = {
    cfIP: null, cnIP: null, cnSource: null, claude: null, claudeLoc: null, mask: true,
    geo: {}, risk: null, dns: null, udp: null, avail: [], service: null, device: null,
    history: [], running: false, lastRun: 0
  };

  // ───────────────────────── 网络检测 ─────────────────────────
  async function fetchCfIP() {
    try {
      const r = await api('https://1.1.1.1/cdn-cgi/trace', { timeout: 6000 });
      if (!r.ok) return null;
      const m = r.text.match(/ip=([^\n]+)/);
      return m ? m[1].trim().replace(/\s+/g, '') : null;
    } catch { return null; }
  }

  async function fetchCNIP() {
    // 与原站“中国出口IPv4”卡对齐：浏览器是全局代理时，该卡显示的是代理出口。
    // 桌宠无法读取浏览器扩展代理，所以用站点回显（同一代理路径）取得同样的出口 IP；
    // 失败时回退到原站的 ip138 / ip.cn 直连源。
    try {
      const r = await api('https://ip.net.coffee/cdn-cgi/trace', { timeout: 6000 });
      if (r.ok) {
        const m = r.text.match(/ip=([^\n]+)/);
        const ip = m ? m[1].trim() : '';
        // 该卡只展示 IPv4；纯 IPv6 网络下站点回显是 IPv6，交给下面的 IPV4 源兜底
        if (ip && !ip.includes(':')) return { ip, source: '站点回显' };
      }
    } catch {}
    const sources = ['https://2026.ip138.com/', 'https://my.ip.cn/'];
    for (const url of sources) {
      try {
        const r = await api(url, { timeout: 6000 });
        if (!r.ok) continue;
        const m = r.text.match(/(\d+\.\d+\.\d+\.\d+)/);
        if (m) return { ip: m[1], source: url.includes('ip138') ? 'ip138' : 'ip.cn' };
      } catch {}
    }
    return null;
  }

  async function fetchClaudeTrace() {
    try {
      const r = await api('https://claude.ai/cdn-cgi/trace', { timeout: 8000 });
      if (!r.ok) return null;
      const entries = Object.fromEntries(r.text.trim().split('\n').map((l) => l.split('=')));
      return { ip: entries.ip || null, loc: (entries.loc || '').toLowerCase() || null };
    } catch { return null; }
  }

  async function fetchGeo(ips) {
    ips = [...new Set((ips || []).filter(Boolean))];
    const out = {};
    if (!ips.length) return out;
    if (ips.length >= 2) {
      try {
        const r = await api('https://ip.net.coffee/api/geoip-batch?ips=' + ips.join(','), { timeout: 8000 });
        if (r.ok) Object.assign(out, r.json() || {});
      } catch {}
    }
    const missing = ips.filter((ip) => !out[ip]);
    await Promise.all(missing.map(async (ip) => {
      try {
        const r = await api('https://ip.net.coffee/api/geoip/' + encodeURIComponent(ip), { timeout: 6000 });
        if (r.ok) { const g = r.json(); if (g && g.country) out[ip] = g; }
      } catch {}
    }));
    return out;
  }

  // 原站 main() 末尾的匿名会话上报（fire-and-forget），接口完全一致
  async function reportSession(claudeIP, cfIP, cnIP) {
    if (!claudeIP && !cfIP && !cnIP) return;
    try {
      await api('https://ip.net.coffee/api/session', {
        method: 'POST',
        body: JSON.stringify({ claude_ip: claudeIP || '', cf_ip: cfIP || '', cn_ip: cnIP || '' }),
        timeout: 5000
      });
    } catch {}
  }

  async function fetchRisk(ip) {
    try {
      const r = await api('https://ip.net.coffee/api/iprisk/' + encodeURIComponent(ip), { timeout: 12000 });
      if (!r.ok) return null;
      return r.json();
    } catch { return null; }
  }

  async function checkDNS() {
    const token = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
    for (let i = 1; i <= 2; i++) {
      try { await api('https://' + token + '-' + i + '.d.ip.net.coffee/pixel.gif?_=' + Date.now(), { timeout: 5000 }); } catch {}
    }
    await sleep(1500);
    let servers = [];
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await api('https://ip.net.coffee/api/dns/result/' + token, { timeout: 5000 });
        if (r.ok) {
          const d = r.json();
          servers = (d && d.dns_servers) || [];
          if (servers.length) break;
        }
      } catch {}
      if (attempt === 0) await sleep(1500);
    }
    if (!servers.length) { state.dns = { empty: true, servers: [] }; renderDNS(); return; }

    const claudeCountry = ((state.risk && state.risk.country) || (state.geo[state.claude] || {}).country || '').toLowerCase();
    const claudeInChina = claudeCountry.includes('china') || claudeCountry.includes('中国');
    const geos = await fetchGeo(servers);
    let show = null, leaked = false;
    for (const ip of servers) {
      const g = geos[ip] || {};
      const cc = (g.country_code || '').toLowerCase();
      const isCN = cc === 'cn';
      if (isCN && !claudeInChina) { show = { ip, cc, isp: g.isp, leaked: true }; leaked = true; break; }
      if (!show) show = { ip, cc, isp: g.isp, leaked: false };
    }
    state.dns = { empty: false, servers, show, leaked };
    renderDNS();
  }

  async function checkUDP() {
    const udp = new Set();
    try {
      const pc = new RTCPeerConnection({
        iceServers: [
          { urls: 'stun:stun.l.google.com:19302' },
          { urls: 'stun:stun.cloudflare.com:3478' }
        ]
      });
      pc.createDataChannel('');
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await new Promise((resolve) => {
        const timeout = setTimeout(() => { try { pc.close(); } catch {} resolve(); }, 5000);
        pc.onicecandidate = (e) => {
          if (!e.candidate) { clearTimeout(timeout); try { pc.close(); } catch {} resolve(); return; }
          const c = e.candidate.candidate;
          const m = c.match(/([0-9]{1,3}\.){3}[0-9]{1,3}/);
          if (m) {
            const ip = m[0];
            if (!ip.startsWith('0.') && !ip.startsWith('127.') && ip !== '0.0.0.0') udp.add(ip);
          }
          const m6 = c.match(/([a-f0-9]{1,4}:){2,7}[a-f0-9]{1,4}/i);
          if (m6) udp.add(m6[0]);
        };
      });
    } catch {
      state.udp = { status: 'disabled', all: [], pub: [] };
      renderUDP();
      return;
    }
    const all = [...udp];
    const pub = all.filter((ip) => !ip.includes(':') && !/^(192\.168\.|10\.|172\.|198\.18\.|198\.19\.|100\.64\.|127\.|0\.)/.test(ip));
    const claudeIP = state.claude || '';
    if (!pub.length) { state.udp = { status: all.length ? 'no-public' : 'disabled', all, pub }; renderUDP(); return; }
    const leakIP = claudeIP ? pub.find((ip) => ip !== claudeIP) : undefined;
    const show = leakIP || pub.find((ip) => ip === claudeIP) || pub[0];
    const geos = await fetchGeo([show]);
    state.udp = { status: leakIP ? 'leak' : 'ok', all, pub, show, geo: geos[show] || {}, matches: show === claudeIP };
    renderUDP();
  }

  async function probe(url, timeout) {
    const start = performance.now();
    try {
      const r = await api(url, { timeout });
      return { ok: r.ok, ms: Math.round(performance.now() - start) };
    } catch {
      return { ok: false, ms: -1 };
    }
  }

  async function checkAvailability() {
    const targets = [
      { name: 'claude.ai', url: 'https://claude.ai/cdn-cgi/trace' },
      { name: 'anthropic.com', url: 'https://www.anthropic.com/cdn-cgi/trace' }
    ];
    // 先预热连接再计时，否则首包 DNS+TLS 会把时延算进去
    await Promise.all(targets.map((t) => probe(t.url, 6000)));
    state.avail = await Promise.all(targets.map(async (t) => {
      const r = await probe(t.url, 6000);
      return { name: t.name, ms: r.ms, ok: r.ok };
    }));
    try {
      const r = await api('https://ip.net.coffee/claude/status.json', { timeout: 4000 });
      if (r.ok) state.service = r.json();
    } catch {}
    renderAvail();
  }

  // ───────────────────────── 设备信息 ─────────────────────────
  const CC_TO_TZ = {
    CN: 'Asia/Shanghai', TW: 'Asia/Taipei', HK: 'Asia/Hong_Kong', MO: 'Asia/Macau',
    JP: 'Asia/Tokyo', KR: 'Asia/Seoul', SG: 'Asia/Singapore', MY: 'Asia/Kuala_Lumpur',
    TH: 'Asia/Bangkok', VN: 'Asia/Ho_Chi_Minh', ID: 'Asia/Jakarta', PH: 'Asia/Manila',
    IN: 'Asia/Kolkata', PK: 'Asia/Karachi', BD: 'Asia/Dhaka',
    IR: 'Asia/Tehran', IL: 'Asia/Jerusalem', AE: 'Asia/Dubai', SA: 'Asia/Riyadh',
    TR: 'Europe/Istanbul', RU: 'Europe/Moscow', UA: 'Europe/Kyiv',
    GB: 'Europe/London', IE: 'Europe/Dublin', FR: 'Europe/Paris', DE: 'Europe/Berlin',
    IT: 'Europe/Rome', ES: 'Europe/Madrid', PT: 'Europe/Lisbon', NL: 'Europe/Amsterdam',
    BE: 'Europe/Brussels', CH: 'Europe/Zurich', AT: 'Europe/Vienna',
    SE: 'Europe/Stockholm', NO: 'Europe/Oslo', DK: 'Europe/Copenhagen', FI: 'Europe/Helsinki',
    PL: 'Europe/Warsaw', CZ: 'Europe/Prague', GR: 'Europe/Athens', RO: 'Europe/Bucharest',
    US: 'America/Los_Angeles', CA: 'America/Toronto', MX: 'America/Mexico_City',
    BR: 'America/Sao_Paulo', AR: 'America/Argentina/Buenos_Aires', CL: 'America/Santiago',
    AU: 'Australia/Sydney', NZ: 'Pacific/Auckland',
    ZA: 'Africa/Johannesburg', EG: 'Africa/Cairo', NG: 'Africa/Lagos', KE: 'Africa/Nairobi'
  };

  const LANG_MAP = {
    CN: ['zh'], TW: ['zh'], HK: ['zh', 'en'], MO: ['zh', 'en'],
    JP: ['ja'], KR: ['ko'], TH: ['th'], VN: ['vi'],
    SG: ['en', 'zh', 'ms', 'ta'], MY: ['ms', 'en', 'zh', 'ta'],
    ID: ['id', 'en'], PH: ['en', 'tl', 'fil'],
    IN: ['en', 'hi'], PK: ['ur', 'en'], BD: ['bn', 'en'],
    LK: ['si', 'ta', 'en'], NP: ['ne', 'en'],
    US: ['en'], GB: ['en'], IE: ['en', 'ga'],
    AU: ['en'], NZ: ['en', 'mi'], CA: ['en', 'fr'],
    DE: ['de'], AT: ['de'], CH: ['de', 'fr', 'it', 'rm'],
    BE: ['nl', 'fr', 'de'], FR: ['fr'], IT: ['it'], ES: ['es', 'ca', 'gl', 'eu'],
    PT: ['pt'], NL: ['nl', 'fy'], LU: ['lb', 'fr', 'de'],
    SE: ['sv'], NO: ['no', 'nb', 'nn'], DK: ['da'], FI: ['fi', 'sv'], IS: ['is', 'en'],
    PL: ['pl'], CZ: ['cs'], SK: ['sk'], HU: ['hu'], RO: ['ro'], BG: ['bg'], GR: ['el'],
    RU: ['ru'], UA: ['uk', 'ru'], BY: ['be', 'ru'],
    TR: ['tr'], IL: ['he', 'ar', 'en'], SA: ['ar'], AE: ['ar', 'en'], EG: ['ar'],
    IR: ['fa'], IQ: ['ar', 'ku'], ZA: ['en', 'af', 'zu', 'xh'], KE: ['en', 'sw'],
    NG: ['en'], ET: ['am', 'en'], BR: ['pt'], AR: ['es'], MX: ['es'], CL: ['es'],
    CO: ['es'], PE: ['es'], VE: ['es']
  };

  function currentOffsetMinutes(tzName) {
    if (!tzName) return null;
    try {
      const parts = new Intl.DateTimeFormat('en-US', { timeZone: tzName, timeZoneName: 'longOffset' }).formatToParts(new Date());
      const p = parts.find((x) => x.type === 'timeZoneName');
      if (!p) return null;
      if (p.value === 'GMT' || p.value === 'UTC') return 0;
      const m = p.value.match(/GMT([+-])(\d{1,2}):?(\d{0,2})/);
      if (!m) return null;
      return (m[1] === '+' ? 1 : -1) * (parseInt(m[2], 10) * 60 + parseInt(m[3] || '0', 10));
    } catch { return null; }
  }
  function formatOffsetHours(mins) {
    if (mins == null) return '';
    const sign = mins >= 0 ? '+' : '-';
    const abs = Math.abs(mins);
    const h = Math.floor(abs / 60), m = abs % 60;
    return 'UTC' + sign + h + (m ? ':' + String(m).padStart(2, '0') : '');
  }

  function computeDevice() {
    const localTz = Intl.DateTimeFormat().resolvedOptions().timeZone || '未知';
    const localOffset = -(new Date().getTimezoneOffset() / 60);
    const localUtc = 'UTC' + (localOffset >= 0 ? '+' : '') + localOffset;
    const risk = state.risk || {};
    const cc = (risk.countryCode || '').toUpperCase();
    const claudeTz = risk.timezone || CC_TO_TZ[cc] || '';
    const tzIsExact = !!risk.timezone;
    const claudeOffMin = currentOffsetMinutes(claudeTz);
    const localOffMin = -new Date().getTimezoneOffset();
    let tzMatch = null;
    if (claudeTz && claudeOffMin != null) tzMatch = Math.abs(claudeOffMin - localOffMin) <= 60;
    const localIsCN = localTz === 'Asia/Shanghai' || localTz === 'Asia/Urumqi';

    let tzHtml = '';
    if (localIsCN) {
      let claudeLine = 'Claude 出口: 未知';
      if (claudeTz && claudeOffMin != null) {
        const diff = claudeOffMin - localOffMin;
        const diffHours = Math.round(diff / 60);
        const diffLabel = diff === 0 ? '偏移一致' : diffHours === 0 ? '偏移略有差异' : (diffHours > 0 ? 'Claude 快 ' + diffHours + ' 小时' : 'Claude 慢 ' + (-diffHours) + ' 小时');
        claudeLine = 'Claude 出口: ' + (tzIsExact ? claudeTz : claudeTz + '（按地区估算）') + ' (' + formatOffsetHours(claudeOffMin) + ') — ' + diffLabel;
      }
      tzHtml = '<span class="tag tag-warn">不推荐使用中国大陆时区</span><br><span class="dim">本地: ' + esc(localTz) + ' (' + esc(localUtc) + ')<br>' + esc(claudeLine) + '</span>';
    } else if (tzMatch === true) {
      tzHtml = '<span class="tag tag-safe">时区一致</span> <span class="dim">' + esc(localTz) + ' (' + esc(localUtc) + ')</span>';
    } else if (tzMatch === false) {
      const diff = claudeOffMin - localOffMin;
      const diffHours = Math.round(diff / 60);
      const diffLabel = diff === 0 ? '偏移一致' : diffHours === 0 ? '偏移略有差异' : (diffHours > 0 ? 'Claude 快 ' + diffHours + ' 小时' : 'Claude 慢 ' + (-diffHours) + ' 小时');
      tzHtml = '<span class="tag tag-warn">时区不一致</span><br><span class="dim">本地: ' + esc(localTz) + ' (' + esc(localUtc) + ')<br>Claude 出口: ' + esc((tzIsExact ? claudeTz : claudeTz + '（按地区估算）') + ' (' + formatOffsetHours(claudeOffMin) + ') — ' + diffLabel) + '</span>';
    } else {
      tzHtml = '<span class="dim">' + esc(localTz) + ' (' + esc(localUtc) + ')</span>';
    }

    const localLangs = navigator.languages || [navigator.language];
    const langsStr = localLangs.join(', ') || '未知';
    const localPrimary = (localLangs[0] || '').split('-')[0].toLowerCase();
    const regionLangs = LANG_MAP[cc] || [];
    const langMatch = (localPrimary && regionLangs.length) ? regionLangs.includes(localPrimary) : null;
    let langHtml = '';
    if (langMatch === true) langHtml = '<span class="tag tag-safe">语言一致</span> <span class="dim">' + esc(langsStr) + '</span>';
    else if (langMatch === false) langHtml = '<span class="tag tag-warn">语言不一致</span><br><span class="dim">本地: ' + esc(langsStr) + '<br>Claude 出口所在地常用: ' + esc(regionLangs.join(' / ')) + '</span>';
    else langHtml = '<span class="dim">' + esc(langsStr) + '</span>';

    const ua = navigator.userAgent;
    let os = '未知', browser = '未知';
    if (ua.includes('Windows')) os = 'Windows';
    else if (ua.includes('Mac OS')) os = 'macOS';
    else if (ua.includes('iPhone') || ua.includes('iPad')) os = 'iOS';
    else if (ua.includes('Android')) os = 'Android';
    else if (ua.includes('Linux')) os = 'Linux';
    if (ua.includes('Edg/')) browser = 'Edge ' + (ua.match(/Edg\/([\d.]+)/) || [])[1];
    else if (ua.includes('Chrome/')) browser = 'Chrome ' + (ua.match(/Chrome\/([\d.]+)/) || [])[1];
    else if (ua.includes('Firefox/')) browser = 'Firefox ' + (ua.match(/Firefox\/([\d.]+)/) || [])[1];
    else if (ua.includes('Safari/') && !ua.includes('Chrome')) browser = 'Safari ' + (ua.match(/Version\/([\d.]+)/) || [])[1];
    else if (ua.includes('AppleWebKit')) browser = 'Safari 内核 (WKWebView)';

    let webglRenderer = '不支持';
    try {
      const canvas = document.createElement('canvas');
      const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
      if (gl) {
        const ext = gl.getExtension('WEBGL_debug_renderer_info');
        if (ext) webglRenderer = gl.getParameter(ext.UNMASKED_RENDERER_WEBGL);
      }
    } catch {}

    let webglHash = '不支持';
    try {
      const canvas = document.createElement('canvas');
      const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
      if (gl) {
        const ext = gl.getExtension('WEBGL_debug_renderer_info');
        const vendor = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : '';
        const renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : '';
        const str = vendor + '~' + renderer + '~' + gl.getParameter(gl.VERSION) + '~' + gl.getParameter(gl.SHADING_LANGUAGE_VERSION);
        let h = 0;
        for (let i = 0; i < str.length; i++) h = ((h << 5) - h + str.charCodeAt(i)) | 0;
        webglHash = (h >>> 0).toString(16).toUpperCase();
      }
    } catch {}

    let canvasHash = '不支持';
    try {
      const canvas = document.createElement('canvas');
      canvas.width = 200; canvas.height = 50;
      const ctx = canvas.getContext('2d');
      ctx.textBaseline = 'top';
      ctx.font = '14px Arial';
      ctx.fillStyle = '#f60';
      ctx.fillRect(50, 0, 100, 50);
      ctx.fillStyle = '#069';
      ctx.fillText('net.coffee', 2, 15);
      ctx.fillStyle = 'rgba(102,204,0,0.7)';
      ctx.fillText('canvas fp', 4, 30);
      const data = canvas.toDataURL();
      let hash = 0;
      for (let i = 0; i < data.length; i++) hash = ((hash << 5) - hash + data.charCodeAt(i)) | 0;
      canvasHash = (hash >>> 0).toString(16).toUpperCase();
    } catch {}

    return {
      tzHtml, langHtml,
      os, browser,
      cookie: navigator.cookieEnabled ? '<span class="tag tag-safe">已启用</span>' : '<span class="tag tag-warn">已禁用</span>',
      webglRenderer, canvasHash, webglHash
    };
  }

  // ───────────────────────── 渲染 ─────────────────────────
  function renderIPs() {
    const cards = [
      { label: '中国出口IPv4', src: state.cnSource || 'ip138 / ip.cn', ip: state.cnIP, geo: state.geo[state.cnIP] },
      { label: 'Cloudflare 出口IP', src: '1.1.1.1 trace', ip: state.cfIP, geo: state.geo[state.cfIP] },
      { label: 'Claude AI出口IP', src: 'claude.ai trace', ip: state.claude, geo: state.geo[state.claude] }
    ];
    let hasV6 = false;
    const html = cards.map((c) => {
      const label = '<div class="ipcard-label">' + c.label + '<span class="src">' + c.src + '</span></div>';
      if (!c.ip) return '<div class="ipcard">' + label + '<div class="ipcard-ip" style="color:#8a7d73;font-family:inherit;font-size:12px">获取失败</div></div>';
      if (String(c.ip).includes(':')) hasV6 = true;
      const g = c.geo || {};
      let geoText = state.mask
        ? [g.country].filter(Boolean).join(' ') + (g.country ? ' · (已隐藏)' : '')
        : [g.country, g.region, g.city, g.isp].filter(Boolean).join(' ');
      if (!geoText && c.ip === state.claude && state.claudeLoc) geoText = state.claudeLoc.toUpperCase();
      const cc = g.country_code || (c.ip === state.claude ? state.claudeLoc : '');
      const level = ipLevel(c.ip, c.ip === state.claude);
      return '<div class="ipcard">' + label +
        '<div class="ipcard-ip"><span class="flag">' + flag(cc) + '</span>' + ipLink(c.ip, level) + '</div>' +
        '<div class="ipcard-geo">' + (esc(geoText) || '归属地未知') + '</div></div>';
    }).join('');
    $('ipCards').innerHTML = html;
    $('ipv6Warn').classList.toggle('hidden', !hasV6);
  }

  function renderTrust() {
    const el = $('trustContent');
    const warn = $('regionWarn');
    const rn = restrictedName(state.risk);
    const hasClaude = !!state.claude;
    let score = null;
    if (hasClaude) {
      if (rn) score = 0;
      else if (state.risk && typeof state.risk.trust_score === 'number') score = state.risk.trust_score;
    }
    let html = '';
    if (score === null) {
      html = '<div class="trust-top"><div class="trust-score" style="color:#9ca3af">—<span class="of">/ 100</span></div>' +
        '<div class="trust-side"><span class="tag tag-neutral">无数据</span></div></div>' +
        '<div class="gauge"><div class="pointer" style="left:0%;opacity:.25"></div></div>' +
        '<div class="trust-phrase">' + (hasClaude ? '该 IP 暂无评分数据' : '未获取到 Claude AI 出口 IP，无法评分') + '</div>';
    } else {
      const sl = rn ? { text: '不可访问', cls: 'tag-danger' } : scoreLabel(score);
      const color = score >= 95 ? '#22c55e' : score >= 80 ? '#16a34a' : score >= 50 ? '#84cc16' : score >= 25 ? '#eab308' : '#ef4444';
      const phrase = rn ? '处于不可访问区域，Claude 会严格风控'
        : score >= 95 ? '该 IP 信誉极好' : score >= 80 ? '该 IP 信誉优异' : score >= 50 ? '该 IP 存在轻微风险' : score >= 25 ? '该 IP 存在一定风险' : '该 IP 风险极高';
      const support = !rn && hasClaude && state.risk && state.risk.countryCode
        ? '<div class="row" style="margin-top:9px"><span class="k">Claude 支持地区</span><span class="v"><span class="tag tag-safe">正常</span></span></div>'
        : '';
      html = '<div class="trust-top"><div class="trust-score" style="color:' + color + '">' + score + '<span class="of">/ 100</span></div>' +
        '<div class="trust-side"><span class="tag ' + sl.cls + '">' + sl.text + '</span><div class="trust-phrase">' + phrase + '</div></div></div>' +
        '<div class="gauge"><div class="pointer" style="left:' + Math.min(score, 100) + '%"></div></div>' +
        '<div class="gauge-scale"><span>0 不可访问</span><span>25</span><span>50</span><span>75</span><span>100 可信</span></div>' + support;
    }
    el.innerHTML = html;
    if (rn) {
      warn.innerHTML = '<span class="icon">⚠️</span>当前 Claude 出口 IP 位于<strong>' + esc(rn) + '</strong>，不建议尝试登录 Claude，容易触发封号风控！';
      warn.classList.remove('hidden');
    } else {
      warn.classList.add('hidden');
    }
  }

  function renderProps() {
    const r = state.risk || {};
    const g = state.geo[state.claude] || {};
    const isRes = r.isResidential !== undefined ? r.isResidential
      : (typeof r.is_datacenter === 'boolean' ? !r.is_datacenter : null);
    let propTag = isRes === true ? '<span class="tag tag-safe">家庭住宅IP</span>'
      : isRes === false ? '<span class="tag tag-warn">机房IP</span>'
      : '<span class="tag tag-neutral">未知</span>';
    if (r.company_type) propTag += ' <span class="dim">(' + esc(r.company_type) + ')</span>';
    const region = g.country || r.country || '未知';
    const city = state.mask ? '***（已隐藏）' : (g.city || r.city || g.country || r.country || '未知');
    $('propsContent').innerHTML =
      row('地区', esc(region)) +
      row('城市', esc(city)) +
      row('IP 属性', propTag) +
      row('ASN', r.asn ? 'AS' + esc(r.asn) : '未知') +
      row('运营商', esc(r.asOrganization || g.isp || r.company_name || '未知'));
  }

  function renderSecurity() {
    const r = state.risk || {};
    $('securityContent').innerHTML =
      row('VPN', boolTag(r.is_vpn, 'VPN', '未检测到')) +
      row('代理 (Proxy)', boolTag(r.is_proxy, '代理', '未检测到')) +
      row('Tor', boolTag(r.is_tor, 'Tor', '未检测到')) +
      row('机器人 (Crawler)', boolTag(r.is_crawler, '是', '否')) +
      row('滥用记录', boolTag(r.is_abuser, '有记录', '无记录'));
  }

  function renderAvail() {
    const rn = restrictedName(state.risk);
    let rows = '';
    (state.avail || []).forEach((a) => {
      if (rn) { rows += row(esc(a.name), '<span class="tag tag-danger">不可访问</span>'); return; }
      if (a.ok) {
        const cls = a.ms < 500 ? 'tag-safe' : 'tag-warn';
        const label = a.ms < 250 ? '正常' : a.ms < 500 ? '良好' : '较慢';
        rows += row(esc(a.name), '<span class="tag ' + cls + '">' + label + '</span> <span class="dim">' + a.ms + 'ms</span>');
      } else {
        rows += row(esc(a.name), '<span class="tag tag-danger">不可访问</span>');
      }
    });
    if (state.service) {
      const ind = state.service.overall_indicator || 'none';
      const map = {
        none: ['全部服务正常', 'tag-safe'], minor: ['轻微故障', 'tag-warn'],
        major: ['重大故障', 'tag-danger'], critical: ['严重故障', 'tag-danger'], maintenance: ['维护中', 'tag-warn']
      };
      const v = map[ind] || ['服务异常', 'tag-warn'];
      rows += row('Claude 服务状态', '<a class="hint-link" style="margin:0;border:none;padding:0;color:inherit" data-open="https://ip.net.coffee/claude/status.html"><span class="tag ' + v[1] + '">' + v[0] + '</span></a>');
    }
    $('availContent').innerHTML = rows || '<div class="loading">检测中…</div>';
  }

  function renderDNS() {
    const el = $('dnsContent');
    const d = state.dns;
    if (!d) { el.innerHTML = '<div class="loading">检测中…</div>'; return; }
    if (d.empty) { el.innerHTML = row('状态', '<span class="tag tag-bad">DNS 加密或未暴露出口（无法确认）</span>'); return; }
    let rows = row('状态', d.leaked ? '<span class="tag tag-bad">可能泄露</span>' : '<span class="tag tag-safe">未检测到泄露</span>');
    if (d.show) {
      const dnsBad = d.show.leaked;
      rows += row('DNS 出口 IP', flag(d.show.cc) + ' <span class="' + (dnsBad ? 'ip-bad' : '') + '" style="font-family:var(--mono)">' + esc(state.mask ? maskIP(d.show.ip) : d.show.ip) + '</span>' +
        (dnsBad ? ' <span class="tag tag-bad">中国 DNS</span>' : ''));
      if (d.show.isp) rows += row('服务商', '<span class="dim">' + esc(d.show.isp) + '</span>');
    }
    if (d.servers.length > 1) rows += row('DNS 出口数量', '<span class="dim">' + d.servers.length + ' 个</span>');
    el.innerHTML = rows;
  }

  function renderUDP() {
    const el = $('udpContent');
    const u = state.udp;
    if (!u) { el.innerHTML = '<div class="loading">检测中…</div>'; return; }
    if (u.status === 'disabled') { el.innerHTML = row('状态', '<span class="tag tag-safe">WebRTC 已禁用或无泄露</span>'); return; }
    if (u.status === 'no-public') { el.innerHTML = row('状态', '<span class="tag tag-safe">未检测到泄露</span>'); return; }
    let rows = row('状态', u.status === 'leak' ? '<span class="tag tag-warn">可能泄露</span>' : '<span class="tag tag-safe">未检测到泄露</span>');
    const g = u.geo || {};
    rows += row('UDP 出口', flag(g.country_code) + ' <span style="font-family:var(--mono)">' + esc(ipText(u.show)) + '</span>' +
      (!u.matches ? ' <span class="tag tag-warn">异常</span>' : ''));
    if (g.country) rows += row('归属地', '<span class="dim">' + esc(g.country) + '</span>');
    el.innerHTML = rows;
  }

  function renderDevice() {
    const d = state.device || computeDevice();
    $('deviceContent').innerHTML =
      row('时区', d.tzHtml) +
      row('语言', d.langHtml) +
      row('操作系统 / 浏览器', esc(d.os + ' / ' + d.browser)) +
      row('Cookie', d.cookie) +
      row('WebGL 渲染器', '<span class="dim">' + esc(d.webglRenderer) + '</span>') +
      row('Canvas 指纹', '<span style="font-family:var(--mono)">' + esc(d.canvasHash) + '</span>') +
      row('WebGL 指纹', '<span style="font-family:var(--mono)">' + esc(d.webglHash) + '</span>');
  }

  function renderHistory() {
    const el = $('historyContent');
    const hint = $('historyHint');
    if (hint) hint.textContent = state.history.length + ' 条记录，100% 隐私友好，历史数据仅本地存储，方便查阅';
    if (!state.history.length) { el.innerHTML = '<div class="loading">暂无历史记录</div>'; return; }
    el.innerHTML = state.history.map((h, i) => {
      const d = new Date(h.time);
      const time = (d.getMonth() + 1) + '-' + d.getDate() + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
      return '<div class="hist-row">' +
        '<span class="hist-time">' + time + (i === 0 ? ' <span class="hist-current">当前</span>' : '') + '</span>' +
        '<span class="hist-main">' + flag(h.cc) + '<a class="ip-link hist-ip" data-ip="' + esc(h.ip) + '">' + esc(ipText(h.ip)) + '</a>' +
        '<span class="hist-geo">' + esc(state.mask ? '已隐藏' : (h.geo || '')) + '</span></span></div>';
    }).join('');
  }

  // ───────────────────────── 历史记录 ─────────────────────────
  async function loadHistory() {
    try {
      const raw = await storeGet('claude_ip_history');
      state.history = raw ? (JSON.parse(raw) || []) : [];
    } catch { state.history = []; }
    if (!Array.isArray(state.history)) state.history = [];
    renderHistory();
  }

  async function saveHistory() {
    const ip = state.claude;
    if (!ip) { renderHistory(); return; }
    const now = new Date();
    const cc = (state.risk && state.risk.countryCode || '').toLowerCase();
    const geo = (state.risk && state.risk.city) || (state.geo[ip] || {}).city || '';
    const entry = { ip, cc, geo, time: now.toISOString() };
    const history = state.history;
    if (history.length) {
      const last = history[0];
      const hours = (now - new Date(last.time)) / 36e5;
      if (last.ip === ip && hours < 24) { renderHistory(); return; }
    }
    history.unshift(entry);
    if (history.length > 6) history.length = 6;
    state.history = history;
    try { await storeSet('claude_ip_history', JSON.stringify(history)); } catch {}
    renderHistory();
  }

  // ───────────────────────── 状态栏 / 徽标 ─────────────────────────
  function setUpdated(text) { $('updated').textContent = text; }
  function setBusy(busy) {
    const btn = $('btnRefresh');
    btn.classList.toggle('spin', busy);
    updateBadge();
  }
  function updateBadge() {
    const badge = $('petBadge');
    const text = $('badgeText');
    const rn = restrictedName(state.risk);
    let score = null;
    if (state.claude) {
      if (rn) score = 0;
      else if (state.risk && typeof state.risk.trust_score === 'number') score = state.risk.trust_score;
    }
    if (state.running && score === null) { badge.className = 'pet-badge run'; text.textContent = '…'; return; }
    if (score === null) { badge.className = 'pet-badge'; text.textContent = state.claude ? '?' : '!'; return; }
    badge.className = 'pet-badge ' + (score >= 80 ? 'ok' : score >= 50 ? 'warn' : 'bad');
    text.textContent = String(score);
  }

  // 检测反馈 toast
  let toastTimer = 0;
  function showToast(text, kind, duration) {
    const el = $('toast');
    if (!el) return;
    el.textContent = text;
    el.className = 'toast show ' + (kind || 'info');
    clearTimeout(toastTimer);
    if (duration && duration > 0) {
      toastTimer = setTimeout(() => { el.className = 'toast hidden'; }, duration);
    }
  }
  function hideToast() {
    const el = $('toast');
    if (el) el.className = 'toast hidden';
  }

  // ───────────────────────── 主流程 ─────────────────────────
  let runSeq = 0;
  async function runAll() {
    if (state.running) return;
    const mySeq = ++runSeq;
    state.running = true;
    setBusy(true);
    setUpdated('正在检测…');
    showToast('正在重新检测…', 'info', 0);
    const started = Date.now();

    try {
      const cfP = fetchCfIP().catch(() => null);
      const cnP = fetchCNIP().catch(() => null);
      const clP = fetchClaudeTrace().catch(() => null);

      // Claude 出口 IP + 风险（主内容，优先渲染）
      const cl = await clP;
      state.claude = cl ? cl.ip : null;
      state.claudeLoc = cl ? cl.loc : null;
      renderIPs();
      const risk = state.claude ? await fetchRisk(state.claude) : null;
      state.risk = risk;
      state.geo = Object.assign({}, state.geo, await fetchGeo([state.claude].filter(Boolean)));
      renderTrust();
      renderProps();
      renderSecurity();
      renderIPs();
      updateBadge();

      // 其余泄露 / 可用性检测并行启动
      const restP = Promise.allSettled([checkDNS(), checkUDP(), checkAvailability()]);

      // 中国出口 / Cloudflare 出口
      const [cf, cn] = await Promise.all([cfP, cnP]);
      state.cfIP = cf;
      state.cnIP = cn ? cn.ip : null;
      state.cnSource = cn ? cn.source : null;
      state.geo = Object.assign({}, state.geo, await fetchGeo([state.cfIP, state.cnIP].filter(Boolean)));
      renderIPs();

      state.device = computeDevice();
      renderDevice();

      await restP;
      if (mySeq !== runSeq) return;

      await saveHistory();
      reportSession(state.claude, state.cfIP, state.cnIP);  // 与原站一致：匿名上报后立即更新 UI
      state.lastRun = Date.now();
      const elapsed = ((Date.now() - started) / 1000).toFixed(1);
      setUpdated('更新 ' + pad(new Date().getHours()) + ':' + pad(new Date().getMinutes()) + ' · 用时 ' + elapsed + 's');
      showToast('✓ 检测完成 · 用时 ' + elapsed + 's', 'ok', 2800);
    } catch (e) {
      console.error(e);
      setUpdated('检测出错');
      showToast('检测出错，请稍后重试', 'err', 3200);
    } finally {
      state.running = false;
      setBusy(false);
      updateBadge();
    }
  }

  // ───────────────────────── UI 绑定 ─────────────────────────
  function maybeRefresh() {
    if (!state.lastRun || Date.now() - state.lastRun > 10 * 60 * 1000) runAll();
  }

  // ───────────────────────── 右键菜单（HTML） ─────────────────────────
  let ctxTimer = 0;
  function showCtxMenu() {
    const menu = $('ctxMenu');
    if (!menu) return;
    const toggle = $('ctxToggle');
    if (toggle) toggle.textContent = $('stage').dataset.state === 'expanded' ? '收起结果面板' : '展开检测结果';
    menu.classList.remove('hidden');
    appCmd('menu', { open: true });
    clearTimeout(ctxTimer);
    ctxTimer = setTimeout(hideCtxMenu, 6000);
  }
  function hideCtxMenu() {
    const menu = $('ctxMenu');
    if (!menu || menu.classList.contains('hidden')) return;
    menu.classList.add('hidden');
    clearTimeout(ctxTimer);
    appCmd('menu', { open: false });
  }

  let helloTimer = 0;
  window.petUI = {
    setExpanded(v) {
      const stage = $('stage');
      const wasExpanded = stage.dataset.state === 'expanded';
      stage.dataset.state = v ? 'expanded' : 'collapsed';
      hideCtxMenu();
      if (v && !wasExpanded) {
        $('panelBody').scrollTop = 0;
        maybeRefresh();
      }
    },
    refresh() { runAll(); },
    toast(text, kind, duration) { showToast(text, kind, duration); },
    setMask(maskEnabled) {
      const t = $('ipMaskToggle');
      if (t) t.checked = !maskEnabled;
      state.mask = !!maskEnabled;
      renderIPs(); renderProps(); renderDNS(); renderUDP(); renderHistory();
    },
    // 第二次双击 App 时，把桌宠叫回屏幕并提示
    hello() {
      const pet = $('pet');
      const bubble = pet && pet.querySelector('.pet-bubble');
      if (!bubble) return;
      bubble.textContent = '我在这里，点我看结果';
      pet.classList.add('hello');
      clearTimeout(helloTimer);
      helloTimer = setTimeout(() => {
        pet.classList.remove('hello');
        bubble.textContent = '点击查看 Claude IP 检测结果';
      }, 2400);
    }
  };

  $('btnRefresh').addEventListener('click', () => runAll());
  // “显示IP”开关：默认关闭 = 隐藏；打开才显示完整 IP
  $('ipMaskToggle').addEventListener('change', (e) => {
    state.mask = !e.target.checked;
    renderIPs();
    renderProps();
    renderDNS();
    renderUDP();
    renderHistory();
  });
  $('btnSite').addEventListener('click', () => appCmd('open', { url: 'https://ip.net.coffee/claude/' }));
  $('btnCollapse').addEventListener('click', () => appCmd('collapse'));

  // 右键桌宠 → HTML 菜单
  document.addEventListener('contextmenu', (e) => {
    const pet = $('pet');
    if (pet && pet.contains(e.target)) {
      e.preventDefault();
      showCtxMenu();
    }
  });
  $('ctxMenu').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-cmd]');
    if (!btn) return;
    const cmd = btn.dataset.cmd;
    hideCtxMenu();
    if (cmd === 'refresh') runAll();
    else if (cmd === 'toggle') appCmd('toggle');
    else if (cmd === 'recenter') appCmd('recenter');
    else if (cmd === 'site') appCmd('open', { url: 'https://ip.net.coffee/claude/' });
    else if (cmd === 'quit') appCmd('quit');
  });
  document.addEventListener('mousedown', (e) => {
    const menu = $('ctxMenu');
    if (menu && !menu.classList.contains('hidden') && !menu.contains(e.target)) hideCtxMenu();
  });
  window.addEventListener('blur', hideCtxMenu);
  $('btnClearHistory').addEventListener('click', async () => {
    state.history = [];
    try { await storeSet('claude_ip_history', '[]'); } catch {}
    renderHistory();
  });

  document.addEventListener('click', (e) => {
    const opener = e.target.closest && e.target.closest('[data-open]');
    if (opener) { e.preventDefault(); appCmd('open', { url: opener.dataset.open }); return; }
    const runner = e.target.closest && e.target.closest('[data-run]');
    if (runner) { e.preventDefault(); runAll(); return; }
    const a = e.target.closest && e.target.closest('a[href^="http"]');
    if (a) { e.preventDefault(); appCmd('open', { url: a.href }); return; }
    const link = e.target.closest && e.target.closest('.ip-link');
    if (link && link.dataset.ip) {
      e.preventDefault();
      appCmd('open', { url: 'https://ip.net.coffee/ip/' + encodeURIComponent(link.dataset.ip) });
    }
  });

  // 启动
  loadHistory().then(() => {
    updateBadge();
    runAll();
  });
})();
