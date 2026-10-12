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

# Exit-code handling for the build. The obvious forms all break:
#
#   docker build ... | tee -a "$LOG"
#     -> `pipefail` makes the pipeline fail (correct), but `set -e` then
#        aborts ON THIS LINE, silently: the log just stops mid-build with no
#        marker, and you cannot tell a failed build from a crashed script.
#
#   docker build ... | tee -a "$LOG" || true
#     -> takes the line out from under `set -e`, but `||` is a command LIST
#        and PIPESTATUS afterwards is reset to [0]: the failure is swallowed
#        and the script reports success. (Verified, not assumed.)
#
#   set +e; ... | tee; rc=${PIPESTATUS[0]}; set -e
#     -> works, but toggling errexit around one command is easy to get wrong.
#
#   `if ! pipeline` (used here)
#     -> keeps errexit intact, needs no PIPESTATUS, and reads as what it is:
#        "if the build pipeline did not succeed, report and stop".
if ! docker build \
  -f tools/build/docker/Dockerfile \
  -t "$TAG" \
  . 2>&1 | tee -a "$LOG"; then
  echo "!! docker build 失败，镜像未更新（详见 $LOG）" | tee -a "$LOG"
  exit 1
fi

echo "=== 构建结束 $(date '+%F %T') ===" | tee -a "$LOG"
docker images "$TAG" --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}  {{.CreatedSince}}' | tee -a "$LOG"
