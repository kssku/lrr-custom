#!/usr/bin/env bash
# 构建 kssku123/lrr-custom:v16
# 基于官方 tools/build/docker/Dockerfile，上下文为仓库根
set -euo pipefail

REPO="/root/GitHub/lrr-custom-push"
TAG="kssku123/lrr-custom:v16"
LOG="$REPO/log/build_v16.log"

cd "$REPO"
mkdir -p log

echo "=== 构建开始 $(date '+%F %T') ===" | tee "$LOG"
echo "分支: $(git branch --show-current)  HEAD: $(git rev-parse --short HEAD)" | tee -a "$LOG"

docker build \
  -f tools/build/docker/Dockerfile \
  -t "$TAG" \
  . 2>&1 | tee -a "$LOG"

echo "=== 构建结束 $(date '+%F %T') ===" | tee -a "$LOG"
docker images "$TAG" --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}  {{.CreatedSince}}' | tee -a "$LOG"
