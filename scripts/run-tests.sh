#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run CoreTests
