#!/usr/bin/env python3
"""FeniceOS — aggiorna il sito quando esce una nuova ISO.

Uso (sul PC dove c'è la ISO appena costruita):
  python3 strumenti/aggiorna-iso.py ~/fenice_build/FeniceOS_x64.iso --versione 2.3
  python3 strumenti/aggiorna-iso.py ~/fenice_build/FeniceOS_x64.iso --versione 2.3 --url https://sourceforge.net/projects/ALTRO/files/2.3/FeniceOS_x64.iso/download

Cosa fa:
  1. calcola dimensione e impronta SHA-256 della ISO (qualche minuto: il file è grande);
  2. scrive docs/dati/iso.json e docs/download/<nome>.sha256;
  3. aggiorna i valori già scritti in docs/index.html (così la pagina è giusta anche aperta dal disco).
Poi: caricate la ISO su SourceForge nella cartella con il numero di versione e pubblicate il sito (git push).
Autore: Danilo D'Auria — licenza MIT
"""
import argparse, datetime, hashlib, html, json, os, re, sys

QUI = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(os.path.dirname(QUI), "docs")
MESI = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"]
PROGETTO_SF = "feniceos"


def sha256(percorso):
    h, fatti, tot = hashlib.sha256(), 0, os.path.getsize(percorso)
    with open(percorso, "rb") as f:
        for blocco in iter(lambda: f.read(8 << 20), b""):
            h.update(blocco); fatti += len(blocco)
            print("\r  impronta: %3d%%" % (100 * fatti // tot), end="", flush=True)
    print()
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description="Aggiorna il sito di FeniceOS con i dati di una nuova ISO")
    ap.add_argument("iso", help="percorso della ISO (es. ~/fenice_build/FeniceOS_x64.iso)")
    ap.add_argument("--versione", required=True, help="numero di versione di FeniceOS, es. 2.3")
    ap.add_argument("--url", help="indirizzo di download (predefinito: SourceForge, progetto «%s»)" % PROGETTO_SF)
    ap.add_argument("--data", help="data AAAA-MM-GG (predefinita: quella del file)")
    a = ap.parse_args()
    iso = os.path.expanduser(a.iso)
    if not os.path.isfile(iso):
        sys.exit("✘ ISO non trovata: %s" % iso)
    if not re.match(r"^\d+(\.\d+){1,2}$", a.versione):
        sys.exit("✘ Versione non valida: usate numeri come 2.3 o 2.3.1")
    nome = os.path.basename(iso)
    byte = os.path.getsize(iso)
    print("» %s (%.2f GB)" % (nome, byte / 1e9))
    impronta = sha256(iso)
    data = a.data or datetime.date.fromtimestamp(os.path.getmtime(iso)).isoformat()
    url = a.url or "https://sourceforge.net/projects/%s/files/%s/%s/download" % (PROGETTO_SF, a.versione, nome)
    vecchio = json.load(open(os.path.join(DOCS, "dati", "iso.json"), encoding="utf-8"))
    nuovo = dict(vecchio, versione=a.versione, nome=nome, byte=byte, sha256=impronta, data=data, scarica=url)
    with open(os.path.join(DOCS, "dati", "iso.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(nuovo, f, ensure_ascii=False, indent=2); f.write("\n")
    # il file .sha256 nel formato di sha256sum (si controlla con: sha256sum -c NOME.sha256)
    for vecchio_sha in [x for x in os.listdir(os.path.join(DOCS, "download")) if x.endswith(".iso.sha256")]:
        os.remove(os.path.join(DOCS, "download", vecchio_sha))
    with open(os.path.join(DOCS, "download", nome + ".sha256"), "w", encoding="utf-8", newline="\n") as f:
        f.write("%s  %s\n" % (impronta, nome))
    # valori scritti nella pagina
    p = os.path.join(DOCS, "index.html")
    t = open(p, encoding="utf-8").read()
    giorno = datetime.date.fromisoformat(data)
    valori = {"versione": a.versione, "nome": nome, "sha256": impronta, "base": nuovo.get("base", ""),
              "architettura": nuovo.get("architettura", ""), "dimensione": ("%.2f GB" % (byte / 1e9)).replace(".", ","),
              "data_lunga": "%d %s %d" % (giorno.day, MESI[giorno.month - 1], giorno.year)}
    for k, v in valori.items():
        t = re.sub(r'(data-iso="%s"[^>]*>)[^<]*(<)' % k, lambda m: m.group(1) + html.escape(v, quote=False) + m.group(2), t)
    for k in ("scarica", "tutte_le_versioni"):
        t = re.sub(r'(data-iso-href="%s" href=")[^"]*(")' % k, lambda m: m.group(1) + html.escape(nuovo[k]) + m.group(2), t)
    t = t.replace('href="download/%s.sha256"' % vecchio.get("nome", nome), 'href="download/%s.sha256"' % nome)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(t)
    print("✔ sito aggiornato: FeniceOS %s, %s, impronta %s…" % (a.versione, valori["dimensione"], impronta[:16]))
    print("  Ora caricate %s su SourceForge nella cartella «%s» e pubblicate il sito (git add -A, commit, push)." % (nome, a.versione))
    print("  Indirizzo di download: %s" % url)


if __name__ == "__main__":
    main()
