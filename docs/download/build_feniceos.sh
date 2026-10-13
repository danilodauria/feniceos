#!/usr/bin/env bash
# =============================================================================
#  FeniceOS - Master Build Script v2.2
#  Ideato e sviluppato da Danilo D'Auria - un progetto FeniceOS
#
#  Genera una ISO "live" avviabile (Debian 12 "bookworm" + MATE) con:
#    - suono di avvio originale (licenza MIT) e sfondo "Alba della Fenice"
#    - dock in stile macOS (Plank) + tema WhiteSur (macOS-like, licenze libere)
#    - negozio app (GNOME Software) con Flathub + pacchetti Debian
#    - Professore Digitale 3.5.3 (scaricato dalla tua release GitHub, verificato
#      e provato: se il server non parte, la build si ferma subito)
#    - LibreOffice in italiano, Thunderbird + Claws Mail, Falkon, Firefox ESR
#    - "Centro FeniceOS" e "Fenice Ottimizza" nel menu Applicazioni
#
#  USO:      sudo ./build_feniceos.sh
#  SOLO ALBERO (nessuna build, per ispezionare i file generati):
#            ./build_feniceos.sh --tree-only
#  OPZIONI (le variabili vanno DOPO sudo, altrimenti sudo le scarta):
#            sudo FENICE_WORK=/mnt/disco/fenice ./build_feniceos.sh       cartella di lavoro
#            sudo FENICE_PANEL_LAYOUT=default ./build_feniceos.sh         pannello classico
#
#  Requisiti host: Debian/Ubuntu/Zorin con Internet, ~25 GB liberi, root.
#  La build avviene dentro un ambiente Debian 12 isolato (creato da debootstrap):
#  il "live-build" di Ubuntu/Zorin e' un fork diverso e NON va usato per Debian.
# =============================================================================
set -Eeuo pipefail

# ----------------------------- CONFIGURAZIONE --------------------------------
FENICE_VERSION="2.2"
DISTRO_NAME="FeniceOS"
ISO_NAME="FeniceOS_x64.iso"
DEBIAN_CODENAME="bookworm"
ARCH="amd64"
PD_VERSION="3.5.3"
PD_BASE_URL="https://github.com/danilodauria/professore-digitale/releases/download/v${PD_VERSION}"
PD_DEB="professore-digitale_${PD_VERSION}_all.deb"
PD_SITE="https://danilodauria.github.io/professore-digitale"
# Rete di sicurezza: il .deb della 3.5.2 non conteneva server/pd_tablet.py (importato da
# pd_server.py) e il server non partiva. La 3.5.3 e' gia' corretta e questa riparazione non scatta
# (lo script prova sempre il pacchetto cosi' com'e'). Resta utile se si torna alla 3.5.2: scarica
# il file dal commit esatto della 3.5.2 e ne controlla l'impronta.
PD_PATCH_COMMIT="c714bc38ea23bf51c3d506904ca0d3bc209c3bb8"
PD_PATCH_URL="https://raw.githubusercontent.com/danilodauria/professore-digitale/${PD_PATCH_COMMIT}/src/server/pd_tablet.py"
PD_PATCH_SHA256="ef65ec800ea3b0f945789cff320f7350e38ed32f6b04b27cf255d0e1e56a9b82"
# layout pannello MATE: "fenice" (barra in alto + dock) oppure "default" (classico)
PANEL_LAYOUT="${FENICE_PANEL_LAYOUT:-fenice}"
MIN_FREE_GB=25

# Pacchetti indispensabili (se uno manca nei repository la build si ferma)
CORE_PACKAGES=(
  mate-desktop-environment lightdm lightdm-gtk-greeter
  firefox-esr network-manager network-manager-gnome
  plank flatpak gnome-software gnome-software-plugin-flatpak
  zenity pulseaudio pulseaudio-utils pavucontrol alsa-utils
  git sassc libglib2.0-dev-bin libxml2-utils dconf-cli libglib2.0-bin
  sudo curl ca-certificates xdg-utils desktop-file-utils librsvg2-common
  policykit-1 libgtk-3-bin locales
  # Ufficio in italiano (LibreOffice 7.4 di Debian 12; Base escluso perche' richiede Java)
  libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-draw libreoffice-math
  libreoffice-gtk3 libreoffice-l10n-it libreoffice-help-it hunspell-it mythes-it hyphen-it
  # Posta: Thunderbird (completo) + Claws Mail (leggero)
  thunderbird thunderbird-l10n-it claws-mail
  # Browser aggiuntivo richiesto (Firefox ESR resta quello predefinito)
  falkon
)
# Pacchetti facoltativi: se uno non e' disponibile viene saltato senza fermare la build
OPTIONAL_PACKAGES=(
  fonts-inter papirus-icon-theme arc-theme
  zram-tools earlyoom preload thermald tlp
  vlc firefox-esr-l10n-it synaptic mate-tweak
  gnome-disk-utility file-roller claws-mail-i18n
  # Firmware piu' comuni (Wi-Fi, grafica) per i PC ricondizionati
  firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211
  firmware-misc-nonfree firmware-amd-graphics
)
# ------------------------------------------------------------------------------

TREE_ONLY=0
for a in "$@"; do
  case "$a" in
    --tree-only) TREE_ONLY=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $a (usa --help)"; exit 2 ;;
  esac
done

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"; REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  REAL_USER="${USER:-root}"; REAL_HOME="${HOME:-/root}"
fi
WORK="${FENICE_WORK:-$REAL_HOME/fenice_build}"
BUILDER="$WORK/builder"          # ambiente Debian 12 che esegue live-build
TREE="$WORK/tree"                # configurazione live-build (montata in /build)
CACHE="$WORK/cache"              # download riutilizzabili
INC="$TREE/config/includes.chroot"
HOOKS="$TREE/config/hooks/live"

log()  { printf '\n\033[1;35m[FeniceOS]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Attenzione]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERRORE]\033[0m %s\n' "$*" >&2; exit 1; }
embed() { # embed <destinazione> <permessi>  (contenuto da stdin)
  mkdir -p "$(dirname "$1")"; cat > "$1"; chmod "$2" "$1"
}

# ------------------------------ MONTAGGI --------------------------------------
cleanup_mounts() {
  [ -d "$WORK" ] || return 0
  local t
  while read -r t; do umount -l "$t" 2>/dev/null || true; done < <(
    findmnt -rn -o TARGET | grep -E "^${WORK}(/|$)" | sort -r || true)
}
mount_builder() {
  mkdir -p "$BUILDER/proc" "$BUILDER/dev/pts" "$BUILDER/build" "$TREE"
  mountpoint -q "$BUILDER/proc"    || mount -t proc proc "$BUILDER/proc"
  mountpoint -q "$BUILDER/dev"     || mount --bind /dev "$BUILDER/dev"
  mountpoint -q "$BUILDER/dev/pts" || mount --bind /dev/pts "$BUILDER/dev/pts"
  mountpoint -q "$BUILDER/build"   || mount --bind "$TREE" "$BUILDER/build"
  cp -L /etc/resolv.conf "$BUILDER/etc/resolv.conf"
}
inb() { # esegue un comando dentro l'ambiente Debian 12
  chroot "$BUILDER" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"
}

# ------------------------------ CONTROLLI HOST --------------------------------
host_checks() {
  [ "$(id -u)" -eq 0 ] || die "Serve root. Rilancia con: sudo $0"
  command -v apt-get >/dev/null || die "Serve un sistema Debian/Ubuntu (apt-get non trovato)."
  [ "$(uname -m)" = "x86_64" ] || die "Serve un PC a 64 bit (x86_64)."
  mkdir -p "$WORK"
  local free_gb
  free_gb=$(df --output=avail -BG "$WORK" | tail -1 | tr -dc '0-9')
  [ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || die "Spazio libero insufficiente: ${free_gb}GB, servono ${MIN_FREE_GB}GB."
  log "Spazio disponibile: ${free_gb}GB - OK"
  # /home montata noexec/nodev bloccherebbe la build
  if findmnt -no OPTIONS -T "$WORK" | grep -qE '(^|,)(noexec|nodev)(,|$)'; then
    die "Il disco di $WORK e' montato con noexec/nodev. Scegli un'altra cartella: sudo FENICE_WORK=/percorso $0"
  fi
}
install_host_deps() {
  log "Installazione strumenti sul computer (debootstrap, chiavi Debian, curl, python3)"
  apt-get update -qq
  apt-get install -y debootstrap debian-archive-keyring ca-certificates curl python3 gnupg
}

# ------------------------------ AMBIENTE DEBIAN 12 ----------------------------
create_builder() {
  if [ ! -e "$BUILDER/.fenice-builder-ok" ]; then
    log "Creo l'ambiente Debian 12 isolato per la build (circa 5-10 minuti, solo la prima volta)"
    rm -rf "$BUILDER"; mkdir -p "$BUILDER"
    debootstrap --arch="$ARCH" --variant=minbase --include=ca-certificates,gnupg \
      "$DEBIAN_CODENAME" "$BUILDER" http://deb.debian.org/debian
    cat > "$BUILDER/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
    mount_builder
    inb apt-get update
    inb apt-get install -y live-build debootstrap debian-archive-keyring squashfs-tools xorriso \
      mtools dosfstools cpio fdisk kmod procps xz-utils isolinux syslinux syslinux-common syslinux-utils \
      grub-pc-bin grub-efi-amd64-bin grub-common
    touch "$BUILDER/.fenice-builder-ok"
  else
    log "Ambiente Debian 12 gia' pronto, lo riutilizzo"
    mount_builder
  fi
  log "Versione live-build usata: $(inb dpkg-query -W -f='${Version}' live-build)"
}

# ------------------------------ CONTROLLO PREVENTIVO --------------------------
preflight_packages() {
  log "Controllo preventivo: verifico che ogni pacchetto esista su Debian ${DEBIAN_CODENAME}"
  inb apt-get update -qq >/dev/null 2>&1 || warn "Aggiornamento elenchi nell'ambiente di build non riuscito."
  local p cand missing=() miss_opt=()
  for p in "${CORE_PACKAGES[@]}"; do
    cand="$(inb apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then missing+=("$p"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "Pacchetti non trovati su Debian ${DEBIAN_CODENAME}: ${missing[*]}
La build non e' ancora partita: correggi l'elenco CORE_PACKAGES in cima allo script e rilancia."
  fi
  if ! inb apt-get -s install "${CORE_PACKAGES[@]}" >"$WORK/preflight.log" 2>&1; then
    tail -n 15 "$WORK/preflight.log" >&2
    die "I pacchetti scelti hanno conflitti di dipendenze (dettagli in $WORK/preflight.log)."
  fi
  for p in "${OPTIONAL_PACKAGES[@]}"; do
    cand="$(inb apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then miss_opt+=("$p"); fi
  done
  [ "${#miss_opt[@]}" -eq 0 ] || warn "Pacchetti facoltativi non disponibili (verranno saltati): ${miss_opt[*]}"
  log "Controllo superato: ${#CORE_PACKAGES[@]} pacchetti essenziali trovati e compatibili"
}

# ------------------------------ DOWNLOAD --------------------------------------
pd_smoke() { # 0 se il server riesce a importare tutti i suoi moduli
  python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import pd_server' "$1" >/dev/null 2>&1
}
pd_integrity_check() { # pd_integrity_check <file.deb>: prova il server e, se serve, ripara
  local chk="$WORK/pdcheck" srv patch
  rm -rf "$chk"; mkdir -p "$chk"
  dpkg-deb -x "$1" "$chk" || die "Impossibile aprire $PD_DEB per il controllo."
  srv="$chk/usr/share/professore-digitale/server"
  [ -f "$srv/pd_server.py" ] || die "Nel pacchetto manca pd_server.py: la release non e' valida."
  if pd_smoke "$srv"; then
    log "Controllo del Professore Digitale: il server si avvia correttamente"
  elif [ ! -f "$srv/pd_tablet.py" ]; then
    warn "Nel .deb ${PD_VERSION} manca server/pd_tablet.py: cosi' com'e' il server non parte."
    log "Applico la riparazione dal tuo repository (commit ${PD_PATCH_COMMIT:0:7})"
    patch="$CACHE/pd_tablet.py"
    curl -fsSL --retry 3 -o "$patch" "$PD_PATCH_URL" || die "Download di pd_tablet.py fallito."
    [ "$(sha256sum "$patch" | awk '{print $1}')" = "$PD_PATCH_SHA256" ] \
      || die "L'impronta di pd_tablet.py non corrisponde: file scartato."
    install -m 0644 "$patch" "$srv/pd_tablet.py"
    pd_smoke "$srv" || die "Anche dopo la riparazione il server del Professore Digitale non parte."
    mkdir -p "$INC/usr/share/fenice/patches"
    install -m 0644 "$patch" "$INC/usr/share/fenice/patches/pd_tablet.py"
    log "Riparazione verificata: sara' applicata alla ISO"
  else
    die "Il server del Professore Digitale non parte per un motivo diverso da pd_tablet.py. Prova: python3 -c \"import sys; sys.path.insert(0,'$srv'); import pd_server\""
  fi
  rm -rf "$chk"
}

fetch_professore() {
  mkdir -p "$CACHE" "$TREE/config/packages.chroot"
  local deb="$CACHE/$PD_DEB" sums="$CACHE/SHA256SUMS"
  log "Professore Digitale ${PD_VERSION}: scarico dalla release GitHub"
  if curl -fsSL --retry 3 -o "$sums" "$PD_SITE/SHA256SUMS"; then :; else warn "SHA256SUMS non scaricabile"; rm -f "$sums"; fi
  local want=""
  [ -f "$sums" ] && want="$(grep -F "$PD_DEB" "$sums" | awk '{print $1}' | head -n1 || true)"
  if [ -f "$deb" ] && [ -n "$want" ] && [ "$(sha256sum "$deb" | awk '{print $1}')" = "$want" ]; then
    log "File gia' scaricato e verificato"
  else
    curl -fL --retry 3 --progress-bar -o "$deb" "$PD_BASE_URL/$PD_DEB" \
      || die "Download di $PD_DEB fallito. Controlla la release v${PD_VERSION} su GitHub."
  fi
  if [ -n "$want" ]; then
    [ "$(sha256sum "$deb" | awk '{print $1}')" = "$want" ] \
      || die "Impronta SHA-256 di $PD_DEB NON corrisponde a quella pubblicata: file scartato."
    log "Impronta SHA-256 verificata (corrisponde a quella del tuo sito)"
  else
    warn "Impronta di $PD_DEB non presente in SHA256SUMS: salto la verifica."
  fi
  dpkg-deb --info "$deb" >/dev/null 2>&1 || die "$PD_DEB non e' un pacchetto .deb valido."
  pd_integrity_check "$deb"
  cp -f "$deb" "$TREE/config/packages.chroot/$PD_DEB"
  # Vademecum (facoltativo, per la guida offline)
  mkdir -p "$INC/usr/share/fenice/guida"
  curl -fsSL --retry 2 -o "$INC/usr/share/fenice/guida/Vademecum_Professore_Digitale.pdf" \
    "$PD_SITE/Vademecum_Professore_Digitale.pdf" || warn "Vademecum non scaricato (facoltativo)."
}

# ------------------------------ RISORSE ORIGINALI -----------------------------
gen_assets() {
  log "Genero suono di avvio e sfondo originali (licenza MIT)"
  mkdir -p "$WORK/assets"
  embed "$WORK/gen_assets.py" 644 <<'__FENICE_EOF__'
#!/usr/bin/env python3
"""
FeniceOS - generatore di risorse originali (solo libreria standard di Python).

Crea:
  1. fenice-startup.wav  - jingle di avvio "Alba della Fenice" (composizione originale)
  2. fenice-alba.png     - sfondo scrivania (gradiente alba con alone caldo)

Copyright (c) 2026 Danilo D'Auria - FeniceOS
Licenza: MIT (suono e sfondo generati da questo codice, nessun campione di terzi)

Uso:  python3 gen_assets.py <cartella_di_output>
"""
import math
import os
import random
import struct
import sys
import wave
import zlib

# --------------------------------------------------------------------------
# 1. JINGLE DI AVVIO
# --------------------------------------------------------------------------
SR = 44100          # campioni al secondo
DUR = 5.2           # durata totale in secondi


def hz(semitones_from_a4):
    return 440.0 * 2 ** (semitones_from_a4 / 12.0)


# Arpeggio ascendente di Re maggiore con nona (D - A - D - F# - A - E):
# suona "luminoso", come un sorgere del sole. Ogni nota: (semitoni da La4, inizio s, ampiezza)
NOTES = [
    (-7, 0.00, 0.60),   # Re4
    (0, 0.38, 0.55),    # La4
    (5, 0.76, 0.55),    # Re5
    (9, 1.14, 0.50),    # Fa#5
    (14, 1.52, 0.45),   # Si5
    (19, 1.95, 0.50),   # Mi6 (nona, apre l'accordo)
]
# Accordo finale che "respira" (Re3, La3, Re4, Fa#4) - entra dolcemente e si spegne lento
PAD = [(-31, 0.40, 0.18), (-24, 0.40, 0.16), (-19, 0.45, 0.16), (-15, 0.50, 0.14)]


def bell(freq, t, decay):
    """Timbro tipo campana morbida: fondamentale + armonici leggermente inarmonici."""
    parts = (
        (1.00, 1.000, decay),
        (2.00, 0.360, decay * 1.5),
        (3.01, 0.150, decay * 2.2),
        (4.20, 0.060, decay * 3.2),
    )
    s = 0.0
    for mult, amp, dec in parts:
        s += amp * math.sin(2 * math.pi * freq * mult * t) * math.exp(-dec * t)
    return s


def pad_tone(freq, t, length):
    """Tono lungo e morbido per il fondo: attacco lento, rilascio lento."""
    att = min(1.0, t / 0.9)
    rel = min(1.0, max(0.0, (length - t) / 1.6))
    env = att * rel
    # leggero chorus: due oscillatori appena scordati
    return env * (math.sin(2 * math.pi * freq * t) +
                  math.sin(2 * math.pi * freq * 1.003 * t)) * 0.5


def render_jingle():
    n = int(SR * DUR)
    left = [0.0] * n
    right = [0.0] * n

    for semis, start, amp in NOTES:
        f = hz(semis)
        i0 = int(start * SR)
        pan = 0.35 + 0.30 * (semis + 7) / 26.0      # note acute leggermente a destra
        for i in range(i0, min(n, i0 + int(3.6 * SR))):
            t = (i - i0) / SR
            attack = min(1.0, t / 0.004)             # click-free
            v = amp * attack * bell(f, t, 1.35)
            left[i] += v * (1 - pan)
            right[i] += v * pan

    pad_len = DUR - 0.4
    for semis, start, amp in PAD:
        f = hz(semis)
        i0 = int(start * SR)
        for i in range(i0, min(n, i0 + int(pad_len * SR))):
            t = (i - i0) / SR
            v = amp * pad_tone(f, t, pad_len)
            left[i] += v
            right[i] += v

    # Eco/riverbero semplice (3 linee di ritardo con feedback) per dare spazio
    def reverb(x):
        out = x[:]
        for delay_ms, gain in ((61, 0.30), (97, 0.24), (143, 0.18), (211, 0.12)):
            d = int(SR * delay_ms / 1000)
            for i in range(d, n):
                out[i] += out[i - d] * gain
        return out

    left, right = reverb(left), reverb(right)
    # canale destro con micro-ritardo per ampiezza stereo
    shift = int(SR * 0.011)
    right = [0.0] * shift + right[:-shift]

    # normalizzazione a -3 dBFS e dissolvenze
    peak = max(max(abs(v) for v in left), max(abs(v) for v in right))
    scale = 0.70 / peak
    fade_in = int(0.02 * SR)
    fade_out = int(1.4 * SR)
    frames = bytearray()
    for i in range(n):
        g = scale
        if i < fade_in:
            g *= i / fade_in
        if i > n - fade_out:
            g *= max(0.0, (n - i) / fade_out) ** 1.5
        l = max(-1.0, min(1.0, left[i] * g))
        r = max(-1.0, min(1.0, right[i] * g))
        frames += struct.pack("<hh", int(l * 32767), int(r * 32767))
    return bytes(frames)


def write_wav(path):
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(render_jingle())


# --------------------------------------------------------------------------
# 2. SFONDO "ALBA" (PNG, solo zlib/struct)
# --------------------------------------------------------------------------
def lerp(a, b, t):
    return a + (b - a) * t


def write_png(path, w=1920, h=1080):
    # tavolozza: notte blu profondo -> viola -> arancio caldo all'orizzonte
    stops = [
        (0.00, (10, 18, 48)),
        (0.45, (38, 36, 92)),
        (0.72, (150, 66, 96)),
        (0.88, (236, 120, 60)),
        (1.00, (255, 176, 80)),
    ]

    def sky(t):
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t <= t1:
                k = (t - t0) / (t1 - t0)
                return [lerp(c0[j], c1[j], k) for j in range(3)]
        return list(stops[-1][1])

    cx, cy = w * 0.5, h * 0.93        # centro dell'alone
    rad = h * 0.75
    rng = random.Random(7)             # grana costante, riproducibile
    raw = bytearray()
    for y in range(h):
        base = sky(y / (h - 1))
        raw.append(0)                  # filtro PNG: nessuno
        dy = (y - cy) / rad
        for x in range(w):
            dx = (x - cx) / (rad * 1.5)
            glow = max(0.0, 1.0 - math.sqrt(dx * dx + dy * dy)) ** 2.2
            n = rng.uniform(-1.6, 1.6)  # grana leggera contro il banding
            r = base[0] + 90 * glow + n
            g = base[1] + 70 * glow + n
            b = base[2] + 20 * glow + n
            raw += bytes((max(0, min(255, int(r))),
                          max(0, min(255, int(g))),
                          max(0, min(255, int(b)))))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    write_wav(os.path.join(out, "fenice-startup.wav"))
    write_png(os.path.join(out, "fenice-alba.png"))
    print("Creati: fenice-startup.wav, fenice-alba.png in", out)
__FENICE_EOF__
  python3 -I "$WORK/gen_assets.py" "$WORK/assets" >/dev/null
  mkdir -p "$INC/usr/share/fenice/sounds" "$INC/usr/share/backgrounds/fenice"
  cp "$WORK/assets/fenice-startup.wav" "$INC/usr/share/fenice/sounds/"
  cp "$WORK/assets/fenice-alba.png"    "$INC/usr/share/backgrounds/fenice/"
}

# ------------------------------ CONFIG live-build -----------------------------
lb_config() {
  log "Configuro live-build (Debian ${DEBIAN_CODENAME}, ${ARCH}, ISO ibrida per Rufus/USB)"
  if [ "$TREE_ONLY" -eq 1 ]; then mkdir -p "$TREE/config"; return 0; fi
  inb bash -c "cd /build && lb config noauto \
    --mode debian \
    --distribution ${DEBIAN_CODENAME} \
    --architectures ${ARCH} \
    --linux-flavours ${ARCH} \
    --binary-images iso-hybrid \
    --archive-areas 'main contrib non-free non-free-firmware' \
    --debian-installer none \
    --memtest none \
    --iso-volume FENICEOS_LIVE \
    --iso-application '${DISTRO_NAME} ${FENICE_VERSION}' \
    --iso-publisher 'Progetto Fenice - Danilo D Auria' \
    --bootappend-live 'boot=live components quiet locales=it_IT.UTF-8 keyboard-layouts=it timezone=Europe/Rome'"
}

write_tree() {
  log "Scrivo configurazione, script, menu, dock e personalizzazioni"
  mkdir -p "$TREE/config/package-lists" "$HOOKS" "$INC"

  # ---- elenco pacchetti ----
  printf '%s\n' "${CORE_PACKAGES[@]}" > "$TREE/config/package-lists/fenice.list.chroot"
  printf '%s\n' "${OPTIONAL_PACKAGES[@]}" | embed "$INC/usr/share/fenice/optional-packages.txt" 644
  cat > "$INC/usr/share/fenice/build.conf" <<EOF
PANEL_LAYOUT=${PANEL_LAYOUT}
FENICE_VERSION=${FENICE_VERSION}
EOF

  # ---- suono di avvio ----
  embed "$INC/usr/local/bin/fenice-startup-sound" 755 <<'__FENICE_EOF__'
#!/usr/bin/env bash
# Suona il jingle "Alba della Fenice" quando la scrivania e' pronta.
# Per disattivarlo: crea il file ~/.config/fenice/no-startup-sound (o usa il Centro FeniceOS).
[ -e "$HOME/.config/fenice/no-startup-sound" ] && exit 0
SND=/usr/share/fenice/sounds/fenice-startup.wav
[ -f "$SND" ] || exit 0
for _ in $(seq 1 20); do
  if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then break; fi
  sleep 0.5
done
sleep 1
if command -v paplay >/dev/null 2>&1; then paplay "$SND" 2>/dev/null
elif command -v aplay >/dev/null 2>&1; then aplay -q "$SND" 2>/dev/null
fi
exit 0
__FENICE_EOF__
  embed "$INC/etc/xdg/autostart/fenice-startup-sound.desktop" 644 <<'__FENICE_EOF__'
[Desktop Entry]
Type=Application
Name=Suono di avvio FeniceOS
Comment=Musica di apertura della scrivania
Exec=/usr/local/bin/fenice-startup-sound
OnlyShowIn=MATE;
NoDisplay=true
X-MATE-Autostart-Phase=Application
X-MATE-Autostart-Delay=2
__FENICE_EOF__

  # ---- dock (Plank) ----
  embed "$INC/usr/local/bin/fenice-dock" 755 <<'__FENICE_EOF__'
#!/usr/bin/env bash
# Prepara (al primo avvio) e lancia il dock in stile macOS (Plank).
CONF="$HOME/.config/fenice"
LAUNCH="$HOME/.config/plank/dock1/launchers"
SCHEMA="net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/"
mkdir -p "$CONF" "$LAUNCH"

find_desktop() {
  local d
  for d in /usr/share/applications /var/lib/flatpak/exports/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/$1" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}

if [ ! -e "$CONF/dock-v3" ]; then
  rm -f "$LAUNCH"/*.dockitem
  items=()
  add() { # add <nome> <file.desktop>
    local f; f="$(find_desktop "$2")" || return 0
    printf '[PlankDockItemPreferences]\nLauncher=file://%s\n' "$f" > "$LAUNCH/$1.dockitem"
    items+=("'$1.dockitem'")
  }
  add 01-centro fenice-centro.desktop
  add 02-professore professore-digitale.desktop
  add 03-firefox firefox-esr.desktop
  add 04-posta thunderbird.desktop
  add 05-writer libreoffice-writer.desktop
  add 06-file caja.desktop
  add 07-negozio fenice-store.desktop
  add 08-ottimizza fenice-ottimizza.desktop
  add 09-impostazioni mate-control-center.desktop
  add 10-terminale mate-terminal.desktop
  list="$(IFS=,; echo "${items[*]}")"
  gsettings set "$SCHEMA" dock-items "[${list}]" 2>/dev/null
  gsettings set "$SCHEMA" icon-size 52 2>/dev/null
  gsettings set "$SCHEMA" zoom-enabled true 2>/dev/null
  gsettings set "$SCHEMA" zoom-percent 160 2>/dev/null
  gsettings set "$SCHEMA" theme 'Transparent' 2>/dev/null
  gsettings set "$SCHEMA" position 'bottom' 2>/dev/null
  gsettings set "$SCHEMA" hide-mode 'none' 2>/dev/null
  touch "$CONF/dock-v3"
fi
exec plank
__FENICE_EOF__
  embed "$INC/etc/xdg/autostart/fenice-dock.desktop" 644 <<'__FENICE_EOF__'
[Desktop Entry]
Type=Application
Name=Dock FeniceOS
Comment=Barra delle applicazioni in stile macOS
Exec=/usr/local/bin/fenice-dock
OnlyShowIn=MATE;
NoDisplay=true
X-MATE-Autostart-Phase=Application
X-MATE-Autostart-Delay=1
__FENICE_EOF__

  # ---- negozio app ----
  embed "$INC/usr/local/bin/fenice-store" 755 <<'__FENICE_EOF__'
#!/usr/bin/env bash
# Negozio delle app di FeniceOS: pacchetti Debian + Flathub (GNOME Software).
if command -v flatpak >/dev/null 2>&1 && ! flatpak remotes --system 2>/dev/null | grep -q '^flathub'; then
  CMD=(flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo)
  if [ "$(id -u)" -eq 0 ]; then "${CMD[@]}" 2>/dev/null
  elif sudo -n true 2>/dev/null; then sudo -n "${CMD[@]}" 2>/dev/null
  else pkexec "${CMD[@]}" 2>/dev/null; fi
fi
exec gnome-software "$@"
__FENICE_EOF__

  # ---- Video e lezioni ----
  embed "$INC/usr/local/bin/fenice-video" 755 <<'__FENICE_EOF__'
#!/usr/bin/env bash
# Apre la cartella dei video di FeniceOS. Se e' vuota lo spiega e propone la cartella Video personale.
D=/usr/share/fenice/video
if find "$D" -type f ! -name 'LEGGIMI*' 2>/dev/null | grep -q .; then exec caja "$D"; fi
if zenity --question --title="Video e lezioni" --width=460 \
     --ok-label="Apri i miei video" --cancel-label="Chiudi" \
     --text=$'In questa edizione di FeniceOS non ci sono ancora video.\nLe lezioni si trovano dentro il Professore Digitale.\n\nVuoi aprire la tua cartella Video?' 2>/dev/null; then
  mkdir -p "$HOME/Video"
  exec caja "$HOME/Video"
fi
exit 0
__FENICE_EOF__

  # ---- Fenice Ottimizza ----
  embed "$INC/usr/local/bin/fenice-ottimizza" 755 <<'__FENICE_EOF__'
#!/usr/bin/env bash
# Fenice Ottimizza - ottimizzazione guidata del computer. Licenza MIT - Danilo D'Auria
# Uso:  fenice-ottimizza            apre la finestra guidata
#       fenice-ottimizza --stato    mostra lo stato del sistema
#       fenice-ottimizza --applica ram,sysctl,log   applica voci da terminale
#       aggiungi --prova per vedere cosa verrebbe fatto senza modificare nulla
set -u
APP="Fenice Ottimizza"
SELF="$(readlink -f "$0")"
DRY=0
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/fenice-ottimizza.log"
PLANK_SCHEMA="net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/"

run() { if [ "$DRY" = 1 ]; then echo "[prova] $*"; else "$@"; fi; }
put() { # put <file>  (contenuto da stdin)
  if [ "$DRY" = 1 ]; then echo "[prova] scrivo $1"; cat >/dev/null
  else mkdir -p "$(dirname "$1")"; cat > "$1"; fi
}
have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }
need_pkg() {
  have_pkg "$1" && return 0
  run apt-get install -y "$1" || { echo "Pacchetto $1 non disponibile (serve Internet)."; return 1; }
}
unit_exists() { systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^$1.service"; }

# ---- azioni da amministratore -------------------------------------------------
root_action() {
  case "$1" in
    ram)
      need_pkg zram-tools || return 1
      printf 'ALGO=zstd\nPERCENT=50\nPRIORITY=100\n' | put /etc/default/zramswap
      run systemctl restart zramswap.service || run systemctl enable --now zramswap.service
      echo "RAM compressa (zram) attiva." ;;
    sysctl)
      if swapon --noheadings --show=NAME 2>/dev/null | grep -q zram; then SW=100; PC=0; else SW=30; PC=3; fi
      put /etc/sysctl.d/99-fenice.conf <<EOF
# FeniceOS - regolazione memoria
vm.swappiness=$SW
vm.vfs_cache_pressure=50
vm.page-cluster=$PC
EOF
      run sysctl --system >/dev/null
      echo "Memoria regolata (swappiness $SW)." ;;
    oom)
      need_pkg earlyoom || return 1
      run systemctl enable --now earlyoom.service
      echo "Protezione anti-blocco attiva." ;;
    trim)
      run fstrim -av || true
      echo "TRIM eseguito sui dischi che lo supportano." ;;
    pulizia)
      run apt-get clean
      run journalctl --vacuum-size=50M >/dev/null 2>&1 || true
      echo "Cache dei pacchetti e vecchi registri puliti." ;;
    log)
      put /etc/systemd/journald.conf.d/fenice.conf <<'EOF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=50M
EOF
      run systemctl restart systemd-journald.service
      echo "Registri di sistema limitati a 50 MB." ;;
    preload)
      need_pkg preload || return 1
      run systemctl enable --now preload.service
      echo "Preload attivo (utile su dischi meccanici)." ;;
    servizi)
      for s in ModemManager cups-browsed; do
        unit_exists "$s" && run systemctl disable --now "$s.service"
      done
      echo "Servizi poco usati disattivati." ;;
    *) echo "Azione sconosciuta: $1"; return 2 ;;
  esac
}

# ---- azioni dell'utente --------------------------------------------------------
restart_plank() {
  [ "$DRY" = 1 ] && { echo "[prova] riavvio del dock"; return 0; }
  pkill -x plank 2>/dev/null; sleep 1
  nohup setsid plank >/dev/null 2>&1 &
}
user_action() {
  case "$1" in
    leggera)
      run gsettings set org.mate.Marco.general compositing-manager false
      run gsettings set "$PLANK_SCHEMA" zoom-enabled false
      run gsettings set "$PLANK_SCHEMA" theme 'Default'
      restart_plank
      echo "Modalita' leggera attiva: meno effetti, piu' scatto." ;;
    effetti)
      run gsettings set org.mate.Marco.general compositing-manager true
      run gsettings set "$PLANK_SCHEMA" zoom-enabled true
      run gsettings set "$PLANK_SCHEMA" theme 'Transparent'
      restart_plank
      echo "Effetti grafici riattivati." ;;
    miniature)
      if [ "$DRY" = 1 ]; then echo "[prova] svuoto ~/.cache/thumbnails"; else rm -rf "$HOME/.cache/thumbnails"/* 2>/dev/null; fi
      echo "Miniature in cache eliminate." ;;
    cestino)
      run gio trash --empty
      echo "Cestino svuotato." ;;
    *) echo "Azione sconosciuta: $1"; return 2 ;;
  esac
}

asroot() {
  if [ "$DRY" = 1 ]; then "$SELF" --prova --root "$@"; return; fi
  if [ "$(id -u)" -eq 0 ]; then "$SELF" --root "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$SELF" --root "$@"
  else pkexec "$SELF" --root "$@"; fi
}

apply_one() {
  case "$1" in
    ram|sysctl|oom|trim|log|preload|servizi) asroot "$1" ;;
    pulizia) asroot pulizia; user_action miniature ;;
    leggera|effetti|miniature|cestino) user_action "$1" ;;
    *) echo "Voce sconosciuta: $1" ;;
  esac
}

status_text() {
  echo "== Memoria =="; free -h
  echo; echo "== Swap / zram =="; swapon --show 2>/dev/null || echo "nessuna"
  command -v zramctl >/dev/null && zramctl 2>/dev/null
  echo; echo "== Servizi di ottimizzazione =="
  for s in zramswap earlyoom preload; do
    printf '%-10s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo 'non installato')"
  done
  echo; echo "== Disco =="; df -h / 2>/dev/null | tail -n 2
  echo; printf 'Effetti grafici (compositing): '
  gsettings get org.mate.Marco.general compositing-manager 2>/dev/null || echo "?"
}

gui() {
  command -v zenity >/dev/null || { echo "zenity non trovato."; exit 1; }
  while true; do
    sel="$(zenity --list --checklist --title="$APP" --width=780 --height=600 \
      --text="<b>Scegli cosa ottimizzare.</b>"$'\n'"Le voci gia' spuntate sono sicure e consigliate; le altre sono facoltative." \
      --column="Fai" --column="id" --column="Azione" --hide-column=2 --print-column=2 --separator=" " \
      --extra-button="Stato del sistema" --ok-label="Applica" --cancel-label="Chiudi" \
      TRUE  ram       "Comprimi la RAM (zram): piu' fluido con poca memoria" \
      TRUE  sysctl    "Regola la gestione della memoria" \
      TRUE  oom       "Protezione anti-blocco quando la memoria finisce" \
      TRUE  pulizia   "Libera spazio: cache pacchetti, vecchi registri, miniature" \
      TRUE  log       "Limita i registri di sistema a 50 MB" \
      FALSE trim      "Ottimizza i dischi SSD (TRIM)" \
      FALSE preload   "Avvio piu' rapido dei programmi (solo dischi meccanici)" \
      FALSE servizi   "Disattiva servizi poco usati (modem 3G, stampanti di rete automatiche)" \
      FALSE leggera   "Modalita' leggera: meno effetti grafici (PC molto vecchi)" \
      FALSE effetti   "Riattiva gli effetti grafici (dopo la modalita' leggera)" \
      FALSE cestino   "Svuota il cestino (cancella i file per sempre)" 2>/dev/null)"
    rc=$?
    if [ "$sel" = "Stato del sistema" ]; then
      status_text | zenity --text-info --title="Stato del sistema" --width=640 --height=520 2>/dev/null
      continue
    fi
    [ "$rc" -ne 0 ] && break
    [ -z "$sel" ] && { zenity --info --text="Non hai scelto nessuna voce." 2>/dev/null; continue; }
    mkdir -p "$(dirname "$LOG")"; : > "$LOG"
    ( for id in $sel; do echo "# Applico: $id"; apply_one "$id" >> "$LOG" 2>&1; done ) \
      | zenity --progress --pulsate --auto-close --no-cancel --title="$APP" --text="Lavoro in corso..." 2>/dev/null
    zenity --text-info --title="$APP - Fatto" --width=600 --height=420 --filename="$LOG" 2>/dev/null
  done
}

# ---- avvio ---------------------------------------------------------------------
MODE=gui; LIST=""; ROOT_ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prova) DRY=1 ;;
    --stato) MODE=stato ;;
    --applica) MODE=applica; LIST="${2:-}"; shift ;;
    --root) MODE=root; ROOT_ACTION="${2:-}"; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $1"; exit 2 ;;
  esac
  shift
done
case "$MODE" in
  gui) gui ;;
  stato) status_text ;;
  applica) for id in ${LIST//,/ }; do apply_one "$id"; done ;;
  root)
    [ "$(id -u)" -eq 0 ] || [ "$DRY" = 1 ] || { echo "Servono i permessi di amministratore."; exit 1; }
    root_action "$ROOT_ACTION" ;;
esac
__FENICE_EOF__

  # ---- Centro FeniceOS ----
  embed "$INC/usr/local/bin/fenice-centro" 755 <<'__FENICE_EOF__'
#!/usr/bin/env bash
# Centro FeniceOS - tutto in un posto: programmi, guide, quiz, video, ottimizzazione.
APP="Centro FeniceOS"
SHARE=/usr/share/fenice
MUTE="$HOME/.config/fenice/no-startup-sound"

open_url() { xdg-open "$1" >/dev/null 2>&1 & }
find_pd() {
  local f=/usr/share/applications/professore-digitale.desktop
  if [ -f "$f" ]; then echo "$f"; return; fi
  grep -l -i 'professore' /usr/share/applications/*.desktop 2>/dev/null | grep -v -e '/fenice-' -e 'setup' | head -n1
}
launch_pd() {
  local f; f="$(find_pd)"
  if [ -n "$f" ]; then gio launch "$f" >/dev/null 2>&1 || gtk-launch "$(basename "$f" .desktop)" >/dev/null 2>&1 &
  else zenity --error --text="Professore Digitale non risulta installato." 2>/dev/null; fi
}
about() {
  zenity --info --title="Informazioni su FeniceOS" --width=520 --no-wrap --text=\
"<b>FeniceOS</b> - un progetto di Danilo D'Auria
Distribuzione Linux per l'inclusione digitale e il riuso dell'hardware.

Basata su Debian 12. Desktop MATE.
Tema WhiteSur (MIT) e icone WhiteSur (GPL-3.0) di vinceliuice.
Dock Plank (GPL-3.0). Font Inter (OFL-1.1).
Suono di avvio e sfondo: originali, licenza MIT.
Professore Digitale: codice MIT, contenuti CC BY-NC-SA 4.0.

FeniceOS non usa marchi, loghi, suoni o icone di Apple." 2>/dev/null
}

while true; do
  if [ -e "$MUTE" ]; then SL="Attiva il suono di avvio"; else SL="Disattiva il suono di avvio"; fi
  choice="$(zenity --list --title="$APP" --width=760 --height=560 \
    --text="<span size='x-large'><b>Benvenuto in FeniceOS</b></span>"$'\n'"Tutto quello che ti serve, in un posto solo." \
    --column=id --column="Cosa vuoi fare?" --column="Descrizione" --hide-column=1 --print-column=1 \
    --ok-label="Apri" --cancel-label="Chiudi" \
    professore "Professore Digitale" "Lezioni, quiz ed esercizi passo dopo passo" \
    negozio    "Negozio delle app" "Installa nuovi programmi (Debian e Flathub)" \
    ottimizza  "Fenice Ottimizza" "Rendi il computer piu' veloce e scattante" \
    guida      "Guida di FeniceOS" "Istruzioni semplici per iniziare" \
    vademecum  "Vademecum del Professore" "Il manuale in PDF" \
    video      "Video e lezioni" "Guarda i video didattici" \
    quiz       "Il Grande Quiz dell'Informatica" "Gioca e metti alla prova le tue conoscenze" \
    sito       "Sito del Professore Digitale" "Novita' e aggiornamenti (serve Internet)" \
    suono      "$SL" "Musica di apertura della scrivania" \
    info       "Informazioni e licenze" "Chi ha fatto FeniceOS" 2>/dev/null)" || break
  case "$choice" in
    professore) launch_pd ;;
    negozio)    fenice-store >/dev/null 2>&1 & ;;
    ottimizza)  fenice-ottimizza >/dev/null 2>&1 & ;;
    guida)      open_url "$SHARE/guida/index.html" ;;
    vademecum)
      if [ -f "$SHARE/guida/Vademecum_Professore_Digitale.pdf" ]; then open_url "$SHARE/guida/Vademecum_Professore_Digitale.pdf"
      else open_url "https://danilodauria.github.io/professore-digitale/Vademecum_Professore_Digitale.pdf"; fi ;;
    video)      fenice-video >/dev/null 2>&1 & ;;
    quiz)  open_url "https://danilodauria.github.io/grande-quiz/" ;;
    sito)  open_url "https://danilodauria.github.io/professore-digitale/" ;;
    suono) mkdir -p "$(dirname "$MUTE")"; if [ -e "$MUTE" ]; then rm -f "$MUTE"; else touch "$MUTE"; fi ;;
    info)  about ;;
  esac
done
__FENICE_EOF__

  # ---- voci di menu (categoria "FeniceOS" nel menu Applicazioni) ----
  embed "$INC/usr/share/desktop-directories/fenice.directory" 644 <<'__FENICE_EOF__'
[Desktop Entry]
Type=Directory
Name=FeniceOS
Name[it]=FeniceOS
Comment=Programmi, lezioni e strumenti di FeniceOS
Icon=feniceos
__FENICE_EOF__
  embed "$INC/etc/xdg/menus/applications-merged/fenice.menu" 644 <<'__FENICE_EOF__'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>FeniceOS</Name>
    <Directory>fenice.directory</Directory>
    <Include>
      <Category>X-FeniceOS</Category>
    </Include>
  </Menu>
</Menu>
__FENICE_EOF__
  mk_desktop() { # mk_desktop <file> <nome> <commento> <exec> <icona>
    embed "$INC/usr/share/applications/$1" 644 <<EOF
[Desktop Entry]
Type=Application
Name=$2
Comment=$3
Exec=$4
Icon=$5
Terminal=false
Categories=X-FeniceOS;
EOF
  }
  mk_desktop fenice-centro.desktop    "Centro FeniceOS"     "Programmi, guide, quiz e strumenti in un posto solo" "fenice-centro" "feniceos"
  mk_desktop fenice-ottimizza.desktop "Fenice Ottimizza"    "Rendi il computer piu' veloce"                       "fenice-ottimizza" "fenice-ottimizza"
  mk_desktop fenice-store.desktop     "Negozio delle app"   "Installa programmi da Debian e Flathub"              "fenice-store" "system-software-install"
  mk_desktop fenice-guida.desktop     "Guida di FeniceOS"   "Istruzioni semplici per iniziare"                   "xdg-open /usr/share/fenice/guida/index.html" "help-browser"
  mk_desktop fenice-quiz.desktop      "Il Grande Quiz dell'Informatica" "Gioca e impara" "xdg-open https://danilodauria.github.io/grande-quiz/" "applications-education"
  mk_desktop fenice-video.desktop     "Video e lezioni"     "Video didattici di FeniceOS"                         "fenice-video" "applications-multimedia"
  mkdir -p "$INC/usr/share/fenice/video"
  # Cartelle personali opzionali accanto allo script: ./fenice-extra/video/*  ./fenice-extra/guida/*
  local extra; extra="$(dirname "$(readlink -f "$0")")/fenice-extra"
  if [ -d "$extra/video" ]; then cp -r "$extra/video/." "$INC/usr/share/fenice/video/"; log "Aggiunti i tuoi video da $extra/video"; fi
  if [ -d "$extra/guida" ]; then mkdir -p "$INC/usr/share/fenice/guida"; cp -r "$extra/guida/." "$INC/usr/share/fenice/guida/"; fi
  # la cartella esiste sempre (con un LEGGIMI), cosi' non si trova mai "cartella inesistente"
  cat > "$INC/usr/share/fenice/video/LEGGIMI.txt" <<'EOF'
Cartella dei video di FeniceOS.

Per includere i tuoi video nella ISO: crea la cartella "fenice-extra/video" accanto allo
script build_feniceos.sh, copiaci i file (mp4, webm, mkv...) e rilancia la build.
Nel sistema gia' avviato puoi usare la tua cartella personale "Video".
EOF

  # ---- layout pannello MATE: barra sottile in alto (il dock sta in basso) ----
  embed "$INC/usr/share/mate-panel/layouts/fenice.layout" 644 <<'__FENICE_EOF__'
[Toplevel top]
expand=true
orientation=top
size=28

[Object menu-bar]
object-type=menu-bar
toplevel-id=top
position=0

[Object notification-area]
object-type=applet
applet-iid=NotificationAreaAppletFactory::NotificationArea
toplevel-id=top
pack-type=end
position=10

[Object clock]
object-type=applet
applet-iid=ClockAppletFactory::ClockApplet
toplevel-id=top
pack-type=end
position=0
__FENICE_EOF__

  # ---- icone originali del logo (disponibili a tutti i temi) ----
  embed "$INC/usr/share/icons/hicolor/scalable/apps/feniceos.svg" 644 <<'__FENICE_EOF__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <defs>
    <linearGradient id="fiamma" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#e8362a"/>
      <stop offset="0.55" stop-color="#ff8a1f"/>
      <stop offset="1" stop-color="#ffd24a"/>
    </linearGradient>
    <linearGradient id="notte" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#33388a"/>
      <stop offset="1" stop-color="#14183f"/>
    </linearGradient>
  </defs>
  <rect x="4" y="4" width="120" height="120" rx="28" fill="url(#notte)"/>
  <path d="M64 86 C46 84 30 72 20 46 C36 57 50 59 60 57 Z" fill="url(#fiamma)" opacity="0.92"/>
  <path d="M64 86 C82 84 98 72 108 46 C92 57 78 59 68 57 Z" fill="url(#fiamma)" opacity="0.92"/>
  <path d="M64 16 C68 34 85 44 85 69 C85 89 75 107 64 111 C53 107 43 89 43 69 C43 58 48 52 54 46 C54 58 60 63 64 63 C60 46 60 32 64 16 Z" fill="url(#fiamma)"/>
  <path d="M64 64 C70 74 74 82 72 93 C70 101 66 105 64 107 C62 105 58 101 56 93 C54 82 58 74 64 64 Z" fill="#fff3b0" opacity="0.92"/>
</svg>
__FENICE_EOF__
  embed "$INC/usr/share/icons/hicolor/scalable/apps/fenice-ottimizza.svg" 644 <<'__FENICE_EOF__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <defs>
    <linearGradient id="sfondo" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2fbfa5"/>
      <stop offset="1" stop-color="#16806f"/>
    </linearGradient>
  </defs>
  <rect x="4" y="4" width="120" height="120" rx="28" fill="url(#sfondo)"/>
  <path d="M30 88 A42 42 0 1 1 98 88" fill="none" stroke="#ffffff" stroke-width="9" stroke-linecap="round" opacity="0.92"/>
  <path d="M64 78 L88 50" stroke="#ffb02e" stroke-width="8" stroke-linecap="round"/>
  <circle cx="64" cy="78" r="9" fill="#ffffff"/>
  <circle cx="64" cy="78" r="4" fill="#16806f"/>
</svg>
__FENICE_EOF__
  mkdir -p "$INC/usr/share/pixmaps"
  cp "$INC/usr/share/icons/hicolor/scalable/apps/feniceos.svg" "$INC/usr/share/pixmaps/feniceos.svg"

  # ---- guida offline ----
  embed "$INC/usr/share/fenice/guida/index.html" 644 <<'__FENICE_EOF__'
<!doctype html>
<html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Guida di FeniceOS</title>
<style>
 body{font-family:Inter,system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#1d1d2b;background:#fffaf4}
 h1{color:#c2410c} h2{color:#33388a;margin-top:2rem} code{background:#ffe9d6;padding:.1rem .35rem;border-radius:.3rem}
 .box{background:#fff;border:1px solid #f2d3b8;border-radius:.8rem;padding:1rem 1.2rem;margin:1rem 0}
</style></head><body>
<h1>Benvenuto in FeniceOS</h1>
<p>FeniceOS e' un sistema semplice, veloce e gratuito, pensato per dare nuova vita ai computer e per insegnare l'informatica a tutti.</p>
<h2>Primi passi</h2>
<div class="box"><ol>
<li>In basso trovi il <b>dock</b>: clicca sulle icone per aprire i programmi.</li>
<li>In alto a sinistra c'e' il menu <b>Applicazioni</b>: dentro trovi la cartella <b>FeniceOS</b>.</li>
<li>Il <b>Centro FeniceOS</b> (la fenice nel dock) raccoglie tutto: lezioni, guide, quiz, video.</li>
<li>Per imparare passo dopo passo apri il <b>Professore Digitale</b>.</li>
</ol></div>
<h2>Installare nuovi programmi</h2>
<p>Apri il <b>Negozio delle app</b>: puoi scegliere tra i programmi Debian e quelli di Flathub.</p>
<h2>Ufficio, posta e internet</h2>
<p><b>LibreOffice</b> (scrittura, fogli di calcolo, presentazioni) e' gia' in italiano, nel menu <i>Ufficio</i>. Per la posta c'e' <b>Thunderbird</b> (completo, il piu' semplice per Gmail e Outlook) e <b>Claws Mail</b> (molto leggero, per i computer piu' vecchi). Per navigare: <b>Firefox</b> (predefinito) e <b>Falkon</b>.</p>
<h2>Il computer e' lento?</h2>
<p>Apri <b>Fenice Ottimizza</b>, lascia spuntate le voci consigliate e premi <b>Applica</b>. Sui PC molto vecchi prova anche la <i>Modalita' leggera</i>.</p>
<h2>La musica di apertura</h2>
<p>Si puo' spegnere o riaccendere dal Centro FeniceOS, voce "suono di avvio".</p>
<h2>Importante: questa e' una sessione "live"</h2>
<p>Quello che salvi sulla chiavetta USB (cartelle dei documenti nella chiavetta o in un altro disco) resta; le impostazioni fatte durante la sessione live si perdono allo spegnimento, salvo diversa configurazione.</p>
<h2>Licenze e crediti</h2>
<p>FeniceOS: ideato e sviluppato da Danilo D'Auria. Basato su Debian 12 e MATE.<br>
Tema WhiteSur (MIT) e icone WhiteSur (GPL-3.0) di vinceliuice &middot; Dock Plank (GPL-3.0) &middot; Font Inter (OFL-1.1).<br>
Suono di avvio e sfondo: originali, licenza MIT. Professore Digitale: codice MIT, contenuti CC BY-NC-SA 4.0.<br>
FeniceOS non usa marchi, loghi, suoni o icone di Apple o di altre aziende.</p>
</body></html>
__FENICE_EOF__

  # ---- licenza dei file originali FeniceOS ----
  embed "$INC/usr/share/fenice/LICENSE-FENICE.txt" 644 <<'__FENICE_EOF__'
MIT License

Copyright (c) 2026 Danilo D'Auria - FeniceOS

Si applica a: suono di avvio "Alba della Fenice", sfondo "Alba", logo e icone
FeniceOS, script fenice-* e file di configurazione generati dal Master Build Script.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Componenti di terzi inclusi (licenze proprie): WhiteSur GTK theme (MIT),
WhiteSur icon theme (GPL-3.0), Plank (GPL-3.0), font Inter (OFL-1.1),
LibreOffice (MPL-2.0), Thunderbird (MPL-2.0), Claws Mail (GPL-3.0+), Falkon (GPL-3.0+),
Debian e relativi pacchetti (licenze nei rispettivi pacchetti).
Professore Digitale: codice MIT, contenuti CC BY-NC-SA 4.0 (Danilo D'Auria).
__FENICE_EOF__

  # ---- HOOK 0100: pacchetti facoltativi ----
  embed "$HOOKS/0100-pacchetti-facoltativi.hook.chroot" 755 <<'__FENICE_EOF__'
#!/bin/bash
# Installa i pacchetti facoltativi uno per uno: se uno manca, si va avanti.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
while read -r p; do
  [ -z "$p" ] && continue
  if apt-get install -y "$p" >/dev/null 2>&1; then echo "[fenice] installato: $p"
  else echo "[fenice] saltato (non disponibile): $p"; fi
done < /usr/share/fenice/optional-packages.txt
exit 0
__FENICE_EOF__

  # ---- HOOK 0150: Professore Digitale (riparazione eventuale + prova del server) ----
  embed "$HOOKS/0150-professore-digitale.hook.chroot" 755 <<'__FENICE_EOF__'
#!/bin/bash
# Se serve applica la riparazione (pd_tablet.py mancante nel .deb 3.5.2) e prova il server.
SRV=/usr/share/professore-digitale/server
PATCH=/usr/share/fenice/patches/pd_tablet.py
if [ -f "$PATCH" ] && [ -d "$SRV" ] && [ ! -f "$SRV/pd_tablet.py" ]; then
  install -m 0644 "$PATCH" "$SRV/pd_tablet.py" && echo "[fenice] riparazione applicata: pd_tablet.py"
fi
if [ ! -f "$SRV/pd_server.py" ]; then
  echo "[fenice] ERRORE: Professore Digitale non risulta installato"; exit 1
fi
if python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import pd_server' "$SRV"; then
  echo "[fenice] Professore Digitale: server OK"
else
  echo "[fenice] ERRORE: il server del Professore Digitale non parte"; exit 1
fi
exit 0
__FENICE_EOF__

  # ---- HOOK 0200: tema macOS-like (WhiteSur) con ripiego automatico ----
  embed "$HOOKS/0200-tema-whitesur.hook.chroot" 755 <<'__FENICE_EOF__'
#!/bin/bash
export HOME=/root
mkdir -p /tmp/fenice-theme && cd /tmp/fenice-theme
TH=""; ICO=""

if git clone --depth 1 https://github.com/vinceliuice/WhiteSur-gtk-theme.git ws-gtk >/dev/null 2>&1; then
  ( cd ws-gtk && ./install.sh -d /usr/share/themes -c light -c dark -o normal < /dev/null ) \
    || echo "[fenice] installazione tema WhiteSur non riuscita"
fi
[ -d /usr/share/themes/WhiteSur-Light ] && TH="WhiteSur-Light"

if git clone --depth 1 https://github.com/vinceliuice/WhiteSur-icon-theme.git ws-ico >/dev/null 2>&1; then
  ( cd ws-ico && ./install.sh -d /usr/share/icons < /dev/null ) \
    || echo "[fenice] installazione icone WhiteSur non riuscita"
fi

if [ -d /usr/share/icons/WhiteSur ]; then
  # Tema "FeniceOS": eredita WhiteSur e sostituisce il tasto menu con il logo Fenice
  mkdir -p /usr/share/icons/FeniceOS/scalable/places
  cat > /usr/share/icons/FeniceOS/index.theme <<'EOF'
[Icon Theme]
Name=FeniceOS
Comment=Icone FeniceOS (base WhiteSur, GPL-3.0) con il logo Fenice
Inherits=WhiteSur,hicolor
Directories=scalable/places

[scalable/places]
Size=64
MinSize=8
MaxSize=512
Type=Scalable
Context=Places
EOF
  for n in start-here distributor-logo; do
    cp /usr/share/icons/hicolor/scalable/apps/feniceos.svg "/usr/share/icons/FeniceOS/scalable/places/$n.svg"
  done
  gtk-update-icon-cache -f /usr/share/icons/FeniceOS >/dev/null 2>&1 || true
  ICO="FeniceOS"
elif [ -d /usr/share/icons/Papirus ]; then
  ICO="Papirus"
fi

if [ -z "$TH" ] && [ -d /usr/share/themes/Arc ]; then TH="Arc"; fi

MARCO=""
if [ -n "$TH" ] && [ -d "/usr/share/themes/$TH/metacity-1" ]; then MARCO="$TH"; fi

FONT=""
fc-list : family 2>/dev/null | grep -qiE '(^|,)Inter(,|$)' && FONT="Inter 10"

mkdir -p /usr/share/fenice
cat > /usr/share/fenice/theme.chosen <<EOF
GTK_THEME="$TH"
ICON_THEME="$ICO"
MARCO_THEME="$MARCO"
FONT="$FONT"
EOF
echo "[fenice] tema scelto: GTK='$TH' icone='$ICO' finestre='$MARCO' font='$FONT'"
rm -rf /tmp/fenice-theme
exit 0
__FENICE_EOF__

  # ---- HOOK 0300: Flathub ----
  embed "$HOOKS/0300-flathub.hook.chroot" 755 <<'__FENICE_EOF__'
#!/bin/bash
flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
  && echo "[fenice] Flathub aggiunto" \
  || echo "[fenice] Flathub non aggiunto ora: verra' aggiunto al primo uso del Negozio"
exit 0
__FENICE_EOF__

  # ---- HOOK 0400: impostazioni finali (schema predefiniti, menu, prompt) ----
  embed "$HOOKS/0400-impostazioni-finali.hook.chroot" 755 <<'__FENICE_EOF__'
#!/bin/bash
. /usr/share/fenice/build.conf
. /usr/share/fenice/theme.chosen 2>/dev/null

# Valori predefiniti di MATE per ogni nuovo utente (anche l'utente "live")
{
  if [ -n "$GTK_THEME$ICON_THEME$FONT" ]; then
    echo "[org.mate.interface]"
    [ -n "$GTK_THEME" ]  && echo "gtk-theme='$GTK_THEME'"
    [ -n "$ICON_THEME" ] && echo "icon-theme='$ICON_THEME'"
    [ -n "$FONT" ] && { echo "font-name='$FONT'"; echo "document-font-name='$FONT'"; }
    echo
  fi
  echo "[org.mate.Marco.general]"
  [ -n "$MARCO_THEME" ] && echo "theme='$MARCO_THEME'"
  echo "compositing-manager=true"
  echo "button-layout='close,minimize,maximize:'"
  echo
  echo "[org.mate.background]"
  echo "picture-filename='/usr/share/backgrounds/fenice/fenice-alba.png'"
  echo "picture-options='zoom'"
  echo
  echo "[org.mate.panel]"
  echo "default-layout='$PANEL_LAYOUT'"
} > /usr/share/glib-2.0/schemas/90_fenice.gschema.override
glib-compile-schemas /usr/share/glib-2.0/schemas || echo "[fenice] attenzione: compilazione schemi"

# Schermata di accesso
mkdir -p /etc/lightdm
{
  echo "[greeter]"
  echo "background=/usr/share/backgrounds/fenice/fenice-alba.png"
  [ -n "$GTK_THEME" ]  && echo "theme-name=$GTK_THEME"
  [ -n "$ICON_THEME" ] && echo "icon-theme-name=$ICON_THEME"
  [ -n "$FONT" ] && echo "font-name=$FONT"
  echo "indicators=~host;~spacer;~clock;~spacer;~session;~a11y;~power"
} > /etc/lightdm/lightdm-gtk-greeter.conf

# Professore Digitale dentro la cartella FeniceOS del menu
for f in $(grep -l -i 'professore' /usr/share/applications/*.desktop 2>/dev/null | grep -v '/fenice-'); do
  grep -q 'X-FeniceOS' "$f" || sed -i 's/^Categories=\(.*\)$/Categories=\1X-FeniceOS;/' "$f"
  echo "[fenice] voce di menu: $f"
done

# Prompt del terminale
cat >> /etc/skel/.bashrc <<'EOF'

# FeniceOS
PS1='\[\e[1;35m\][FeniceOS]\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\]\$ '
EOF

# Voci tecniche che non servono a chi usa il computer (Picom e Plank sono motori del
# desktop che girano gia' da soli: cliccarli non fa nulla). Non vengono disinstallate, solo
# nascoste dal menu, con una copia in /usr/local/share che resiste agli aggiornamenti.
mkdir -p /usr/local/share/applications
hide_entry() {
  local b; b="$(basename "$1")"
  [ -f "/usr/share/applications/$b" ] || return 0
  sed -e '/^NoDisplay=/d' -e '0,/^\[Desktop Entry\]/s//[Desktop Entry]\nNoDisplay=true/' \
      "/usr/share/applications/$b" > "/usr/local/share/applications/$b"
  echo "[fenice] nascosta dal menu: $b"
}
for b in picom.desktop plank.desktop compton.desktop avahi-discover.desktop bssh.desktop bvnc.desktop; do
  hide_entry "$b"
done
for f in /usr/share/applications/*.desktop; do
  exe="$(grep -m1 '^Exec=' "$f" | sed 's/^Exec=//' | awk '{print $1}')"; exe="${exe##*/}"
  case "$exe" in picom|plank|compton) hide_entry "$f" ;; esac
done

# Programmi predefiniti: Firefox per il web, Thunderbird per la posta (Falkon e Claws restano disponibili)
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
text/html=firefox-esr.desktop
x-scheme-handler/http=firefox-esr.desktop
x-scheme-handler/https=firefox-esr.desktop
x-scheme-handler/mailto=thunderbird.desktop
EOF
update-alternatives --set x-www-browser /usr/bin/firefox-esr >/dev/null 2>&1 || true
update-alternatives --set gnome-www-browser /usr/bin/firefox-esr >/dev/null 2>&1 || true

gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
exit 0
__FENICE_EOF__

  # tolleranza: se si usa --tree-only controlla subito la sintassi degli script
  if [ "$TREE_ONLY" -eq 1 ]; then
    for f in "$INC"/usr/local/bin/fenice-* "$HOOKS"/*.hook.chroot; do bash -n "$f" && echo "sintassi OK: $(basename "$f")"; done
  fi
}

# ------------------------------ BUILD -----------------------------------------
run_build() {
  log "Compilazione di ${DISTRO_NAME} in corso (circa 30-90 minuti: scarica e comprime tutto)"
  mkdir -p "$WORK"
  inb bash -c "cd /build && lb build" 2>&1 | tee "$WORK/build.log"
  local iso
  iso="$(find "$TREE" -maxdepth 1 -name '*.iso' | head -n1)"
  [ -n "$iso" ] || die "Build terminata ma nessuna ISO trovata. Guarda $WORK/build.log"
  cp -f "$iso" "$WORK/$ISO_NAME"
  ( cd "$WORK" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256" )
  chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$WORK/$ISO_NAME" "$WORK/$ISO_NAME.sha256" "$WORK/build.log" 2>/dev/null || true
}

# ------------------------------ MAIN ------------------------------------------
trap 'cleanup_mounts' EXIT
log "=== ${DISTRO_NAME} ${FENICE_VERSION} - Master Build Script ==="
if [ "$TREE_ONLY" -eq 0 ]; then
  host_checks
  install_host_deps
  cleanup_mounts
else
  mkdir -p "$WORK"
fi
rm -rf "$TREE"; mkdir -p "$TREE" "$CACHE"
if [ "$TREE_ONLY" -eq 0 ]; then create_builder; preflight_packages; fi
gen_assets
if [ "$TREE_ONLY" -eq 0 ]; then fetch_professore; else warn "--tree-only: salto il download di Professore Digitale"; fi
lb_config
write_tree
if [ "$TREE_ONLY" -eq 1 ]; then
  log "Albero generato in: $TREE (nessuna build eseguita)"; exit 0
fi
run_build
cleanup_mounts
log "=== FENICEOS COMPLETATO ==="
echo "ISO:          $WORK/$ISO_NAME"
echo "Impronta:     $WORK/$ISO_NAME.sha256"
echo "Log completo: $WORK/build.log"
echo
echo "Prossimo passo: apri Rufus, scegli l'ISO, schema GPT (UEFI) o MBR (BIOS) e scrivi la chiavetta."
echo "Se il PC non parte da USB, disattiva Secure Boot nel BIOS/UEFI."
