#!/bin/zsh
set -euo pipefail

focus_repo=${0:A:h:h}
cd "$focus_repo"

# `jai` is also available as a shell alias, but scripts need an executable.
focus_compiler=${commands[jai]:-${commands[jai-macos]:-}}
if [[ -z "$focus_compiler" ]]; then
  print -u2 'Jai compiler not found on PATH.'
  exit 1
fi
focus_build_marker=$(mktemp "${TMPDIR:-/tmp}/focus-build.XXXXXX")
trap 'rm -f "$focus_build_marker"' EXIT
"$focus_compiler" first.jai - release
[[ -x build_release/focus && build_release/focus -nt "$focus_build_marker" ]] || {
  print -u2 'The build did not produce a fresh release executable.'
  exit 1
}

mkdir -p "$HOME/bins"
# Replace by rename so a running editor can keep using its old executable.
install -m 755 build_release/focus "$HOME/bins/focus-bin.new"
mv -f "$HOME/bins/focus-bin.new" "$HOME/bins/focus-bin"

focus_themes="$HOME/Library/Application Support/dev.focus-editor/themes"
focus_backup="$focus_themes/backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$focus_themes"
cp fonts/liberation-mono.ttf "${focus_themes:h}/liberation-mono.ttf"
for focus_theme in handmade-hero jblowtorch jblow-nostalgia; do
  focus_target="$focus_themes/$focus_theme.focus-theme"
  if [[ -f "$focus_target" ]] && ! cmp -s "config/themes/$focus_theme.focus-theme" "$focus_target"; then
    mkdir -p "$focus_backup"
    cp -p "$focus_target" "$focus_backup/"
  fi
  cp "config/themes/$focus_theme.focus-theme" "$focus_target"
done

focus_source="source ${(q)focus_repo}/config/focus.zsh"
if ! /usr/bin/grep -Fxq "$focus_source" "$HOME/.zshrc"; then
  cp -p "$HOME/.zshrc" "$HOME/.zshrc.focus-backup.$(date +%Y%m%d-%H%M%S)-$$"
  printf '\n# Focus build/install command and detached launcher\n%s\n' "$focus_source" >> "$HOME/.zshrc"
fi
print 'Installed Focus and updated themes. Run: source ~/.zshrc'
