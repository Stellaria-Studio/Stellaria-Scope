#!/usr/bin/env bash
set -euo pipefail

echo "== machine =="
sw_vers || true
sysctl -n hw.model || true
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
sysctl hw.physicalcpu hw.logicalcpu hw.memsize || true

echo

echo "== powermetrics samplers =="
powermetrics -h 2>&1 | sed -n '/samplers/,$p' | head -120 || true

echo

echo "== memory =="
vm_stat || true
sysctl vm.swapusage || true

echo

echo "== thermal public state via Swift =="
swift -e 'import Foundation; let s=ProcessInfo.processInfo.thermalState; print(s.rawValue)' || true
