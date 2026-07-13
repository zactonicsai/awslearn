#!/usr/bin/env bash
#
# install-session-manager-plugin.sh
# =================================
# Installs the AWS Session Manager plugin.
#
# WHY YOU NEED THIS
# -----------------
# The AWS CLI can *call* the SSM API on its own, but `aws ssm
# start-session` needs a separate helper binary to actually broker the
# WebSocket connection and wire it to your terminal. It is NOT bundled
# with the CLI. AWS ships it separately.
#
# Ansible's community.aws.aws_ssm connection plugin shells out to this
# exact binary too. Without it, every single Ansible task fails with a
# vague "plugin not found" error.
#
# Install this on:
#   - your LAPTOP    (so you can `aws ssm start-session` into the Command Node)
#   - the COMMAND NODE (so Ansible can reach NiFi and Kafka over SSM)
#
# Run:  bash install-session-manager-plugin.sh
#
set -euo pipefail

PLUGIN_PATH="/usr/local/sessionmanagerplugin/bin/session-manager-plugin"

if [[ -x "$PLUGIN_PATH" ]]; then
  echo "Already installed:"
  "$PLUGIN_PATH" --version
  exit 0
fi

echo "Installing the AWS Session Manager plugin..."

ARCH="$(uname -m)"
OS="$(uname -s)"

case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64)  DEB_ARCH="64bit" ;;
      aarch64) DEB_ARCH="arm64" ;;
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
    esac

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cd "$TMP"

    URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_${DEB_ARCH}/session-manager-plugin.deb"
    echo "  Downloading: $URL"
    curl -fsSL "$URL" -o session-manager-plugin.deb

    sudo dpkg -i session-manager-plugin.deb
    ;;

  Darwin)
    echo "  macOS detected. Use Homebrew:"
    echo "    brew install --cask session-manager-plugin"
    exit 0
    ;;

  *)
    echo "Unsupported OS: $OS" >&2
    echo "See: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
    exit 1
    ;;
esac

echo
echo "Verifying..."
"$PLUGIN_PATH" --version

echo
echo "Done. You can now run:"
echo "    aws ssm start-session --target <instance-id>"
echo
echo "...and Ansible's aws_ssm connection plugin will work."
