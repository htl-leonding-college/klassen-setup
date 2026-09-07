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
# Persoenliche Angaben (Name, E-Mail, SSH-Schluessel, Anmeldungen) richtet
# setup-identity.sh ein — einmalig und interaktiv. Dieses Script fasst sie nie
# an, deshalb darf es beliebig oft laufen.

set -euo pipefail

cd "$(dirname "$0")"
source ./versions.env

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# --- Ausgabe ---------------------------------------------------------------
step()    { printf '\n== %s\n' "$*"; }
ok()      { printf '   [ok]      %s\n' "$*"; }
doing()   { printf '   [install] %s\n' "$*"; }
skipped() { printf '   [fehlt]   %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- Eine Weiche, kein zweites Script --------------------------------------
case "$(uname -s)" in
  Linux)  PKG=apt  ;;
  Darwin) PKG=brew ;;
  *) echo "Nicht unterstuetztes System: $(uname -s)" >&2; exit 1 ;;
esac
printf 'System: %s (%s), Schuljahr %s\n' "$(uname -s)" "$PKG" "$SCHULJAHR"

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
  pkg_install "$apt_name" "$brew_name"
}

# --- Paketquellen ----------------------------------------------------------
step "Paketquellen"
if [[ "$CHECK_ONLY" -eq 0 ]]; then
  if [[ "$PKG" == "apt" ]]; then
    sudo apt-get update -qq
  else
    have brew || {
      echo "Homebrew fehlt. Installationsanleitung: https://brew.sh" >&2
      exit 1
    }
    brew update --quiet
  fi
fi

# --- Grundwerkzeuge --------------------------------------------------------
step "Grundwerkzeuge"
ensure_command git      git         git
ensure_command curl     curl        curl
ensure_command unzip    unzip       unzip
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
  curl -fsSL "https://get.sdkman.io?rcupdate=false" -o /tmp/sdkman-install.sh
  bash /tmp/sdkman-install.sh
fi

sdk_install() {
  local candidate="$1" version="$2"
  if [[ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then skipped "$candidate $version"; return; fi
  set +u; source "$SDKMAN_DIR/bin/sdkman-init.sh"; set -u
  if [[ -d "$SDKMAN_DIR/candidates/$candidate/$version" ]]; then
    ok "$candidate $version"
    return
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then skipped "$candidate $version"; return; fi
  doing "$candidate $version"
  sdk install "$candidate" "$version" </dev/null
  sdk default "$candidate" "$version" </dev/null
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
    sudo apt-get install -y docker.io docker-compose-v2
    sudo usermod -aG docker "$USER"
    printf '   Hinweis: einmal ab- und wieder anmelden, damit die Gruppe greift.\n'
  else
    brew install --cask docker
    printf '   Hinweis: Docker Desktop einmal starten, damit der Dienst laeuft.\n'
  fi
fi

install_binary() {
  # install_binary <befehl> <url>
  local command_name="$1" url="$2"
  if have "$command_name"; then ok "$command_name"; return; fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then skipped "$command_name"; return; fi
  doing "$command_name"
  local tmp="/tmp/$command_name"
  curl -fsSL "$url" -o "$tmp"
  sudo install -m 0755 "$tmp" "/usr/local/bin/$command_name"
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
    brew install --cask jetbrains-toolbox
  fi
else
  if [[ -x "$HOME/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox" ]]; then
    ok "JetBrains Toolbox"
  elif [[ "$CHECK_ONLY" -eq 1 ]]; then
    skipped "JetBrains Toolbox"
  else
    doing "JetBrains Toolbox"
    printf '   Herunterladen von https://www.jetbrains.com/toolbox-app/ und entpacken.\n'
    printf '   Bewusst kein automatischer Download: die Datei ist versionsgebunden.\n'
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
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
  printf '   In ~/.zshrc ergaenzen: source %s/powerlevel10k.zsh-theme\n' "$P10K_DIR"
fi

# --- asciidoctor laeuft im Container, nicht lokal --------------------------
step "asciidoctor"
ok "laeuft containerisiert (siehe curriculum-syp3/local-convert.sh) — Docker genuegt"

step "Fertig"
printf 'Zustand hergestellt. Persoenliche Einrichtung: ./setup-identity.sh\n'
