#!/usr/bin/env python3
"""Prove automatiche del sito di FeniceOS (Playwright + Chromium).
Uso: python3 tests/test_sito.py        Autore: Danilo D'Auria — licenza MIT"""
import functools, http.server, json, os, re, threading, sys
from playwright.sync_api import sync_playwright

QUI = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(os.path.dirname(QUI), "docs")
errori = []
def check(nome, ok, dett=""):
    print(("  ✔ " if ok else "  ✘ ") + nome + ("" if ok else "  →  %s" % (dett,)))
    if not ok: errori.append(nome)

dati = json.load(open(os.path.join(DOCS, "dati", "iso.json"), encoding="utf-8"))
check("iso.json: impronta di 64 caratteri esadecimali", re.fullmatch(r"[0-9a-f]{64}", dati["sha256"]) is not None)
check("iso.json: download in https", dati["scarica"].startswith("https://"))
sha = open(os.path.join(DOCS, "download", dati["nome"] + ".sha256"), encoding="utf-8").read().split()
check("file .sha256 nel formato di sha256sum e uguale a iso.json", sha == [dati["sha256"], dati["nome"]], sha)
pagina = open(os.path.join(DOCS, "index.html"), encoding="utf-8").read()
check("la pagina contiene già i valori giusti (anche aperta dal disco)", dati["sha256"] in pagina and ('>%s<' % dati["versione"]) in pagina)
for ref in re.findall(r'\s(?:href|src)="([^"#:]+)"', pagina):
    check("collegamento interno esistente: " + ref, os.path.exists(os.path.join(DOCS, ref)))

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 18778), functools.partial(QuietHandler, directory=DOCS))
threading.Thread(target=srv.serve_forever, daemon=True).start()
with sync_playwright() as p:
    b = p.chromium.launch()
    for w, h, nome in ((1280, 900, "computer"), (360, 780, "telefono")):
        pg = b.new_page(viewport={"width": w, "height": h})
        esterne, errori_js = [], []
        pg.on("request", lambda r: esterne.append(r.url) if not r.url.startswith("http://127.0.0.1:18778") else None)
        pg.on("pageerror", lambda e: errori_js.append(str(e)))
        pg.goto("http://127.0.0.1:18778/"); pg.wait_for_timeout(600)
        check(nome + ": nessuna risorsa da altri siti (nessun tracciamento)", not esterne, esterne)
        check(nome + ": nessun errore JavaScript", not errori_js, errori_js)
        check(nome + ": niente scorrimento orizzontale", pg.evaluate("document.documentElement.scrollWidth") <= w)
        check(nome + ": impronta mostrata", pg.inner_text("#sha").strip() == dati["sha256"])
        check(nome + ": pulsante di download verso SourceForge", pg.get_attribute("[data-iso-href=scarica]", "href") == dati["scarica"])
    pg = b.new_page(); pg.goto("http://127.0.0.1:18778/"); pg.wait_for_timeout(300)
    pg.context.grant_permissions(["clipboard-read", "clipboard-write"])
    pg.click("[data-copia]"); pg.wait_for_timeout(300)
    check("«Copia» copia l'impronta", pg.evaluate("navigator.clipboard.readText()") == dati["sha256"])
    check("«Copia» mostra l'avviso", "copiata" in pg.inner_text("#avviso"))
    pg = b.new_page(); pg.goto("file://" + os.path.join(DOCS, "index.html")); pg.wait_for_timeout(300)
    check("aperta dal disco: i valori ci sono", pg.inner_text("#sha").strip() == dati["sha256"])
    b.close()
srv.shutdown()
print("✔ TUTTO A POSTO" if not errori else "✘ %d PROBLEMI" % len(errori))
sys.exit(1 if errori else 0)
