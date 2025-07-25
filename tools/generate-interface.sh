#! /bin/bash
# generate-interface.sh generates the interface for the Payments contract

set -euo pipefail

# Check for required tools
for cmd in forge jq npm; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH." >&2
    exit 1
  fi
done

# Build the contracts
echo "Building contracts..."
forge build --force > /dev/null 2>&1

# Create a temporary directory and install abi-to-sol locally
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
npm init -y > /dev/null
npm install abi-to-sol > /dev/null

# Extract ABI using jq
cd -
jq '.abi' out/Payments.sol/Payments.json > "$TEMP_DIR/Payments.abi.json"

# Generate the interface using abi-to-sol
npx --prefix "$TEMP_DIR" abi-to-sol IPayments \
  --license MIT \
  --solidity-version "^0.8.27" \
  < "$TEMP_DIR/Payments.abi.json" > src/IPayments.sol

# Clean up temporary directory
rm -rf "$TEMP_DIR"

echo "Interface generated at src/IPayments.sol"

forge fmt src/IPayments.sol