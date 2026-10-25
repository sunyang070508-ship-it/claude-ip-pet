// Development-only DOM measurements via the app's pre-existing --eval option.
// Does not ship in either app and never reads or logs IP addresses.
(() => {
  const rect = (element) => {
    const r = element.getBoundingClientRect();
    return { x:r.x,y:r.y,width:r.width,height:r.height,bottom:r.bottom,right:r.right };
  };
  const spinner = document.querySelector('.refresh-icon');
  const animation = spinner.getAnimations()[0];
  const oldTime = animation?.currentTime;
  const samples = [];
  if (animation) {
    animation.pause();
    for (const time of [0,125,250,500,750]) {
      animation.currentTime = time;
      const r = rect(spinner);
      samples.push({time,centerX:r.x+r.width/2,centerY:r.y+r.height/2});
    }
    animation.currentTime = oldTime; animation.play();
  }
  const artwork=spinner.querySelector('svg').getBBox();
  console.warn('UI_SPINNER_AUDIT '+JSON.stringify({
    samples,
    centerDrift:samples.length?Math.max(...samples.map(s=>Math.hypot(s.centerX-samples[0].centerX,s.centerY-samples[0].centerY))):null,
    artworkCenter:{x:artwork.x+artwork.width/2,y:artwork.y+artwork.height/2},
    viewBoxCenter:{x:12,y:12},
    originalBusyClass:document.getElementById('btnRefresh').classList.contains('spin'),
    toast:rect(document.getElementById('toast')),
    panelBottom:rect(document.getElementById('panel')).bottom,
    footerInsideHUD:!!document.querySelector('.hud-overview > .p-foot')
  }));
  const measure = () => {
    const updated = document.getElementById('updated').textContent;
    if (!updated.startsWith('更新 ') && !updated.includes('出错')) return;
    observer.disconnect();
    const panel=rect(document.getElementById('panel'));
    const dial=rect(document.querySelector('.hud-gauge-rings'));
    const trustFrameBottom=panel.y+443*650/1122;
    const regions={};
    for(const [selector,sourceBottom] of [['.hud-properties',691],['.hud-exits',691],['.hud-device',992],['.hud-services',992]]){
      const element=document.querySelector(selector),children=element.lastElementChild.children;
      const bottom=children.length?rect(children[children.length-1]).bottom:rect(element).y;
      regions[selector]={contentBottom:bottom,frameBottom:panel.y+sourceBottom*650/1122,clearance:panel.y+sourceBottom*650/1122-bottom};
    }
    console.warn('UI_LAYOUT_AUDIT '+JSON.stringify({
      panel,dial,dialBottomClearance:trustFrameBottom-dial.bottom,
      regions,
      headings:Array.from(document.querySelectorAll('.hud-region>h2')).map(h=>({title:h.textContent,rect:rect(h),color:getComputedStyle(h).color,visibility:getComputedStyle(h).visibility})),
      ipRows:Array.from(document.querySelectorAll('#hudExits .ipcard')).map(card=>({height:rect(card).height})),
      existingButtons:['btnRefresh','btnSite','btnCollapse','ipMaskToggle'].map(id=>({id,count:document.querySelectorAll('#'+id).length}))
    }));
  };
  const observer=new MutationObserver(measure);
  observer.observe(document.getElementById('updated'),{childList:true,characterData:true,subtree:true});
  measure();
})();
