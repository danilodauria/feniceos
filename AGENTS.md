# AGENTS.md — feniceos

Se sei un assistente IA che riprende il lavoro qui, **prima di tutto leggi** il file di consegna comune:
https://github.com/danilodauria/danilodauria.github.io/blob/main/HANDOFF.md

Regola fondamentale: **non riscrivere, rinominare o rifattorizzare ciò che funziona.** Prima un piano dettagliato, poi la conferma di Danilo, poi il codice.

## In questo repository

- **Cos'è**: distro Linux live basata su Debian 12 (FeniceOS) e il suo sito.
- **Leggi nell'ordine**: README.md → ultimi commit (`git log --oneline -30`) → il resto della cartella.
- **Verifica prima e dopo ogni modifica**: `python3 tests/test_sito.py` (deve chiudere con «TUTTO A POSTO»).
- **Robot attivi**: nessun workflow GitHub Actions.
- **Da sapere**: `strumenti/build_feniceos.sh` genera la ISO live (Debian 12 + MATE): **non lanciarlo** senza che Danilo lo chieda. La versione è nel file `VERSIONE`: non cambiarla di tua iniziativa.

Dopo il lavoro aggiungi una riga al registro: https://github.com/danilodauria/danilodauria.github.io/blob/main/HANDOFF-REGISTRO.md
