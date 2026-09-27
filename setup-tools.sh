#!/usr/bin/env bash
#
# Werkzeuginstallation für den Unterricht — wiederholbar, unbeaufsichtigt.
#
# Jeder Schritt prüft zuerst, ob das Werkzeug schon da ist. Der Lauf dauert
# beim ersten Mal über eine Viertelstunde und kann abbrechen (Netz, apt-Lock,
# abgebrochener Download). Ein zweiter Lauf setzt fort und beschädigt nichts.
# Genau das heißt idempotent — derselbe Begriff begegnet euch bei Docker und
# Kubernetes wieder.
#
#   ./setup-tools.sh            alles installieren
#   ./setup-tools.sh --check    nur zeigen, was fehlt
#
# Ein fehlgeschlagener Schritt beendet den Lauf nicht. Er wird gemerkt, die
# übrigen Schritte laufen weiter, und am Ende steht unter "Bilanz", was offen
# blieb. Der Rückgabewert ist dann ungleich 0 — sonst wäre "ist
# durchgelaufen" keine Aussage.
#
# Persönliche Angaben (Name, E-Mail, SSH-Schlüssel, Anmeldungen) richtet
# setup-identity.sh ein — einmalig und interaktiv. Dieses Script fasst sie nie
# an, deshalb darf es beliebig oft laufen.

set -uo pipefail

cd "$(dirname "$0")" || { echo "Verzeichnis des Scripts nicht erreichbar" >&2; exit 1; }
source ./versions.env || { echo "versions.env fehlt oder ist fehlerhaft" >&2; exit 1; }

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# --- Ausgabe ---------------------------------------------------------------
MISSING=()
FAILED=()

step()    { printf '\n== %s\n' "$*"; }
ok()      { printf '   [ok]      %s\n' "$*"; }
doing()   { printf '   [install] %s\n' "$*"; }
skipped() { printf '   [fehlt]   %s\n' "$*";   MISSING+=("$*"); }
broke()   { printf '   [FEHLER]  %s\n' "$*";   FAILED+=("$*"); }

have() { command -v "$1" >/dev/null 2>&1; }

# --- Eine Weiche, kein zweites Script --------------------------------------
case "$(uname -s)" in
  Linux)  PKG=apt  ;;
  Darwin) PKG=brew ;;
  *) echo "Nicht unterstütztes System: $(uname -s)" >&2; exit 1 ;;
esac
printf 'System: %s (%s), Schuljahr %s\n' "$(uname -s)" "$PKG" "$SCHULJAHR"

# UBUNTU_RELEASE ist die Version, gegen die geprüft wurde. Eine andere ist
# kein Fehler — aber wenn später ein Paketname nicht passt, steht hier warum.
if [[ "$PKG" == "apt" && -r /etc/os-release ]]; then
  running_release="$(. /etc/os-release && printf '%s' "${VERSION_ID:-unbekannt}")"
  if [[ "$running_release" != "$UBUNTU_RELEASE" ]]; then
    printf 'Hinweis: geprüft gegen Ubuntu %s, hier läuft %s.\n' \
      "$UBUNTU_RELEASE" "$running_release"
  fi
fi

pkg_install() {
  # pkg_install <apt-paket> <brew-paket>
  local apt_name="$1" brew_name="$2"
  if [[ "$PKG" == "apt" ]]; then
    sudo apt-get install -y "$apt_name"
  else
    brew install "$brew_name"
  fi
}

ensure_command() {
  # ensure_command <befehl> <apt-paket> <brew-paket>
  local command_name="$1" apt_name="$2" brew_name="$3"
  if have "$command_name"; then
    ok "$command_name"
    return
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then skipped "$command_name"; return; fi
  doing "$command_name"
  pkg_install "$apt_name" "$brew_name" \
    || broke "$command_name (Paket $apt_name / $brew_name)"
}

# --- Paketquellen ----------------------------------------------------------
step "Paketquellen"
if [[ "$CHECK_ONLY" -eq 0 ]]; then
  if [[ "$PKG" == "apt" ]]; then
    sudo apt-get update -qq || broke "apt-get update"
  else
    have brew || {
      echo "Homebrew fehlt. Installationsanleitung: https://brew.sh" >&2
      exit 1
    }
    brew update --quiet || broke "brew update"
  fi
fi

# --- Grundwerkzeuge --------------------------------------------------------
# zip steht hier, weil der SDKMAN-Installer es verlangt und ohne es abbricht.
# unzip allein genügt ihm nicht — das kostet sonst den ganzen Lauf.
step "Grundwerkzeuge"
ensure_command git      git         git
ensure_command curl     curl        curl
ensure_command unzip    unzip       unzip
ensure_command zip      zip         zip
ensure_command zsh      zsh         zsh
ensure_command gh       gh          gh

# --- Java-Stack über SDKMAN ----------------------------------------------
# Ein Mechanismus für JDK, Maven und Gradle, identisch auf beiden Systemen,
# Versionen pinbar, mehrere JDKs parallel. Das von Hand gesetzte JAVA_HOME —
# die häufigste Fehlerquelle der bisherigen Anleitung — entfällt.
step "Java-Stack (SDKMAN)"
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
if [[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
  ok "SDKMAN"
elif [[ "$CHECK_ONLY" -eq 1 ]]; then
  skipped "SDKMAN"
else
  doing "SDKMAN"
  # Die eine Ausnahme von "kein fremdes Script ungelesen ausführen": SDKMAN
  # bietet keinen Paketweg. Der Installer landet deshalb nicht in einer Pipe,
  # sondern als Datei, wird benannt und bleibt zum Nachlesen liegen.
  mkdir -p .cache
  sdkman_installer="$PWD/.cache/sdkman-install.sh"
  if curl -fsSL "https://get.sdkman.io?rcupdate=false" -o "$sdkman_installer"; then
    printf '   fremdes Script, nachlesbar unter %s (%s Bytes)\n' \
      "$sdkman_installer" "$(wc -c < "$sdkman_installer" | tr -d ' ')"
    bash "$sdkman_installer" || broke "SDKMAN-Installer"
  else
    broke "SDKMAN herunterladen"
  fi
fi

sdk_install() {
  # sdk_install <kandidat> <version>
  #
  # SDKMAN ist nicht "set -u"-fest: seine eigenen Funktionen greifen auf nicht
  # gesetzte Positionsparameter zu und brechen dann mit "$3: unbound variable"
  # ab. Deshalb läuft der ganze Abschnitt hier ohne -u, nicht nur das source.
  local candidate="$1" version="$2"
  if [[ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then skipped "$candidate $version"; return; fi

  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"

  if [[ -d "$SDKMAN_DIR/candidates/$candidate/$version" ]]; then
    set -u
    ok "$candidate $version"
    return
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    set -u
    skipped "$candidate $version"
    return
  fi

  doing "$candidate $version"
  if sdk install "$candidate" "$version" </dev/null; then
    sdk default "$candidate" "$version" </dev/null \
      || { set -u; broke "$candidate $version als Standard setzen"; return; }
  else
    set -u
    broke "$candidate $version — Kennung in SDKMAN vorhanden? 'sdk list $candidate'"
    return
  fi
  set -u
}

sdk_install java   "$JAVA_VERSION"
sdk_install maven  "$MAVEN_VERSION"
sdk_install gradle "$GRADLE_VERSION"

# --- Container -------------------------------------------------------------
step "Container"
if have docker; then
  ok "docker"
elif [[ "$CHECK_ONLY" -eq 1 ]]; then
  skipped "docker"
else
  doing "docker"
  if [[ "$PKG" == "apt" ]]; then
    if sudo apt-get install -y docker.io docker-compose-v2; then
      sudo usermod -aG docker "$USER" || broke "Benutzer zur Gruppe docker hinzufügen"
      printf '   Hinweis: einmal ab- und wieder anmelden, damit die Gruppe greift.\n'
    else
      broke "docker (Pakete docker.io, docker-compose-v2)"
    fi
  else
    if brew install --cask docker; then
      printf '   Hinweis: Docker Desktop einmal starten, damit der Dienst läuft.\n'
    else
      broke "docker (brew --cask docker)"
    fi
  fi
fi

install_binary() {
  # install_binary <befehl> <url>
  local command_name="$1" url="$2"
  if have "$command_name"; then ok "$command_name"; return; fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then skipped "$command_name"; return; fi
  doing "$command_name"
  local tmp="/tmp/$command_name"
  if ! curl -fsSL "$url" -o "$tmp"; then
    broke "$command_name herunterladen ($url)"
    return
  fi
  sudo install -m 0755 "$tmp" "/usr/local/bin/$command_name" \
    || broke "$command_name installieren"
  rm -f "$tmp"
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH=amd64 ;;
  arm64|aarch64) GOARCH=arm64 ;;
  *) echo "Unbekannte Architektur: $ARCH" >&2; exit 1 ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

install_binary kubectl \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${GOARCH}/kubectl"
install_binary minikube \
  "https://github.com/kubernetes/minikube/releases/download/v${MINIKUBE_VERSION}/minikube-${OS}-${GOARCH}"

# --- Entwicklungsumgebung --------------------------------------------------
step "Entwicklungsumgebung"
if [[ "$PKG" == "brew" ]]; then
  if brew list --cask jetbrains-toolbox >/dev/null 2>&1; then
    ok "JetBrains Toolbox"
  elif [[ "$CHECK_ONLY" -eq 1 ]]; then
    skipped "JetBrains Toolbox"
  else
    doing "JetBrains Toolbox"
    brew install --cask jetbrains-toolbox || broke "JetBrains Toolbox"
  fi
else
  # Auf Linux gibt es keinen Paketweg — also Tarball, wie bei kubectl und
  # minikube. Zwei Unterschiede zu allem anderen hier, beide gewollt:
  #
  #   * keine gepinnte Version. JetBrains veröffentlicht unter TBA immer nur
  #     den aktuellen Build und räumt alte weg; ein Pin in versions.env wäre
  #     eine Zusage, die JetBrains nicht einhält. Die Toolbox ist ohnehin nur
  #     der Installer der IDEs und aktualisiert sich nach dem ersten Start
  #     selbst — die Version altert also nur bis dahin.
  #   * dafür wird die Prüfsumme geprüft. Ohne Pin ist sie das einzige, was
  #     zwischen "geladen" und "das Richtige geladen" unterscheidet.
  TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox"
  if [[ -x "$TOOLBOX_DIR/bin/jetbrains-toolbox" ]]; then
    ok "JetBrains Toolbox"
  elif [[ "$CHECK_ONLY" -eq 1 ]]; then
    skipped "JetBrains Toolbox"
  else
    doing "JetBrains Toolbox"
    case "$GOARCH" in
      arm64) toolbox_platform=linuxARM64 ;;
      *)     toolbox_platform=linux      ;;
    esac
    toolbox_url="$(curl -sIL -o /dev/null -w '%{url_effective}' \
      "https://data.services.jetbrains.com/products/download?code=TBA&platform=${toolbox_platform}")"

    if [[ "$toolbox_url" != *.tar.gz ]]; then
      broke "JetBrains Toolbox — unerwartete Adresse: ${toolbox_url:-leer}"
    else
      toolbox_archive="/tmp/${toolbox_url##*/}"
      if ! curl -fsSL "$toolbox_url" -o "$toolbox_archive"; then
        broke "JetBrains Toolbox herunterladen ($toolbox_url)"
      elif ! curl -fsSL "$toolbox_url.sha256" -o "$toolbox_archive.sha256"; then
        broke "JetBrains Toolbox — Prüfsumme nicht erreichbar"
        rm -f "$toolbox_archive"
      elif ! (cd /tmp && sha256sum -c "$toolbox_archive.sha256" >/dev/null 2>&1); then
        broke "JetBrains Toolbox — Prüfsumme stimmt nicht, Datei verworfen"
        rm -f "$toolbox_archive" "$toolbox_archive.sha256"
      else
        printf '   Prüfsumme stimmt (%s)\n' "${toolbox_url##*/}"
        mkdir -p "$TOOLBOX_DIR"
        # --strip-components=1: das Archiv trägt die Version als oberstes
        # Verzeichnis, und die soll nicht im Zielpfad landen.
        if tar -xzf "$toolbox_archive" -C "$TOOLBOX_DIR" --strip-components=1; then
          printf '   Hinweis: einmal %s/bin/jetbrains-toolbox starten.\n' "$TOOLBOX_DIR"
        else
          broke "JetBrains Toolbox entpacken"
        fi
        rm -f "$toolbox_archive" "$toolbox_archive.sha256"
      fi
    fi
  fi
fi

# --- Shell -----------------------------------------------------------------
step "Shell"
P10K_DIR="${ZSH_CUSTOM:-$HOME/.local/share}/powerlevel10k"
if [[ -d "$P10K_DIR" ]]; then
  ok "powerlevel10k"
elif [[ "$CHECK_ONLY" -eq 1 ]]; then
  skipped "powerlevel10k"
else
  doing "powerlevel10k"
  if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"; then
    printf '   In ~/.zshrc ergänzen: source %s/powerlevel10k.zsh-theme\n' "$P10K_DIR"
  else
    broke "powerlevel10k klonen"
  fi
fi

# --- asciidoctor läuft im Container, nicht lokal --------------------------
step "asciidoctor"
ok "läuft containerisiert (siehe curriculum-syp3/local-convert.sh) — Docker genügt"

# --- Bilanz ----------------------------------------------------------------
step "Bilanz"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    printf 'Nichts fehlt.\n'
    exit 0
  fi
  printf '%d Werkzeuge fehlen. Ohne --check werden sie installiert.\n' "${#MISSING[@]}"
  exit 1
fi

if [[ ${#FAILED[@]} -eq 0 ]]; then
  printf 'Zustand hergestellt. Persönliche Einrichtung: ./setup-identity.sh\n'
  exit 0
fi

printf '%d Schritte sind fehlgeschlagen:\n' "${#FAILED[@]}"
for entry in "${FAILED[@]}"; do
  printf '  - %s\n' "$entry"
done
printf '\nDas Script nochmals starten — was schon steht, wird übersprungen.\n'
exit 1
