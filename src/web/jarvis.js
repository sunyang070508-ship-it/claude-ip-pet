/* UI adapter only. Mirrors the existing DOM. No requests, scoring, preferences,
   detection state, timers, or replacements of the original event handlers. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const cloneContents = (source, destination) => {
    const src = $(source), dst = $(destination);
    dst.replaceChildren(...Array.from(src.childNodes, (node) => node.cloneNode(true)));
  };
  // All badges/values below are cloned from the original render tree.
  const displayRow = (label, value) => {
    const element=document.createElement('div');element.className='row';
    const key=document.createElement('span');key.className='k';key.textContent=label;
    const text=document.createElement('span');text.className='v';
    if(value instanceof Node)text.append(...Array.from(value.childNodes,node=>node.cloneNode(true)));
    else text.textContent=value;
    element.append(key,text);return element;
  };
  const icons={
    globe:'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20ZM2 12h20M12 2c-6 6-6 14 0 20 6-6 6-14 0-20ZM4 6h16M4 18h16',
    shield:'m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6l9-4Zm-4 10 3 3 5-6',
    clock:'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 4v7l5 3',
    grid:'M3 3h6v6H3ZM15 3h6v6h-6ZM3 15h6v6H3ZM15 15h6v6h-6Z',
    building:'M5 22V7h6V2h8v20M2 22h20M8 10v2m0 3v2m6-12v2m0 3v2m0 3v2m4-12v2m0 3v2m0 3v2',
    network:'M12 3a2 2 0 1 0 0 4 2 2 0 0 0 0-4ZM4 17a2 2 0 1 0 0 4 2 2 0 0 0 0-4ZM20 17a2 2 0 1 0 0 4 2 2 0 0 0 0-4ZM11 7 5 17m8-10 6 10M6 19h12',
    screen:'M3 3h18v13H3ZM8 21h8m-4-5v5',
    server:'M3 3h18v6H3ZM3 15h18v6H3ZM6 6h1m-1 12h1M4 12h16'
  };
  function decorateRows(id){
    $(id).querySelectorAll('.row .k').forEach(key=>{
      const label=key.textContent;
      const name=/时区/.test(label)?'clock':/ASN/.test(label)?'network':/运营商/.test(label)?'building':/属性/.test(label)?'grid':/系统|浏览器|Canvas/.test(label)?'screen':/服务|anthropic/.test(label)?'server':/风险|滥用|状态|泄露|记录/.test(label)?'shield':'globe';
      const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('aria-hidden','true');
      const path=document.createElementNS('http://www.w3.org/2000/svg','path');path.setAttribute('d',icons[name]);svg.append(path);key.prepend(svg);
    });
  }
  function mirror() {
    const trust=$('trustContent'),score=trust.querySelector('.trust-score');
    const number=score?score.firstChild.textContent.trim():'—';
    const numberNode=document.createElement('span');numberNode.className='hud-score-value';numberNode.textContent=number;
    const denominator=document.createElement('small');denominator.textContent='/100';
    $('hudScore').replaceChildren(numberNode,denominator);$('hudScore').style.color=score?score.style.color:'';
    const pointer=trust.querySelector('.pointer');
    // Read the already-rendered gauge; do not calculate another risk score.
    $('hudGauge').style.setProperty('--score',pointer?`calc(${pointer.style.left||'0%'} * .84)`:'0%');
    $('hudTrustSummary').replaceChildren();
    ['.trust-side','.gauge','.gauge-scale'].forEach(selector=>{
      const original=trust.querySelector(selector);if(original)$('hudTrustSummary').append(original.cloneNode(true));
    });
    const support=trust.querySelector('.row');
    if(support){const copy=support.cloneNode(true);copy.classList.add('hud-support');$('hudTrustSummary').querySelector('.trust-side')?.append(copy);}
    const properties=Array.from($('propsContent').querySelectorAll('.row'));
    const propertyOrder=['地区','ASN','运营商','IP 属性'];
    $('hudProperties').replaceChildren(...propertyOrder.map(label=>properties.find(row=>row.querySelector('.k')?.textContent===label)?.cloneNode(true)).filter(Boolean));
    const abuse=Array.from($('securityContent').querySelectorAll('.row')).find(row=>row.querySelector('.k')?.textContent==='滥用记录');
    if(abuse)$('hudProperties').append(abuse.cloneNode(true));
    cloneContents('ipCards','hudExits');
    $('hudExits').querySelectorAll('.ipcard').forEach((card,index)=>{
      const label=card.querySelector('.ipcard-label'),country=card.querySelector('.ipcard-geo')?.textContent.split(' · ')[0]||'';
      if(label)label.textContent=index===0?'中国':`${country} (${index===1?'Cloudflare':'Claude'})`;
    });
    const deviceRows=Array.from($('deviceContent').querySelectorAll('.row'));
    $('hudDevice').replaceChildren(...deviceRows.slice(0,2).map(row=>row.cloneNode(true)));
    const timezone=$('hudDevice').querySelector('.row .v');
    const offset=timezone?.textContent.match(/UTC[+-]\d{1,2}(?::\d{2})?/);
    if(timezone&&offset){const tag=timezone.querySelector('.tag')?.cloneNode(true);timezone.replaceChildren();if(tag){tag.textContent=tag.textContent.replace('时区','');timezone.append(tag);}timezone.append(' '+offset[0]);}
    const platform=deviceRows[2]?.querySelector('.v')?.textContent||'';
    if(platform){const parts=platform.split(' / ');$('hudDevice').append(displayRow('系统',parts[0]),displayRow('浏览器',parts.slice(1).join(' / ')));}
    const dnsRows=Array.from($('dnsContent').querySelectorAll('.row'));
    const provider=dnsRows.find(row=>row.querySelector('.k')?.textContent==='服务商');
    if(provider)$('hudDevice').append(displayRow('DNS 服务商',provider.querySelector('.v')));
    const fingerprint=deviceRows.find(row=>row.querySelector('.k')?.textContent==='Canvas 指纹');
    if(fingerprint)$('hudDevice').append(fingerprint.cloneNode(true));
    cloneContents('availContent','hudServices');
    dnsRows.slice(0,3).forEach((row,index)=>{
      const copy=row.cloneNode(true);if(index===0)copy.querySelector('.k').textContent='DNS 泄露';$('hudServices').append(copy);
    });
    ['hudProperties','hudDevice','hudServices'].forEach(decorateRows);
    const updated=$('updated').textContent,clock=updated.match(/\d{2}:\d{2}/);
    $('hudClock').textContent=clock?clock[0]:'—';
    const completed=updated.startsWith('更新 '),failed=updated.includes('出错');
    $('hudFooterTitle').textContent=completed?'检测完成':updated;
    $('hudStateIcon').textContent=completed?'✓':failed?'!':'⟳';
    $('hudStateIcon').className='state-light'+(failed?' error':completed?'':' running');
    $('hudStatus').textContent='';
    $('panel').dataset.ipMasked=String(!$('ipMaskToggle').checked);
    const lastCard=$('ipCards').lastElementChild;
    const location=lastCard?.querySelector('.ipcard-geo')?.textContent||'',flag=lastCard?.querySelector('.flag')?.textContent||'';
    $('hudCountry').textContent=[flag,location.split(' · ')[0]].filter(Boolean).join(' ')||'等待定位';
    $('hudLocation').textContent=location.includes('已隐藏')?'国家级示意 · IP 已隐藏':'出口 IP · 国家级示意';
    $('pet').setAttribute('aria-label',`贾维斯桌宠，当前评分 ${$('badgeText').textContent}，点击展开检测结果`);
    drawGlobe(flag);
  }
  function drawGlobe(flag) {
    const canvas = $('hudGlobe'), world = window.HUD_WORLD;
    if (!world) return;
    const box = canvas.getBoundingClientRect(), density = window.devicePixelRatio || 1;
    if (!box.width || !box.height) return;
    canvas.width = Math.round(box.width * density); canvas.height = Math.round(box.height * density);
    const ctx = canvas.getContext('2d'); ctx.scale(density, density);
    const w = box.width, h = box.height, cx = w * .53, cy = h * .54, radius = h * .54;
    const code = Array.from(flag).map((letter) => String.fromCharCode(letter.codePointAt(0) - 0x1f1e6 + 65)).join('');
    const country = world.countries[code], longitude = (country ? country[1] : -30) + 36;
    const tilt = 10 * Math.PI / 180;
    const project = (latitude, lon) => {
      const lat = latitude * Math.PI / 180, azimuth = (lon - longitude) * Math.PI / 180;
      const x = Math.cos(lat) * Math.sin(azimuth);
      const y = Math.sin(lat) * Math.cos(tilt) - Math.cos(lat) * Math.cos(azimuth) * Math.sin(tilt);
      const z = Math.sin(lat) * Math.sin(tilt) + Math.cos(lat) * Math.cos(azimuth) * Math.cos(tilt);
      return { x: cx + radius * x, y: cy - radius * y, z };
    };
    const orbitPoint = (angle) => {
      const x = radius * 1.35 * Math.cos(angle), y = radius * .31 * Math.sin(angle), rotation = -.24;
      return { x: cx + x * Math.cos(rotation) - y * Math.sin(rotation), y: cy + x * Math.sin(rotation) + y * Math.cos(rotation) - radius * .10 };
    };
    const orbit = (start, end) => {
      ctx.beginPath();
      for (let i = 0; i <= 140; i++) {
        const p = orbitPoint(start + (end - start) * i / 140);
        i ? ctx.lineTo(p.x,p.y) : ctx.moveTo(p.x,p.y);
      } ctx.stroke();
    };
    // Stable decorative star field. No animation loop or detection work.
    for(let index=0;index<68;index++){
      const u=Math.sin(index*12.9898+1.3)*43758.5453,v=Math.sin(index*78.233+4.1)*19341.732;
      const x=(u-Math.floor(u))*w,y=(v-Math.floor(v))*h;
      if(Math.hypot(x-cx,y-cy)<radius*.97)continue;
      const bright=index%9===0,r=bright?1.3:index%3===0?.7:.4;
      ctx.shadowColor='#16cfff';ctx.shadowBlur=bright?6:0;
      ctx.fillStyle=bright?'#c2faff':`rgba(48,194,242,${.30+(index%4)*.12})`;
      ctx.beginPath();ctx.arc(x,y,r,0,Math.PI*2);ctx.fill();
      if(bright){ctx.strokeStyle='#61d6f66b';ctx.lineWidth=.4;ctx.beginPath();ctx.moveTo(x-4,y);ctx.lineTo(x+4,y);ctx.moveTo(x,y-4);ctx.lineTo(x,y+4);ctx.stroke();}
    }ctx.shadowBlur=0;
    ctx.strokeStyle = '#21bde03b'; ctx.lineWidth = .7; orbit(0,Math.PI*2);
    ctx.strokeStyle='#d58e3b6b';ctx.lineWidth=1.3;
    ctx.beginPath();ctx.ellipse(cx,cy+radius*.30,radius*1.46,radius*.24,.24,0,Math.PI*2);ctx.stroke();
    ctx.strokeStyle='#21c9e772';ctx.lineWidth=.7;
    ctx.beginPath();ctx.ellipse(cx,cy,radius*1.11,radius*.38,-.74,0,Math.PI*2);ctx.stroke();
    ctx.shadowColor = '#009dff'; ctx.shadowBlur = 14;
    ctx.strokeStyle = '#0eaeefd0'; ctx.lineWidth = 1.2;
    ctx.beginPath();ctx.arc(cx,cy,radius,0,Math.PI*2);ctx.stroke();ctx.shadowBlur=0;
    const ocean = ctx.createRadialGradient(cx-radius*.4,cy-radius*.65,0,cx-radius*.4,cy-radius*.65,radius*1.7);
    ocean.addColorStop(0,'#062d50');ocean.addColorStop(.65,'#011a32');ocean.addColorStop(1,'#000c1e');
    ctx.fillStyle=ocean;ctx.fill();
    ctx.shadowColor='#00cfff';ctx.shadowBlur=11;ctx.strokeStyle='#2adfffdd';ctx.lineWidth=1.5;
    ctx.beginPath();ctx.arc(cx,cy,radius,217*Math.PI/180,311*Math.PI/180);ctx.stroke();ctx.shadowBlur=0;
    ctx.save();ctx.beginPath();ctx.arc(cx,cy,radius,0,Math.PI*2);ctx.clip();
    ctx.strokeStyle='#25b7e626';ctx.lineWidth=.5;
    for(let latitude=-60;latitude<=60;latitude+=20) {
      ctx.beginPath();let drawing=false;
      for(let lon=longitude-180;lon<=longitude+180;lon+=3) {
        const p=project(latitude,lon);
        if(p.z>0){drawing?ctx.lineTo(p.x,p.y):ctx.moveTo(p.x,p.y);drawing=true;}else drawing=false;
      }ctx.stroke();
    }
    for(let lon=longitude-80;lon<=longitude+80;lon+=20) {
      ctx.beginPath();let drawing=false;
      for(let latitude=-90;latitude<=90;latitude+=3){
        const p=project(latitude,lon);
        if(p.z>0){drawing?ctx.lineTo(p.x,p.y):ctx.moveTo(p.x,p.y);drawing=true;}else drawing=false;
      }ctx.stroke();
    }
    const cells=new Set();
    for(const coordinate of world.land){
      const p=project(coordinate[0],coordinate[1]);if(p.z<=0)continue;
      const cell=`${Math.round(p.x/2.1)},${Math.round(p.y/2.1)}`;if(cells.has(cell))continue;cells.add(cell);
      ctx.fillStyle=`rgba(${Math.round(32+p.z*50)},${Math.round(132+p.z*90)},255,${.28+p.z*.68})`;
      ctx.beginPath();ctx.arc(p.x,p.y,.38+p.z*.30,0,Math.PI*2);ctx.fill();
    }
    ctx.restore();
    ctx.shadowColor='#00c8ff';ctx.shadowBlur=6;ctx.strokeStyle='#22c9f2c9';ctx.lineWidth=.85;
    orbit(Math.PI*.96,Math.PI*1.94);
    [.16,.39,.74].forEach((fraction)=>{
      const p=orbitPoint(Math.PI*fraction+Math.PI);ctx.fillStyle='#9cf4ff';ctx.beginPath();ctx.arc(p.x,p.y,1.6,0,Math.PI*2);ctx.fill();
    });ctx.shadowBlur=0;
    if(country){
      const p=project(country[0],country[1]);
      const halo=ctx.createRadialGradient(p.x,p.y,0,p.x,p.y,29);
      halo.addColorStop(0,'#00ffd688');halo.addColorStop(1,'#00ffd600');
      ctx.fillStyle=halo;ctx.fillRect(p.x-29,p.y-29,58,58);
      ctx.strokeStyle='#40ecffd0';ctx.lineWidth=.8;ctx.beginPath();ctx.arc(p.x,p.y,15,0,Math.PI*2);ctx.stroke();
      ctx.shadowColor='#00eaff';ctx.shadowBlur=10;ctx.fillStyle='#74fff1';
      ctx.beginPath();ctx.moveTo(p.x,p.y+9);ctx.bezierCurveTo(p.x-16,p.y-7,p.x-6,p.y-15,p.x,p.y-15);
      ctx.bezierCurveTo(p.x+6,p.y-15,p.x+16,p.y-7,p.x,p.y+9);ctx.fill();ctx.shadowBlur=0;
      ctx.fillStyle='#0c839b';ctx.beginPath();ctx.arc(p.x,p.y-6,3.5,0,Math.PI*2);ctx.fill();
    }
  }
  const observer = new MutationObserver(mirror);
  ['trustContent','propsContent','securityContent','ipCards','deviceContent','availContent','dnsContent','updated','badgeText'].forEach((id) => {
    observer.observe($(id), { childList:true, subtree:true, characterData:true });
  });
  new ResizeObserver(mirror).observe($('hudGlobe'));
  mirror();
})();
