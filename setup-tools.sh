#!/usr/bin/env bash
#
# Werkzeuginstallation fuer den Unterricht — wiederholbar, unbeaufsichtigt.
#
# Jeder Schritt prueft zuerst, ob das Werkzeug schon da ist. Der Lauf dauert
# beim ersten Mal ueber eine Viertelstunde und kann abbrechen (Netz, apt-Lock,
# abgebrochener Download). Ein zweiter Lauf setzt fort und beschaedigt nichts.
# Genau das heisst idempotent — derselbe Begriff begegnet euch bei Docker und
# Kubernetes wieder.
#
#   ./setup-tools.sh            alles installieren
#   ./setup-tools.sh --check    nur zeigen, was fehlt
#
# Ein fehlgeschlagener Schritt beendet den Lauf nicht. Er wird gemerkt, die
# uebrigen Schritte laufen weiter, und am Ende steht, was offen blieb. Der
# Rueckgabewert ist dann ungleich 0 — sonst waere "ist durchgelaufen" keine
# Aussage.
#
# Persoenliche Angaben (Name, E-Mail, SSH-Schluessel, Anmeldungen) richtet
# setup-identity.sh ein — einmalig und interaktiv. Dieses Script fasst sie nie
# an, deshalb darf es beliebig oft laufen.

set -uo pipefail

cd "$(dirname "$0")" || { echo "Verzeichnis des Scripts nicht erreichbar" >&2; exit 1; }
source ./versions.env || { echo "versions.env fehlt oder ist fehlerhaft" >&2; exit 1; }

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# --- Ausgabe ---------------------------------------------------------------
MISSING=()
MANUAL=()
FAILED=()

step()    { printf '\n== %s\n' "$*"; }
ok()      { printf '   [ok]      %s\n' "$*"; }
doing()   { printf '   [install] %s\n' "$*"; }
skipped() { printf '   [fehlt]   %s\n' "$*";   MISSING+=("$*"); }
manual()  { printf '   [manuell] %s\n' "$*";   MANUAL+=("$*"); }
broke()   { printf '   [FEHLER]  %s\n' "$*";   FAILED+=("$*"); }

have() { command -v "$1" >/dev/null 2>&1; }

# --- Eine Weiche, kein zweites Script --------------------------------------
case "$(uname -s)" in
  Linux)  PKG=apt  ;;
  Darwin) PKG=brew ;;
  *) echo "Nicht unterstuetztes System: $(uname -s)" >&2; exit 1 ;;
esac
printf 'System: %s (%s), Schuljahr %s\n' "$(uname -s)" "$PKG" "$SCHULJAHR"

# UBUNTU_RELEASE ist die Version, gegen die geprueft wurde. Eine andere ist
# kein Fehler — aber wenn spaeter ein Paketname nicht passt, steht hier warum.
if [[ "$PKG" == "apt" && -r /etc/os-release ]]; then
  running_release="$(. /etc/os-release && printf '%s' "${VERSION_ID:-unbekannt}")"
  if [[ "$running_release" != "$UBUNTU_RELEASE" ]]; then
    printf 'Hinweis: geprueft gegen Ubuntu %s, hier laeuft %s.\n' \
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
# unzip allein genuegt ihm nicht — das kostet sonst den ganzen Lauf.
step "Grundwerkzeuge"
ensure_command git      git         git
ensure_command curl     curl        curl
ensure_command unzip    unzip       unzip
ensure_command zip      zip         zip
ensure_command zsh      zsh         zsh
ensure_command gh       gh          gh

# --- Java-Stack ueber SDKMAN ----------------------------------------------
# Ein Mechanismus fuer JDK, Maven und Gradle, identisch auf beiden Systemen,
# Versionen pinbar, mehrere JDKs parallel. Das von Hand gesetzte JAVA_HOME —
# die haeufigste Fehlerquelle der bisherigen Anleitung — entfaellt.
step "Java-Stack (SDKMAN)"
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
if [[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
  ok "SDKMAN"
elif [[ "$CHECK_ONLY" -eq 1 ]]; then
  skipped "SDKMAN"
else
  doing "SDKMAN"
  # Die eine Ausnahme von "kein fremdes Script ungelesen ausfuehren": SDKMAN
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
  # ab. Deshalb laeuft der ganze Abschnitt hier ohne -u, nicht nur das source.
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
      sudo usermod -aG docker "$USER" || broke "Benutzer zur Gruppe docker hinzufuegen"
      printf '   Hinweis: einmal ab- und wieder anmelden, damit die Gruppe greift.\n'
    else
      broke "docker (Pakete docker.io, docker-compose-v2)"
    fi
  else
    if brew install --cask docker; then
      printf '   Hinweis: Docker Desktop einmal starten, damit der Dienst laeuft.\n'
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
  # Auf Linux gibt es keinen Paketweg. Das ist ein Handgriff und wird als
  # solcher gemeldet — nicht als [install]: sonst behauptet jeder weitere Lauf
  # eine Installation, die nie stattfindet, und "beim zweiten Lauf steht
  # ueberall [ok]" waere falsch.
  if [[ -x "$HOME/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox" ]]; then
    ok "JetBrains Toolbox"
  else
    manual "JetBrains Toolbox — von https://www.jetbrains.com/toolbox-app/ laden, nach ~/.local/share/JetBrains/Toolbox entpacken"
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
    printf '   In ~/.zshrc ergaenzen: source %s/powerlevel10k.zsh-theme\n' "$P10K_DIR"
  else
    broke "powerlevel10k klonen"
  fi
fi

# --- asciidoctor laeuft im Container, nicht lokal --------------------------
step "asciidoctor"
ok "laeuft containerisiert (siehe curriculum-syp3/local-convert.sh) — Docker genuegt"

# --- Bilanz ----------------------------------------------------------------
step "Bilanz"

if [[ ${#MANUAL[@]} -gt 0 ]]; then
  for entry in "${MANUAL[@]}"; do
    printf 'Handgriff offen: %s\n' "$entry"
  done
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    printf 'Nichts fehlt.\n'
    exit 0
  fi
  printf '%d Werkzeuge fehlen. Ohne --check werden sie installiert.\n' "${#MISSING[@]}"
  exit 1
fi

if [[ ${#FAILED[@]} -eq 0 ]]; then
  printf 'Zustand hergestellt. Persoenliche Einrichtung: ./setup-identity.sh\n'
  exit 0
fi

printf '%d Schritte sind fehlgeschlagen:\n' "${#FAILED[@]}"
for entry in "${FAILED[@]}"; do
  printf '  - %s\n' "$entry"
done
printf '\nDas Script nochmals starten — was schon steht, wird uebersprungen.\n'
exit 1
