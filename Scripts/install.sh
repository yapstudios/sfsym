#!/bin/bash
# Build sfsym and install it to ~/.local/bin so `sfsym` works from any shell.
set -euo pipefail

INSTALL_BIN="${HOME}/.local/bin"

echo "Building sfsym (release)..."
swift build -c release 2>&1 | tail -1

mkdir -p "${INSTALL_BIN}"
cp -f .build/release/sfsym "${INSTALL_BIN}/sfsym"

echo ""
echo "Installed:"
echo "  ${INSTALL_BIN}/sfsym"
"${INSTALL_BIN}/sfsym" --version

# Friendly PATH check.
case ":${PATH}:" in
  *":${INSTALL_BIN}:"*) ;;
  *)
    echo ""
    echo "Warning: ${INSTALL_BIN} is not on your PATH."
    echo "Add this to your shell profile (.zshrc / .bashrc):"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
