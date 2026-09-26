#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mochilog-transfer-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
swiftc -DTRANSFER_TESTING -o "$test_root/transfer-protocol-tests" \
  Sources/Collector.swift Sources/MacTransferL10n.swift \
  Sources/SupportDiagnostics.swift Sources/TransferServer.swift \
  Tests/TransferProtocolTests.swift
MOCHILOG_TRANSFER_TEST_ROOT="$test_root/data" \
  "$test_root/transfer-protocol-tests"
