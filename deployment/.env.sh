#!/usr/bin/env bash
# Einz 部署环境变量脚本（deployment/.env）
#
# 用法：bash deployment/.env.sh（脚本可执行，也可 ./.env.sh）
#   - 每次调用自动确保 deployment/.env 存在并包含 EINZ_DB_BACKUP_KEY；
#   - 密钥缺失或为占位值时，用 python3 生成随机 32 字节 base64 密钥并写入；
#   - 幂等：已存在有效非空密钥则不重复添加。
#
# 其他环境变量（如需）：直接在 deployment/.env 中手动添加/编辑即可。
# .env 已在 .gitignore 中，不入库、git pull 不覆盖。
set -euo pipefail
cd "$(dirname "$0")"   # 脚本所在目录（deployment/）

ENV_FILE=".env"
KEY_NAME="EINZ_DB_BACKUP_KEY"
PLACEHOLDER="粘贴"     # 旧模板占位值特征（含"粘贴"视为未配置）

# 1. 确保 .env 存在（不存在则创建）
touch "${ENV_FILE}"

# 2. 已存在"有效"密钥（非空且非占位）则跳过（幂等）
if grep -q "^${KEY_NAME}=.\+" "${ENV_FILE}" && ! grep -q "^${KEY_NAME}=.*${PLACEHOLDER}" "${ENV_FILE}"; then
  echo "skip: ${ENV_FILE} has valid ${KEY_NAME}"
  exit 0
fi

# 3. 生成随机 32 字节 base64 密钥；先删除该变量的旧行（占位/旧值），再追加唯一一行
NEW_KEY="$(python3 -c 'import os,base64;print(base64.b64encode(os.urandom(32)).decode())')"
sed -i.bak "/^${KEY_NAME}=/d" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
echo "${KEY_NAME}=${NEW_KEY}" >> "${ENV_FILE}"
echo "set: ${ENV_FILE} ${KEY_NAME} (regenerated)"
