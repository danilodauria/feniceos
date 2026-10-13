# FeniceOS

**Un sistema libero e gentile che dà nuova vita ai computer e insegna l'informatica a tutti.**
Ideato e sviluppato da **Danilo D'Auria** — autore di «Tecnologia Gentile: Informatica Sostenibile».

🌐 **Sito e download:** https://danilodauria.github.io/feniceos/

FeniceOS è una distribuzione live basata su **Debian 12 «bookworm»** con desktop **MATE**, in italiano. Parte da chiavetta USB
senza toccare il disco e contiene già il [Professore Digitale](https://danilodauria.github.io/professore-digitale/),
LibreOffice, Thunderbird e Claws Mail, Firefox ESR e Falkon, il Negozio dei programmi (pacchetti Debian e Flathub),
il Centro FeniceOS e Fenice Ottimizza. Nessuna telemetria.

## Dove sta cosa
| Percorso | Contenuto |
|---|---|
| `docs/` | Il sito pubblicato con GitHub Pages (Settings → Pages → *Deploy from a branch* → `main` / `/docs`) |
| `docs/dati/iso.json` | Versione, dimensione, impronta SHA-256 e indirizzo di download della ISO |
| `docs/download/` | Libretto (schermo e stampa A4), file `.sha256`, script di costruzione |
| `strumenti/build_feniceos.sh` | Lo script che costruisce la ISO (`sudo ./build_feniceos.sh`) |
| `strumenti/aggiorna-iso.py` | Aggiorna il sito dopo una nuova ISO: `python3 strumenti/aggiorna-iso.py ~/fenice_build/FeniceOS_x64.iso --versione 2.3` |
| `tests/test_sito.py` | Prove automatiche del sito (Playwright) |

## La ISO non sta qui
GitHub non accetta file oltre i 100 MB nel repository né oltre i 2 GB nelle Release, e la ISO pesa più di 2 GB.
Per questo la ISO è su **SourceForge** (https://sourceforge.net/projects/feniceos/), una cartella per ogni versione,
con accanto il file `.sha256`.

## Licenze
- **Codice** (script, pagine, strumenti): [MIT](LICENSE).
- **Contenuti** (libretto, testi, logo e grafica): © 2026 Danilo D'Auria, [CC BY-NC-SA 4.0](LICENZA-CONTENUTI.md).
- **Programmi dentro la ISO**: le licenze libere dei rispettivi progetti (vedi il libretto, capitolo 24).
