#!/usr/bin/env bash
# v16 部署：Dell 本地 save -> 传 NAS -> load -> compose up -d
# 用法: bash script/deploy_v16.sh
set -euo pipefail

IMG="kssku123/lrr-custom:v16"
TAR="/tmp/lrr-custom-v16.tar"
NAS_TAR="/vol1/1000/docker/lrr/lrr-custom-v16.tar"
NAS_COMPOSE_DIR="/vol1/1000/docker/lrr"

echo "=== 1/5 Dell 本地导出镜像 ==="
docker save -o "$TAR" "$IMG"
ls -lh "$TAR"
sha256sum "$TAR" | tee /tmp/lrr-custom-v16.tar.sha256

echo "=== 2/5 传输到 NAS ==="
scp "$TAR" "nas:$NAS_TAR"

# 校验和比对，确保传输完整
echo "=== 3/5 校验和比对 ==="
REMOTE_SUM=$(ssh nas "sha256sum $NAS_TAR | cut -d' ' -f1")
LOCAL_SUM=$(cut -d' ' -f1 /tmp/lrr-custom-v16.tar.sha256)
if [ "$REMOTE_SUM" != "$LOCAL_SUM" ]; then
  echo "!! 校验和不一致，中止部署"
  echo "local : $LOCAL_SUM"
  echo "remote: $REMOTE_SUM"
  exit 1
fi
echo "校验和一致: $LOCAL_SUM"

echo "=== 4/5 NAS 上 load 镜像 ==="
ssh nas "docker load -i $NAS_TAR && docker images kssku123/lrr-custom --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}'"

echo "=== 5/5 拉起 lrr-test 容器 ==="
ssh nas "cd $NAS_COMPOSE_DIR && docker compose up -d && docker compose ps"

echo "=== 完成 ==="
