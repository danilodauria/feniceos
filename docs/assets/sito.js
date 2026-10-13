/* FeniceOS — sito di download: dati della ISO e pulsante «Copia». © 2026 Danilo D'Auria — codice MIT.
   I dati della versione stanno in dati/iso.json (si aggiornano con strumenti/aggiorna-iso.py o modificando il file su GitHub).
   La pagina contiene già gli stessi valori: se il file non si legge (per esempio aprendo la pagina dal disco), resta tutto corretto. */
(function () {
  "use strict";
  var MESI = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"];
  function gb(byte) { return (byte / 1e9).toFixed(2).replace(".", ",") + " GB"; }
  function dataLunga(iso) { var p = String(iso || "").split("-"); return p.length === 3 ? (+p[2]) + " " + MESI[+p[1] - 1] + " " + p[0] : iso; }
  function applica(d) {
    var v = { versione: d.versione, nome: d.nome, base: d.base, architettura: d.architettura, sha256: d.sha256,
              dimensione: d.byte ? gb(d.byte) : null, data_lunga: dataLunga(d.data) };
    Array.prototype.forEach.call(document.querySelectorAll("[data-iso]"), function (el) {
      var k = el.getAttribute("data-iso"); if (v[k]) el.textContent = v[k];
    });
    Array.prototype.forEach.call(document.querySelectorAll("[data-iso-href]"), function (el) {
      var k = el.getAttribute("data-iso-href"); if (d[k] && /^https:\/\//.test(d[k])) el.href = d[k];
    });
  }
  try {
    if (window.fetch && location.protocol !== "file:") {
      fetch("dati/iso.json", { cache: "no-cache" }).then(function (r) { return r.ok ? r.json() : null; }).then(function (d) { if (d) applica(d); }).catch(function () {});
    }
  } catch (e) { /* restano i valori scritti nella pagina */ }

  var avviso = document.getElementById("avviso"), timer;
  function mostra(t) { avviso.textContent = t; avviso.classList.add("si"); clearTimeout(timer); timer = setTimeout(function () { avviso.classList.remove("si"); }, 2400); }
  Array.prototype.forEach.call(document.querySelectorAll("[data-copia]"), function (b) {
    b.addEventListener("click", function () {
      var testo = document.querySelector(b.getAttribute("data-copia")).textContent.trim();
      function vecchio() {
        var t = document.createElement("textarea"); t.value = testo; t.setAttribute("readonly", ""); t.style.position = "fixed"; t.style.opacity = "0";
        document.body.appendChild(t); t.select();
        try { document.execCommand("copy"); mostra("Impronta copiata"); } catch (e) { mostra("Selezionala e copiala con Ctrl + C"); }
        document.body.removeChild(t);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(testo).then(function () { mostra("Impronta copiata"); }, vecchio);
      else vecchio();
    });
  });
})();
