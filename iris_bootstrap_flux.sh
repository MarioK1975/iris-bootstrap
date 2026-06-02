#!/usr/bin/env bash
#
# iris_bootstrap.sh — reproduzierbarer ComfyUI-Stack für RunPod (Projekt Iris)
#
# Was:    Baut den schlanken Juggernaut-Photo-Stack auf einem frischen Pod.
#         venv + PyTorch (cu124) + ComfyUI 0.22.0 + Custom Nodes + Modelle.
# Wofür:  Flüchtiger, regions-agnostischer Bootstrap (Modell A, Container disk).
# Aufruf: bash iris_bootstrap.sh   (auf dem frisch deployten Pod)
#
# Stack-Disziplin: nur Ada / Ampere / Hopper — niemals Blackwell (sm_120).
# Sicherheit: ComfyUI bindet nur auf 127.0.0.1, Zugriff ausschliesslich per
#             SSH-Tunnel oder Tailscale-Mesh. Kein oeffentlicher HTTP-Proxy-Port.

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Konfiguration: Single Source of Truth
# ═══════════════════════════════════════════════════════════════════════════
COMFY_ROOT="/workspace/ComfyUI"
COMFY_PORT="8188"
COMFY_LISTEN="127.0.0.1"   # nur localhost — Zugriff per SSH-Tunnel, NICHT 0.0.0.0
COMFY_VERSION="0.22.0"

# venv als Geschwister von ComfyUI (NICHT darin — sonst scheitert der spaetere Klon)
VENV_DIR="/workspace/venv"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# PyTorch-Stack — hart gepinnt fuer Reproduzierbarkeit (cu124 = CUDA 12.4)
TORCH_VERSION="2.6.0"
TORCHVISION_VERSION="0.21.0"
TORCHAUDIO_VERSION="2.6.0"
TRITON_VERSION="3.2.0"
TORCH_INDEX_URL="https://download.pytorch.org/whl/cu124"

# Custom Nodes
NODES_DIR="$COMFY_ROOT/custom_nodes"
MANAGER_URL="https://github.com/ltdrdata/ComfyUI-Manager.git"
IMAGE_SAVER_URL="https://github.com/alexopus/ComfyUI-Image-Saver.git"
IMAGE_SAVER_REF="2ba0f2bc4ee5235a0f9299f415fb2fb6be78f9e9"   # gepinnt 2026-05-31, war 'master'

# Modell-URLs (immer /resolve/main/ — echte Binaerdatei, nicht der Blob-Viewer)
JUGGERNAUT_URL="https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors"
ULTRASHARP_URL="https://huggingface.co/lokCX/4x-Ultrasharp/resolve/main/4x-UltraSharp.pth"

# Modell-Zielpfade (voller Pfad inkl. Dateiname — ermoeglicht Umbenennen via wget -O)
JUGGERNAUT_DST="$COMFY_ROOT/models/checkpoints/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors"
ULTRASHARP_DST="$COMFY_ROOT/models/upscale_models/4x-UltraSharp.pth"

# Soll-Groessen in Bytes (Schwelle fuer file_ok — faengt Pointer-Stub & Abbruch)
JUGGERNAUT_BYTES="7110000000"   # ~7,11 GB
ULTRASHARP_BYTES="67000000"     # ~67 MB

# ─── Flux.1-dev (optionales Profil, via INSTALL_FLUX=true aktiviert) ─────────
# Vier Dateien, drei Zielverzeichnisse, zwei davon gated ($HF_TOKEN noetig).
# fp16 bewusst (nicht fp8): Iris hat VRAM-Headroom — Qualitaet vor Sparsamkeit.
# Soll-Groessen sind Schaetzwerte aus der Recherche; nach 1. realem Lauf per
# stat nachtragen (wie bei Juggernaut geschehen).
INSTALL_FLUX="${INSTALL_FLUX:-false}"  # nur exakt "true" zieht den Flux-Block; Default schlank

# 1) Hauptmodell (gated) -> models/diffusion_models/
FLUX_MAIN_URL="https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors"
FLUX_MAIN_DST="$COMFY_ROOT/models/diffusion_models/flux1-dev.safetensors"
FLUX_MAIN_BYTES="23800000000"   # ~23,8 GB

# 2) VAE (gated) -> models/vae/
FLUX_VAE_URL="https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors"
FLUX_VAE_DST="$COMFY_ROOT/models/vae/ae.safetensors"
FLUX_VAE_BYTES="335000000"      # ~335 MB

# 3) CLIP-L (offen) -> models/text_encoders/
FLUX_CLIPL_URL="https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"
FLUX_CLIPL_DST="$COMFY_ROOT/models/text_encoders/clip_l.safetensors"
FLUX_CLIPL_BYTES="246000000"    # ~246 MB

# 4) T5-XXL fp16 (offen) -> models/text_encoders/
FLUX_T5_URL="https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
FLUX_T5_DST="$COMFY_ROOT/models/text_encoders/t5xxl_fp16.safetensors"
FLUX_T5_BYTES="9790000000"      # ~9,79 GB

# ─── Tailscale (optionales Profil, via USE_TAILSCALE=true aktiviert) ─────────
# Loest den UI-Zugriff hinter dem ISP-Portfilter (Binz): bei restriktiver
# Firewall faellt Tailscale auf DERP ueber 443 zurueck — und 443 lebt.
# Userspace-Modus ist Pflicht, der Pod-Container hat kein /dev/net/tun.
# Eingehende Tailnet-Verbindungen reicht der netstack automatisch an
# localhost:gleicher-Port weiter -> ComfyUI bleibt auf 127.0.0.1, der Mac
# oeffnet http://iris:8188. Auth-Key ist ephemeral+reusable, kommt als
# RunPod-Secret — NIE hardcoden.
USE_TAILSCALE="${USE_TAILSCALE:-false}"   # nur exakt "true" zieht den Block
TS_HOSTNAME="iris"                        # MagicDNS-Name -> http://iris:8188
# TS_AUTHKEY wird inline via ${TS_AUTHKEY:-} gelesen (wie HF_TOKEN) — Secret,
# bewusst NICHT hier deklariert.

# ═══════════════════════════════════════════════════════════════════════════
# Farben: nur, wenn stdout wirklich ein Terminal ist
# ═══════════════════════════════════════════════════════════════════════════
if [ -t 1 ]; then
    C_OK=$'\033[32m'      # gruen
    C_SKIP=$'\033[33m'    # gelb
    C_ERR=$'\033[31m'     # rot
    C_RST=$'\033[0m'      # reset
else
    C_OK='' C_SKIP='' C_ERR='' C_RST=''
fi

# ═══════════════════════════════════════════════════════════════════════════
# Sprecher (machen die Meldungen)
# ═══════════════════════════════════════════════════════════════════════════
log()      { printf '%s[%s]%s %s\n'        "$C_OK"   "$(date +%H:%M:%S)" "$C_RST" "$*"; }
skip_msg() { printf '%s[%s] SKIP%s %s\n'   "$C_SKIP" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
die()      { printf '%s[%s] FEHLER%s %s\n' "$C_ERR"  "$(date +%H:%M:%S)" "$C_RST" "$*" >&2; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# Pruefer (schweigend, nur Exit-Code)
# ═══════════════════════════════════════════════════════════════════════════
dir_exists() { [ -d "$1" ] && [ -n "$(ls -A "$1")" ]; }

file_ok() {
    local datei="$1" soll="$2" ist
    [ -f "$datei" ] || return 1
    ist=$(stat -c %s "$datei")
    [ "$ist" -ge $(( soll * 95 / 100 )) ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: Tailscale (Userspace-Mesh — loest UI-Zugriff hinter ISP-Portfilter)
# ═══════════════════════════════════════════════════════════════════════════
setup_tailscale() {
    # Gate: nur bei ausdruecklicher Aktivierung (analog INSTALL_FLUX)
    if [ "$USE_TAILSCALE" != "true" ]; then
        skip_msg "USE_TAILSCALE nicht gesetzt — Tailscale-Block uebersprungen"
        return
    fi

    # Fail-Fast: Schalter an, aber kein Schluessel -> sauber abbrechen
    if [ -z "${TS_AUTHKEY:-}" ]; then
        die "USE_TAILSCALE=true, aber TS_AUTHKEY fehlt — Key als RunPod-Secret setzen"
    fi

    # Install (idempotent): vorhandenes Binary nicht neu ziehen. curl|sh ist
    # Tailscales offizielle Routine ueber HTTPS — auf einem fluechtigen Fremd-
    # Pod vertretbar (auf Apollon waere der Repo-Weg richtig).
    if command -v tailscale >/dev/null 2>&1; then
        skip_msg "tailscale bereits installiert — ueberspringe Install"
    else
        log "Installiere Tailscale (offizielles Install-Skript ueber 443)"
        curl -fsSL https://tailscale.com/install.sh | sh \
            || die "Tailscale-Installation fehlgeschlagen"
    fi

    # Daemon im Userspace starten (kein /dev/net/tun im Container).
    # Laeuft schon? Nicht doppelt starten (idempotent bei Re-Run im selben Pod).
    if pgrep -x tailscaled >/dev/null 2>&1; then
        skip_msg "tailscaled laeuft bereits — ueberspringe Daemon-Start"
    else
        log "Starte tailscaled (userspace-networking, Hintergrund)"
        tailscaled --tun=userspace-networking \
            >/var/log/tailscaled.log 2>&1 &
    fi

    # Poll-Loop gegen die Race Condition: der Daemon-Socket erscheint, sobald
    # tailscaled lauscht — login-unabhaengig, daher robuster als 'tailscale
    # status' (dessen Exit-Code vor dem Login zwischen Versionen schwankt).
    log "Warte auf tailscaled-Bereitschaft (max 15 s)"
    local sock="/var/run/tailscale/tailscaled.sock" ready=0 i
    for i in $(seq 1 30); do
        if [ -S "$sock" ]; then ready=1; break; fi
        sleep 0.5
    done
    [ "$ready" -eq 1 ] || die "tailscaled nicht bereit nach 15 s — /var/log/tailscaled.log pruefen"

    # Ans Tailnet anmelden. 'ephemeral' steckt im Key selbst, nicht hier.
    log "Melde Pod ans Tailnet an (Hostname: $TS_HOSTNAME)"
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" \
        || die "tailscale up fehlgeschlagen — Key gueltig / nicht abgelaufen?"

    # Verify: Tailnet-IP beweist, dass der Knoten steht
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null | head -n1) \
        || die "konnte Tailscale-IP nicht lesen"
    log "Tailscale aktiv — $TS_HOSTNAME @ $ts_ip"
    log "  UI nach ComfyUI-Start im Browser: http://$TS_HOSTNAME:$COMFY_PORT"
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: Python-venv anlegen
# ═══════════════════════════════════════════════════════════════════════════
setup_venv() {
    if [ -x "$VENV_PY" ]; then
        skip_msg "venv existiert bereits ($VENV_DIR) — ueberspringe Erstellung"
        return
    fi

    log "Lege venv an: $VENV_DIR"
    python3 -m venv "$VENV_DIR" || die "venv-Erstellung fehlgeschlagen — fehlt python3-venv?"

    log "Aktualisiere pip"
    "$VENV_PIP" install --upgrade pip || die "pip-Upgrade fehlgeschlagen"

    log "venv bereit ($("$VENV_PY" --version))"
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: PyTorch-Stack installieren (cu124, hart gepinnt)
# ═══════════════════════════════════════════════════════════════════════════
install_pytorch() {
    local soll="${TORCH_VERSION}+cu124"
    if "$VENV_PY" -c "import torch, sys; sys.exit(0 if torch.__version__ == '$soll' else 1)" 2>/dev/null; then
        skip_msg "PyTorch $soll bereits installiert — ueberspringe"
        return
    fi

    log "Installiere PyTorch-Stack ($soll) ueber cu124-Index"
    "$VENV_PIP" install \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}" \
        "triton==${TRITON_VERSION}" \
        --index-url "$TORCH_INDEX_URL" \
        || die "PyTorch-Installation fehlgeschlagen (Index/Version pruefen)"

    log "PyTorch-Stack installiert ($("$VENV_PY" -c 'import torch; print(torch.__version__)'))"
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: ComfyUI klonen (flach, direkt auf Versions-Tag)
# ═══════════════════════════════════════════════════════════════════════════
clone_comfyui() {
    if dir_exists "$COMFY_ROOT"; then
        skip_msg "ComfyUI bereits vorhanden ($COMFY_ROOT) — ueberspringe Klon"
    else
        log "Klone ComfyUI v$COMFY_VERSION (flach) nach $COMFY_ROOT"
        git clone --depth 1 --branch "v$COMFY_VERSION" \
            https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT" \
            || die "ComfyUI-Klon fehlgeschlagen (Tag v$COMFY_VERSION vorhanden?)"
    fi

    log "Installiere ComfyUI-requirements (~60 Pakete, kann dauern)"
    "$VENV_PIP" install -r "$COMFY_ROOT/requirements.txt" \
        || die "ComfyUI-requirements fehlgeschlagen"

    log "ComfyUI bereit"
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: Custom Nodes installieren
# ═══════════════════════════════════════════════════════════════════════════
install_nodes() {
    mkdir -p "$NODES_DIR"

    # lokaler Helfer: Dependencies einer Node installieren (beide Formate)
    _install_node_deps() {
        local node_dir="$1"
        if [ -f "$node_dir/requirements.txt" ]; then
            log "  requirements.txt gefunden — installiere"
            "$VENV_PIP" install -r "$node_dir/requirements.txt" \
                || die "Dependencies fehlgeschlagen: $node_dir/requirements.txt"
        elif [ -f "$node_dir/pyproject.toml" ]; then
            log "  pyproject.toml gefunden — installiere via pip install ."
            "$VENV_PIP" install "$node_dir" \
                || die "Dependencies fehlgeschlagen: $node_dir (pyproject.toml)"
        else
            log "  keine Dependency-Datei — ueberspringe"
        fi
    }

    # 1) ComfyUI-Manager — bewusst master (Sicherheits-Fix CVE-2025-67303 >= 3.38)
    local manager_dir="$NODES_DIR/ComfyUI-Manager"
    if dir_exists "$manager_dir"; then
        skip_msg "ComfyUI-Manager bereits vorhanden — ueberspringe Klon"
    else
        log "Klone ComfyUI-Manager (master, aktuell)"
        git clone --depth 1 "$MANAGER_URL" "$manager_dir" \
            || die "Manager-Klon fehlgeschlagen"
    fi
    _install_node_deps "$manager_dir"

    # 2) ComfyUI-Image-Saver — pin-faehig, vorerst master
    local saver_dir="$NODES_DIR/ComfyUI-Image-Saver"
    if dir_exists "$saver_dir"; then
        skip_msg "Image-Saver bereits vorhanden — ueberspringe Klon"
    else
        log "Klone Image-Saver (gepinnt: ${IMAGE_SAVER_REF:0:7})"
        git clone "$IMAGE_SAVER_URL" "$saver_dir" \
            || die "Image-Saver-Klon fehlgeschlagen"
        git -C "$saver_dir" checkout "$IMAGE_SAVER_REF" \
            || die "Image-Saver-Checkout fehlgeschlagen (Ref $IMAGE_SAVER_REF vorhanden?)"
    fi
    _install_node_deps "$saver_dir"

    log "Custom Nodes bereit"
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: Modelle herunterladen
# ═══════════════════════════════════════════════════════════════════════════
download_models() {
    # Herzstueck: ein Modell holen. Signatur:
    #   fetch_model <zielpfad-mit-name> <soll_bytes> <url> [mirror-url...]
    fetch_model() {
        local dst="$1" soll="$2"; shift 2   # Rest ($@) = eine oder mehr URLs
        local name; name=$(basename "$dst")

        if file_ok "$dst" "$soll"; then
            skip_msg "$name bereits vorhanden (Groesse ok) — ueberspringe Download"
            return
        fi

        mkdir -p "$(dirname "$dst")"

        # Token nur als Header, wenn gesetzt (set -u-sicher via :-)
        local auth=()
        if [ -n "${HF_TOKEN:-}" ]; then
            auth=(--header="Authorization: Bearer ${HF_TOKEN}")
            log "  HF-Token erkannt — Download mit Auth-Header"
        fi

        local url
        for url in "$@"; do
            log "Lade $name von: $url"
            if wget -c --progress=dot:giga "${auth[@]}" -O "$dst" "$url"; then
                file_ok "$dst" "$soll" && { log "  $name ok"; return; }
                log "  $name nach Download zu klein — naechster Spiegel (falls vorhanden)"
            else
                log "  Download fehlgeschlagen — naechster Spiegel (falls vorhanden)"
            fi
        done

        die "$name konnte aus keiner Quelle geladen werden"
    }

    log "Lade Modelle (~7 GB, kann je nach Region etwas dauern)"
    fetch_model "$JUGGERNAUT_DST" "$JUGGERNAUT_BYTES" "$JUGGERNAUT_URL"
    fetch_model "$ULTRASHARP_DST" "$ULTRASHARP_BYTES" "$ULTRASHARP_URL"

    # Flux nur, wenn ausdruecklich aktiviert (~34 GB zusaetzlich)
    if [ "$INSTALL_FLUX" = "true" ]; then
        if [ -z "${HF_TOKEN:-}" ]; then
            die "INSTALL_FLUX=true, aber HF_TOKEN fehlt — flux1-dev/ae sind gated"
        fi
        log "Flux-Profil aktiv — lade zusaetzlich ~34 GB (4 Dateien)"
        fetch_model "$FLUX_MAIN_DST"  "$FLUX_MAIN_BYTES"  "$FLUX_MAIN_URL"
        fetch_model "$FLUX_VAE_DST"   "$FLUX_VAE_BYTES"   "$FLUX_VAE_URL"
        fetch_model "$FLUX_CLIPL_DST" "$FLUX_CLIPL_BYTES" "$FLUX_CLIPL_URL"
        fetch_model "$FLUX_T5_DST"    "$FLUX_T5_BYTES"    "$FLUX_T5_URL"
    else
        skip_msg "INSTALL_FLUX nicht gesetzt — Flux-Block uebersprungen"
    fi

    log "Modelle bereit"
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage: Verifikation
# ═══════════════════════════════════════════════════════════════════════════
verify() {
    log "Pruefe CUDA-Sichtbarkeit"
    "$VENV_PY" -c "import torch; assert torch.cuda.is_available(), 'CUDA nicht verfuegbar'; print('  CUDA ok:', torch.cuda.get_device_name(0))" \
        || die "CUDA nicht sichtbar — falsche GPU-Architektur (Blackwell?) oder Treiberproblem"

    # ─── Flux-Dateibestand — nur wenn das Profil aktiv war ───────────────────
    # Letzte Quittung nach dem Download: liegen alle vier Dateien am richtigen
    # Platz in plausibler Groesse? file_ok schweigt (nur Exit-Code), der Aufrufer
    # sammelt die Luecken; am Ende EIN die mit der vollstaendigen Liste.
    if [ "$INSTALL_FLUX" = "true" ]; then
        log "Pruefe Flux-Dateibestand (vier Dateien, Soll-Groesse)"
        local missing=()
        file_ok "$FLUX_MAIN_DST"  "$FLUX_MAIN_BYTES"  || missing+=("$(basename "$FLUX_MAIN_DST")")
        file_ok "$FLUX_VAE_DST"   "$FLUX_VAE_BYTES"   || missing+=("$(basename "$FLUX_VAE_DST")")
        file_ok "$FLUX_CLIPL_DST" "$FLUX_CLIPL_BYTES" || missing+=("$(basename "$FLUX_CLIPL_DST")")
        file_ok "$FLUX_T5_DST"    "$FLUX_T5_BYTES"    || missing+=("$(basename "$FLUX_T5_DST")")

        if [ "${#missing[@]}" -gt 0 ]; then
            die "Flux-Dateien fehlen oder zu klein: ${missing[*]}"
        fi
        log "  Flux-Dateibestand vollstaendig (4/4)"
    fi

    log "Smoke-Test: ComfyUI startet (--quick-test-for-ci, ohne --cpu, laedt Nodes + GPU)"
    ( cd "$COMFY_ROOT" && "$VENV_PY" main.py --quick-test-for-ci ) \
        || die "ComfyUI-Smoke-Test fehlgeschlagen — Node- oder Importfehler"

    # Weicher Sicherheits-Hook: pip-audit meldet, blockiert aber nicht
    if "$VENV_PIP" show pip-audit >/dev/null 2>&1; then
        log "pip-audit laeuft (Funde sind Hinweise, kein Abbruch)"
        "$VENV_PY" -m pip_audit || log "  pip-audit meldete Funde — siehe oben, manuell bewerten"
    else
        skip_msg "pip-audit nicht installiert — ueberspringe Schwachstellen-Scan"
    fi

    log "Verifikation abgeschlossen"
}

# ═══════════════════════════════════════════════════════════════════════════
# main: Stages der Reihe nach
# ═══════════════════════════════════════════════════════════════════════════
main() {
    log "iris_bootstrap startet — Ziel: $COMFY_ROOT"

    setup_tailscale       # zuerst: Netzpfad steht, bevor der ~8-min-Bau laeuft
    setup_venv
    install_pytorch
    clone_comfyui
    install_nodes
    download_models
    verify

    log "Bootstrap fertig. Start:"
    log "  cd \"$COMFY_ROOT\" && \"$VENV_PY\" main.py --port $COMFY_PORT --listen $COMFY_LISTEN"
    log "  Danach von aussen per SSH-Tunnel:"
    log "  ssh -L ${COMFY_PORT}:127.0.0.1:${COMFY_PORT} <pod-ssh-zugang>"
    log "  ODER per Tailscale (USE_TAILSCALE=true): http://${TS_HOSTNAME}:${COMFY_PORT}"
}

main "$@"
