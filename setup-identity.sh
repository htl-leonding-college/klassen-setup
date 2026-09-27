#!/usr/bin/env bash
#
# Persönliche Einrichtung — einmalig und interaktiv.
#
# Getrennt von setup-tools.sh, weil hier nichts wiederholbar ist: Name,
# E-Mail, SSH-Schlüssel und Anmeldungen gehören zu einer Person, nicht zu
# einem Gerätezustand. Vermischt entstünde ein Script, das man nicht
# wiederholen kann.
#
# Es liegen keine Zugangsdaten im Repository und es werden keine erzeugt, die
# hier landen könnten. Der private Schlüssel bleibt auf dem Gerät.

set -euo pipefail

ask() {
  # ask <frage> <vorgabe>
  local question="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$question [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$question: " answer
    printf '%s' "$answer"
  fi
}

printf '== git\n'
current_name="$(git config --global user.name  || true)"
current_mail="$(git config --global user.email || true)"

if [[ -n "$current_name" && -n "$current_mail" ]]; then
  printf '   bereits gesetzt: %s <%s>\n' "$current_name" "$current_mail"
  if [[ "$(ask 'ändern? (j/N)' 'N')" =~ ^[jJ]$ ]]; then
    current_name=""; current_mail=""
  fi
fi

if [[ -z "$current_name" || -z "$current_mail" ]]; then
  name="$(ask 'Vor- und Nachname')"
  mail="$(ask 'Schul-E-Mail-Adresse')"
  git config --global user.name  "$name"
  git config --global user.email "$mail"
  git config --global init.defaultBranch main
  git config --global pull.rebase false
  printf '   gesetzt: %s <%s>\n' "$name" "$mail"
fi

printf '\n== SSH-Schlüssel\n'
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
key="$HOME/.ssh/id_ed25519"
if [[ -f "$key" ]]; then
  printf '   vorhanden: %s (bleibt unangetastet)\n' "$key"
else
  ssh-keygen -t ed25519 -C "$(git config --global user.email)" -f "$key"
  printf '   erzeugt: %s\n' "$key"
fi

printf '\n   Öffentlicher Schlüssel — dieser Teil darf weitergegeben werden:\n\n'
cat "$key.pub"

printf '\n== GitHub\n'
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    printf '   bereits angemeldet.\n'
  else
    printf '   Anmeldung im Browser — den öffentlichen Schlüssel dabei hochladen.\n'
    gh auth login --hostname github.com --git-protocol ssh --web
  fi
else
  printf '   gh fehlt. Zuerst ./setup-tools.sh ausführen.\n'
fi

printf '\nFertig. setup-tools.sh darf ab jetzt beliebig oft laufen, ohne hiervon\netwas zu verändern.\n'
