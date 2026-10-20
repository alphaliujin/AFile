#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/afile-merge-service-tests"

swiftc -parse-as-library -O \
  "${ROOT}/Alpha的文件同步工具/FileMergeService.swift" \
  "${ROOT}/Alpha的文件同步工具/FileComparisonModels.swift" \
  "${ROOT}/Alpha的文件同步工具/FileCompareViewModel.swift" \
  "${ROOT}/Tests/TestSupport.swift" \
  "${ROOT}/Tests/MergeServiceTests.swift" \
  -o "${OUT}"

"${OUT}" "$@"
