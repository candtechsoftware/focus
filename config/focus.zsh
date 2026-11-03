# Keep the installer tied to the checkout from which this file was sourced.
typeset -g FOCUS_SOURCE_DIR=${${(%):-%x}:A:h:h}

focus-install() {
  /bin/zsh "$FOCUS_SOURCE_DIR/scripts/focus-install.zsh" "$@"
}

focus() {
  if [[ ! -x "$HOME/bins/focus-bin" ]]; then
    print -u2 'Focus is not installed. Run focus-install first.'
    return 1
  fi
  nohup "$HOME/bins/focus-bin" "$@" </dev/null >/dev/null 2>&1 &!
}
