async function w(){const e=await fetch("/api/videos",{credentials:"include"});if(e.status===401)return window.location.href="/library/login",[];if(!e.ok)throw new Error(`Failed to load videos (${e.status})`);return(await e.json()).videos||[]}async function b(e){const t=await fetch(`/api/renew/${e}`,{method:"POST",credentials:"include"});return t.ok&&(await t.json()).expiresAt||null}async function x(e){return(await fetch(`/api/delete/${e}`,{method:"DELETE",credentials:"include"})).ok}function $(e){const t=Math.floor(e/3600),n=Math.floor(e%3600/60),a=Math.floor(e%60);return t>0?`${t}:${String(n).padStart(2,"0")}:${String(a).padStart(2,"0")}`:`${n}:${String(a).padStart(2,"0")}`}function y(e){const t=/[Zz]$|[+-]\d{2}:?\d{2}$/.test(e);return new Date(t?e:e.replace(" ","T")+"Z")}function E(e){const t=y(e);return Number.isNaN(t.getTime())?"—":t.toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"})}function f(e){const t=y(e).getTime();return Number.isNaN(t)?NaN:Math.max(0,Math.round((t-Date.now())/(1440*60*1e3)))}function r(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;")}const u=document.getElementById("lib-loading"),p=document.getElementById("lib-error"),h=document.getElementById("lib-empty"),s=document.getElementById("lib-grid"),c=document.getElementById("toast");function o(e){c.textContent=e,c.classList.add("show"),setTimeout(()=>c.classList.remove("show"),2200)}function m(e){return Number.isNaN(e)?"Expiry unknown":e===0?"Expires today":e===1?"Expires tomorrow":`Expires in ${e} days`}function g(e){return!Number.isNaN(e)&&e<=3?"expiry-soon":"expiry-ok"}function k(e){const t=f(e.expires_at),n=m(t),a=g(t);return`
      <div class="lib-card" data-code="${r(e.share_code)}">
        <div class="card-thumb">
          <img
            src="/thumb/${r(e.share_code)}"
            alt="${r(e.title)}"
            loading="lazy"
            onerror="this.style.display='none'"
          />
          ${e.is_protected?'<span class="lock-badge">&#x1F512;</span>':""}
        </div>
        <div class="card-body">
          <p class="card-title" title="${r(e.title)}">${r(e.title)}</p>
          <div class="card-meta">
            <span>${$(e.duration)}</span>
            <span>${E(e.created_at)}</span>
            <span>${e.view_count===1?"1 view":`${e.view_count} views`}</span>
          </div>
          <p class="card-expiry ${a}">${n}</p>
        </div>
        <div class="card-actions">
          <a href="/s/${r(e.share_code)}" target="_blank" rel="noopener" class="btn btn-ghost">Open</a>
          <button class="btn btn-ghost btn-copy" data-code="${r(e.share_code)}">Copy link</button>
          <button class="btn btn-ghost btn-renew" data-code="${r(e.share_code)}">Renew</button>
          <button class="btn btn-danger btn-delete" data-code="${r(e.share_code)}">Delete</button>
        </div>
      </div>
    `}function N(e){e.querySelectorAll(".btn-copy").forEach(t=>{t.addEventListener("click",()=>{const n=t.dataset.code,a=`${location.origin}/s/${n}`;navigator.clipboard.writeText(a).then(()=>o("Link copied")).catch(()=>o("Copy failed"))})}),e.querySelectorAll(".btn-renew").forEach(t=>{t.addEventListener("click",async()=>{const n=t.dataset.code;t.disabled=!0,t.textContent="Renewing…";const a=await b(n);if(a){const l=t.closest(".lib-card"),d=f(a),i=l.querySelector(".card-expiry");i&&(i.textContent=m(d),i.className=`card-expiry ${g(d)}`),o("Renewed 30 days")}else o("Renew failed");t.disabled=!1,t.textContent="Renew"})}),e.querySelectorAll(".btn-delete").forEach(t=>{t.addEventListener("click",async()=>{const n=t.dataset.code;if(!confirm("Delete this recording permanently?"))return;t.disabled=!0,t.textContent="Deleting…",await x(n)?(t.closest(".lib-card")?.remove(),o("Deleted"),s.children.length===0&&(s.style.display="none",h.style.display="")):(o("Delete failed"),t.disabled=!1,t.textContent="Delete")})})}async function C(){try{const e=await w();if(u.style.display="none",e.length===0){h.style.display="";return}s.innerHTML=e.map(k).join(""),s.style.display="",N(s)}catch{u.style.display="none",p.textContent="Failed to load recordings.",p.style.display=""}}C();
