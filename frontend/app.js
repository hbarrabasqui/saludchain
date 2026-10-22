/* SaludChain – frontend sin build. Habla directo con los contratos mediante ethers.js + MetaMask. */
(() => {
  "use strict";
  const { BrowserProvider, JsonRpcProvider, Contract, Interface, parseEther, formatEther, getAddress, keccak256, ZeroAddress } = ethers;
  const cfg = window.SALUDCHAIN_CONFIG;
  const ESTADOS = ["Pendiente", "Activa", "Cumplida", "Liberada", "Vencida"];
  const $ = (s) => document.querySelector(s);
  const esc = (t) => String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const eth = (wei) => { const n = Number(formatEther(wei)); return n.toLocaleString("es-AR", { maximumFractionDigits: 6 }); };
  const corta = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
  const fecha = (ts) => new Date(Number(ts) * 1000).toLocaleString("es-AR", { dateStyle: "medium", timeStyle: "short" });

  const ifaz = new Interface(window.SALUDCHAIN_ABI);
  const lector = new JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
  const scLectura = new Contract(cfg.saludChain, window.SALUDCHAIN_ABI, lector);
  const reciboLectura = new Contract(cfg.recibo, window.RECIBO_ABI, lector);

  let signer = null, cuenta = null, scEscritura = null, esVerificador = false, esAdmin = false;
  const configurado = cfg.saludChain !== ZeroAddress;

  /* ---------- billetera (EIP-6963: usa MetaMask aunque haya otras billeteras instaladas) ---------- */
  const descubiertas = [];
  window.addEventListener("eip6963:announceProvider", (ev) => descubiertas.push(ev.detail));
  window.dispatchEvent(new Event("eip6963:requestProvider"));
  const billetera = () => (descubiertas.find((d) => d.info.rdns === "io.metamask") || descubiertas[0])?.provider || window.ethereum || null;

  /* ---------- avisos ---------- */
  function toast(html, tipo = "") {
    const d = document.createElement("div");
    d.className = `toast ${tipo}`;
    d.innerHTML = html;
    const caja = $("#toasts");
    caja.appendChild(d);
    while (caja.children.length > 3) caja.firstChild.remove(); // no acumular avisos
    setTimeout(() => d.remove(), tipo === "error" ? 9000 : 6000);
    return d;
  }
  const enlaceTx = (h) => `<a href="${esc(cfg.explorer)}/tx/${esc(h)}" target="_blank" rel="noopener">ver transacción</a>`;

  function mensajeError(e) {
    if (e?.code === "ACTION_REJECTED" || e?.code === 4001 || e?.info?.error?.code === 4001) return "Rechazaste la operación en la billetera.";
    let r = e?.revert;
    if (!r) {
      const data = e?.data || e?.info?.error?.data?.data || e?.error?.data;
      if (typeof data === "string" && data.startsWith("0x")) { try { r = ifaz.parseError(data); } catch { /* sin decodificar */ } }
    }
    if (r) {
      const a = r.args || [];
      switch (r.name) {
        case "EstadoInvalido": return `La campaña está en estado «${ESTADOS[Number(a[1])]}» y no admite esta operación.`;
        case "ExcedeMeta": return `La donación supera lo que falta para la meta (faltan ${eth(a[0])} ETH).`;
        case "MontoCero": return "El monto debe ser mayor que cero.";
        case "PlazoVencido": return "La campaña ya superó su plazo.";
        case "NoEsDestinatario": return "Solo el destinatario de la campaña puede retirar los fondos.";
        case "DevolucionNoDisponible": return "Todavía no hay devolución: el plazo no venció, o el destinatario todavía está a tiempo de retirar.";
        case "VentanaDeRetiroVencida": return "Pasaron los 30 días para retirar: ahora los donantes pueden recuperar su aporte.";
        case "SinAportes": return "No tenés aportes para recuperar en esta campaña.";
        case "MontoAprobadoInvalido": return `El monto aprobado debe ser mayor que cero y no superar la meta solicitada (${eth(a[1])} ETH).`;
        case "AccessControlUnauthorizedAccount": return "Tu cuenta no tiene permiso de verificador.";
        case "DuracionInvalida": return "La duración debe estar entre 1 y 180 días.";
        case "HashDocsInvalido": return "Falta la huella de la documentación.";
        case "DireccionInvalida": return "Dirección inválida.";
        case "MetaInvalida": return "La meta debe ser mayor que cero.";
        case "CampaniaInexistente": return "La campaña no existe.";
        case "TransferenciaFallida": return "Falló la transferencia de ETH.";
        default: return `El contrato rechazó la operación (${r.name}).`;
      }
    }
    return e?.shortMessage || e?.reason || e?.message || "Error desconocido";
  }

  /* ---------- conexión ---------- */
  async function asegurarRed() {
    const hex = "0x" + cfg.chainId.toString(16);
    const w = billetera();
    const actual = await w.request({ method: "eth_chainId" });
    if (actual.toLowerCase() === hex) return;
    try {
      await w.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
    } catch (e) {
      if (e?.code === 4902 && cfg.chainParams) {
        await w.request({ method: "wallet_addEthereumChain", params: [cfg.chainParams] });
      } else { throw e; }
    }
  }

  async function conectar(silencioso = false) {
    const w = billetera();
    if (!w) { if (!silencioso) toast("No se encontró MetaMask. Instalalo para poder operar.", "error"); return; }
    try {
      const prov = new BrowserProvider(w);
      if (silencioso) {
        const cuentas = await w.request({ method: "eth_accounts" });
        if (!cuentas.length) return;
      } else {
        await prov.send("eth_requestAccounts", []);
      }
      await asegurarRed();
      signer = await prov.getSigner();
      cuenta = await signer.getAddress();
      scEscritura = new Contract(cfg.saludChain, window.SALUDCHAIN_ABI, signer);
      const [rolV, rolA] = await Promise.all([scLectura.VERIFICADOR_ROLE(), scLectura.DEFAULT_ADMIN_ROLE()]);
      [esVerificador, esAdmin] = await Promise.all([scLectura.hasRole(rolV, cuenta), scLectura.hasRole(rolA, cuenta)]);
      pintarCabecera();
      if (!$("#c-destinatario").value) $("#c-destinatario").value = cuenta;
      await Promise.all([cargarCampanias(), cargarRecibos()]);
    } catch (e) {
      toast(esc(mensajeError(e)), "error");
    }
  }

  function pintarCabecera() {
    const red = $("#red");
    red.textContent = cuenta ? `${cfg.chainName} · ${corta(cuenta)}` : cfg.chainName;
    red.className = "badge " + (cuenta ? "ok" : "neutral");
    const roles = [esVerificador && "Verificador", esAdmin && "Admin"].filter(Boolean).join(" + ");
    $("#roles").hidden = !roles;
    $("#roles").textContent = roles;
    $("#btn-conectar").textContent = cuenta ? "Conectado" : "Conectar MetaMask";
    $("#btn-conectar").disabled = !!cuenta;
  }

  /* ---------- transacciones ---------- */
  async function enviar(descripcion, fn) {
    if (!scEscritura) { toast("Conectá tu billetera primero.", "error"); return; }
    try {
      toast(`${esc(descripcion)}: confirmá en tu billetera…`);
      const tx = await fn();
      toast(`Transacción enviada. ${enlaceTx(tx.hash)}`);
      await tx.wait();
      toast(`${esc(descripcion)}: confirmada. ${enlaceTx(tx.hash)}`, "ok");
      await Promise.all([cargarCampanias(), cargarRecibos()]);
    } catch (e) {
      toast(esc(mensajeError(e)), "error");
    }
  }

  /* ---------- recibos (leídos del estado del contrato, sin logs) ---------- */
  // Cada donación emite un recibo NFT numerado 1, 2, 3… Se leen directo del contrato (ownerOf + datosDe):
  // así sirve para el gráfico de aportes y para «Mis recibos», y funciona en cualquier nodo (los públicos
  // borran los logs viejos, por eso no se usan eventos). Se guarda lo ya leído y después solo se pide lo nuevo.
  const recibos = new Map(); // id -> { id, owner, campania, monto }
  let proximoRecibo = 1;
  const noExiste = (e) => e?.code === "CALL_EXCEPTION"; // el id todavía no fue emitido

  async function leerRecibo(id) {
    try {
      const [owner, d] = await Promise.all([reciboLectura.ownerOf(id), reciboLectura.datosDe(id)]);
      return { id, owner: getAddress(owner), campania: d.campaniaId, monto: d.monto };
    } catch (e) { if (noExiste(e)) return null; throw e; }
  }

  async function actualizarRecibos() {
    // Los recibos son transferibles: se vuelve a leer quién es el dueño actual de los ya conocidos.
    await Promise.all([...recibos.keys()].map(async (id) => {
      const r = await leerRecibo(id);
      if (r) recibos.set(id, r);
    }));
    for (;;) {
      const lote = await Promise.all(Array.from({ length: 10 }, (_, i) => leerRecibo(proximoRecibo + i)));
      for (const r of lote) {
        if (!r) return;
        recibos.set(r.id, r);
        proximoRecibo = r.id + 1;
      }
    }
  }
  let leyendoRecibos = null; // si dos secciones piden a la vez, comparten la misma lectura
  const asegurarRecibos = () => (leyendoRecibos ??= actualizarRecibos().finally(() => { leyendoRecibos = null; }));

  /* ---------- donantes por campaña ---------- */
  // Se toman los dueños de los recibos de la campaña y el monto de cada billetera se lee del contrato con
  // aporteDe(): así una devolución se refleja sola. (Si un recibo se transfirió, ese aporte no se atribuye
  // a nadie y el gráfico lo muestra aparte, como «sin identificar».)
  function donantesDe(id) {
    const s = new Set();
    for (const r of recibos.values()) if (r.campania === BigInt(id)) s.add(r.owner);
    return [...s];
  }

  async function aportesDe(id) {
    const direcciones = donantesDe(id);
    const montos = await Promise.all(direcciones.map((a) => scLectura.aporteDe(id, a)));
    return direcciones.map((a, i) => ({ a, m: montos[i] }))
      .filter((x) => x.m > 0n)
      .sort((x, y) => (y.m > x.m ? 1 : y.m < x.m ? -1 : 0));
  }

  // Paleta propia del reparto: sin verdes ni el azul/rojo de los estados, para no confundirla con la barra de progreso.
  const COLORES = ["#7c3aed", "#ea580c", "#db2777", "#0891b2", "#a16207", "#4b5563"];
  function graficoDonantes(aportes, destinatario, recaudado) {
    if (!aportes.length) return "";
    const identificado = aportes.reduce((s, x) => s + x.m, 0n);
    const total = recaudado > identificado ? recaudado : identificado; // porcentajes sobre lo recaudado
    const dest = destinatario.toLowerCase(), yo = cuenta ? cuenta.toLowerCase() : "";
    const pctDe = (m) => Number((m * 10000n) / total) / 100;
    const filas = aportes.map((x, i) => ({ ...x, pct: pctDe(x.m), color: COLORES[i % COLORES.length] }));
    const resto = total - identificado; // aportes cuyo recibo cambió de dueño
    let segmentos = filas.map((f) =>
      `<span style="width:${f.pct}%;background:${f.color}" title="${esc(f.a)}: ${eth(f.m)} ETH (${f.pct.toFixed(1)}%)"></span>`).join("");
    let lista = filas.map((f) => {
      const tags = (f.a.toLowerCase() === dest ? '<span class="tag">destinatario</span>' : "") +
        (f.a.toLowerCase() === yo ? '<span class="tag yo">vos</span>' : "");
      return `<li><i class="punto" style="background:${f.color}"></i><span class="mono" title="${esc(f.a)}">${esc(corta(f.a))}</span>${tags}
        <span class="pct">${eth(f.m)} ETH · ${f.pct.toFixed(1)}%</span></li>`;
    }).join("");
    if (resto > 0n) {
      segmentos += `<span style="width:${pctDe(resto)}%;background:#cbd5e1" title="Sin identificar"></span>`;
      lista += `<li><i class="punto" style="background:#cbd5e1"></i><span>Sin identificar (recibo transferido)</span>
        <span class="pct">${eth(resto)} ETH · ${pctDe(resto).toFixed(1)}%</span></li>`;
    }
    const propio = filas.find((f) => f.a.toLowerCase() === dest);
    const aviso = propio ? `<p class="nota-d">El destinatario aportó el ${propio.pct.toFixed(1)}% del total.</p>` : "";
    const n = filas.length;
    return `<div class="donantes">
      <h4>${n} ${n === 1 ? "billetera aportó" : "billeteras distintas aportaron"}</h4>
      <div class="reparto" role="img" aria-label="Reparto de aportes por billetera">${segmentos}</div>
      <ul>${lista}</ul>${aviso}
    </div>`;
  }

  /* ---------- campañas ---------- */
  async function cargarCampanias() {
    const cont = $("#lista");
    if (!configurado) { cont.innerHTML = '<p class="vacio">Faltan configurar las direcciones de los contratos (config.js).</p>'; return; }
    try {
      const total = Number(await scLectura.totalCampanias());
      if (!total) { cont.innerHTML = '<p class="vacio">Todavía no hay campañas. Creá la primera desde la pestaña «Crear campaña».</p>'; return; }
      const ids = Array.from({ length: total }, (_, i) => total - i);
      // Si falla la lectura de eventos, igual se muestran las campañas (sin el reparto de aportes).
      try { await asegurarRecibos(); } catch { /* se reintenta en la próxima carga */ }
      const datos = await Promise.all(ids.map(async (id) => {
        const [c, estado, aporte, aportes] = await Promise.all([
          scLectura.campania(id), scLectura.estadoActual(id), cuenta ? scLectura.aporteDe(id, cuenta) : 0n, aportesDe(id),
        ]);
        return { id, c, estado: Number(estado), aporte, aportes };
      }));
      cont.innerHTML = datos.map(tarjeta).join("");
    } catch (e) {
      cont.innerHTML = `<p class="vacio">No se pudieron leer las campañas: ${esc(mensajeError(e))}</p>`;
    }
  }

  function tarjeta({ id, c, estado, aporte, aportes }) {
    const nombre = ESTADOS[estado];
    const meta = c.meta, rec = c.recaudado;
    const pct = meta > 0n ? Number((rec * 10000n) / meta) / 100 : 0;
    const guardado = Number(c.estado); // estado guardado en el contrato (Vencida es solo derivado)
    const hasta = c.plazo > 0n ? esc(fecha(c.plazo)) : "";
    let plazoTxt;
    if (guardado === 3) plazoTxt = ""; // ya retirada: el plazo dejó de ser relevante
    else if (guardado === 2) plazoTxt = `Ventana de retiro hasta: <b>${hasta}</b>`; // Cumplida: ahora `plazo` es el límite para retirar
    else if (c.plazo > 0n) plazoTxt = `Plazo: <b>${hasta}</b>`;
    else plazoTxt = `Duración: <b>${Number(c.duracion) / 86400} días</b> desde la verificación`;
    const esDest = cuenta && cuenta.toLowerCase() === c.destinatario.toLowerCase();
    let acciones = "";
    if (estado === 0) {
      acciones = esVerificador
        ? `<input id="ver-${id}" type="number" step="any" min="0" value="${esc(formatEther(meta))}" aria-label="Monto aprobado en ETH">
           <button class="btn primary" data-accion="verificar" data-id="${id}">Aprobar campaña</button>
           <span class="nota">Monto aprobado (ETH, máximo lo solicitado)</span>`
        : `<span class="nota">Esperando que un verificador la apruebe.</span>`;
    } else if (estado === 1) {
      const falta = meta - rec;
      acciones = cuenta
        ? `<input id="don-${id}" type="number" step="any" min="0" placeholder="ETH" aria-label="Monto a donar en ETH">
           <button class="btn primary" data-accion="donar" data-id="${id}">Donar</button>
           <span class="nota">Faltan ${eth(falta)} ETH para la meta</span>`
        : `<span class="nota">Conectá tu billetera para donar.</span>`;
    } else if (estado === 2) {
      acciones = esDest
        ? `<button class="btn primary" data-accion="retirar" data-id="${id}">Retirar fondos</button>
           <span class="nota">¡Meta alcanzada! Sos el destinatario: retirá antes del ${hasta}.</span>`
        : `<span class="nota">Meta alcanzada. El destinatario puede retirar hasta el ${hasta}; si no lo hace, los donantes recuperan su aporte.</span>`;
    } else if (estado === 3) {
      acciones = `<span class="nota">Cerrada con éxito: los fondos fueron entregados al destinatario.</span>`;
    } else {
      const sinRetirar = guardado === 2; // alcanzó la meta pero el destinatario no retiró dentro de la ventana
      const motivo = sinRetirar
        ? "La meta se alcanzó pero el destinatario no retiró dentro de los 30 días: cada donante puede recuperar su aporte."
        : "Venció sin alcanzar la meta: cada donante puede recuperar su aporte.";
      acciones = aporte > 0n
        ? `<button class="btn primary" data-accion="devolucion" data-id="${id}">Recuperar mi aporte (${eth(aporte)} ETH)</button>
           <span class="nota">${motivo}</span>`
        : `<span class="nota">${motivo}</span>`;
    }
    return `<article class="card estado-${nombre.toLowerCase()}" data-id="${id}">
      <div class="card-head"><h3>Campaña #${id}</h3><span class="badge ${nombre.toLowerCase()}">${nombre}</span></div>
      <div class="barra" role="progressbar" aria-valuenow="${Math.min(pct, 100)}" aria-valuemin="0" aria-valuemax="100"><span style="width:${Math.min(pct, 100)}%"></span></div>
      <div class="cifras"><span><b>${eth(rec)}</b> ETH recaudados</span><span>Meta: <b>${eth(meta)}</b> ETH (${pct.toFixed(1)}%)</span></div>
      <div class="meta">
        <span>Destinatario: <b class="mono">${esc(c.destinatario)}</b></span>
        ${plazoTxt ? `<span>${plazoTxt}</span>` : ""}
        <span>Huella de documentación: <b class="mono">${esc(c.hashDocs)}</b></span>
        ${aporte > 0n ? `<span>Mi aporte: <b>${eth(aporte)} ETH</b></span>` : ""}
      </div>
      ${graficoDonantes(aportes, c.destinatario, rec)}
      <div class="acciones">${acciones}</div>
    </article>`;
  }

  $("#lista").addEventListener("click", (ev) => {
    const b = ev.target.closest("button[data-accion]");
    if (!b) return;
    const id = BigInt(b.dataset.id);
    const num = (sel) => { const v = $(sel).value.trim(); if (!v || Number(v) <= 0) throw new Error("Ingresá un monto mayor que cero."); return parseEther(v); };
    try {
      switch (b.dataset.accion) {
        case "donar": { const v = num(`#don-${id}`); enviar(`Donar ${eth(v)} ETH`, () => scEscritura.donar(id, { value: v })); break; }
        case "verificar": { const v = num(`#ver-${id}`); enviar("Aprobar campaña", () => scEscritura.verificar(id, v)); break; }
        case "retirar": enviar("Retirar fondos", () => scEscritura.retirar(id)); break;
        case "devolucion": enviar("Recuperar aporte", () => scEscritura.reclamarDevolucion(id)); break;
      }
    } catch (e) { toast(esc(e.message), "error"); }
  });

  /* ---------- crear campaña ---------- */
  $("#form-crear").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    try {
      const destinatario = getAddress($("#c-destinatario").value.trim());
      const meta = parseEther($("#c-meta").value.trim());
      const dias = BigInt(Math.trunc(Number($("#c-dias").value)));
      const archivo = $("#c-archivo").files[0];
      let hash = $("#c-hash").value.trim();
      if (archivo) hash = keccak256(new Uint8Array(await archivo.arrayBuffer()));
      if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Error("Elegí un archivo o pegá una huella de 32 bytes (0x + 64 caracteres).");
      await enviar("Crear campaña", () => scEscritura.crearCampania(destinatario, meta, dias * 86400n, hash));
      $("#form-crear").reset();
      if (cuenta) $("#c-destinatario").value = cuenta;
      cambiarTab("campanias");
    } catch (e) { toast(esc(e.shortMessage || e.message), "error"); }
  });

  /* ---------- recibos (NFT) ---------- */
  async function cargarRecibos() {
    const cont = $("#recibos");
    if (!configurado) return;
    if (!cuenta) { cont.innerHTML = '<p class="vacio">Conectá tu billetera para ver tus recibos.</p>'; return; }
    try {
      await asegurarRecibos();
      const mios = [...recibos.values()].filter((r) => r.owner === cuenta).sort((a, b) => b.id - a.id); // el más nuevo primero
      if (!mios.length) { cont.innerHTML = '<p class="vacio">Todavía no tenés recibos. Cada donación emite uno.</p>'; return; }
      cont.innerHTML = mios.map((r) => `<article class="card recibo"><div class="nft">NFT</div>
        <div><h3>Recibo SaludChain #${r.id}</h3><div class="meta"><span>Campaña: <b>#${r.campania}</b></span><span>Monto donado: <b>${eth(r.monto)} ETH</b></span></div></div></article>`).join("");
    } catch (e) {
      cont.innerHTML = `<p class="vacio">No se pudieron leer los recibos: ${esc(mensajeError(e))}</p>`;
    }
  }

  /* ---------- pestañas y arranque ---------- */
  function cambiarTab(nombre) {
    document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("activa", t.dataset.tab === nombre));
    ["campanias", "crear", "recibos"].forEach((n) => { $(`#tab-${n}`).hidden = n !== nombre; });
  }
  document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => cambiarTab(t.dataset.tab)));
  $("#btn-conectar").addEventListener("click", () => conectar(false));
  $("#btn-recargar").addEventListener("click", cargarCampanias);
  $("#btn-recargar-recibos").addEventListener("click", cargarRecibos);

  const w0 = billetera();
  if (w0) {
    w0.on?.("accountsChanged", () => { cuenta = null; scEscritura = null; esVerificador = esAdmin = false; pintarCabecera(); conectar(true); cargarCampanias(); });
    w0.on?.("chainChanged", () => location.reload());
  }

  $("#direcciones").innerHTML = configurado
    ? `SaludChain: <a href="${esc(cfg.explorer)}/address/${esc(cfg.saludChain)}" target="_blank" rel="noopener">${esc(cfg.saludChain)}</a> · Recibo: <a href="${esc(cfg.explorer)}/address/${esc(cfg.recibo)}" target="_blank" rel="noopener">${esc(cfg.recibo)}</a>`
    : "Contratos sin configurar (completar config.js luego del despliegue).";
  pintarCabecera();
  cargarCampanias();
  conectar(true);
})();
