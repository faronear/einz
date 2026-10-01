# Einz Server 镜像（multi-stage）
# 注意：better-sqlite3 为原生模块，用 Debian (slim) 基座以复用官方预编译二进制，避免 Alpine 编译问题。
#
# ── 依赖源（2026-10-01 老板定：**默认走官方源**）────────────────────────────────
# 与 `package-lock.json` 里的 resolved 保持一致：lock 写官方源，安装时也不替换它。
# 但保留三个可变点，因为大陆构建机跨境拉 GitHub / nodejs.org **会间歇性超时**
# （实测：prebuild 拉 GitHub Releases 超时 → 回退源码编译 → 拉 Node 头文件又超时），
# 网络差时可一次性切镜像救急，**不必改文件**：
#
#   sudo docker compose build \
#     --build-arg NPM_MIRROR=https://registry.npmmirror.com \
#     --build-arg NODE_MIRROR=https://npmmirror.com/mirrors/node \
#     --build-arg BETTER_SQLITE3_MIRROR=https://npmmirror.com/mirrors/better-sqlite3 \
#     server
#   sudo docker compose up -d server
#
# 变量名是 prebuild-install / node-gyp 写死的（`prebuild-install/util.js` 的
# getEnvPrefix = `npm_config_<pkgname>_binary_host[_mirror]`），别改名。
# BETTER_SQLITE3_MIRROR 默认**留空**：空值会被 prebuild-install 当"没设置"，
# 于是走它自己的内置默认（github-from-package），与不加这个 ENV 完全等价。
FROM node:22-slim AS build
WORKDIR /app
ARG NPM_MIRROR=https://registry.npmjs.org
ARG NODE_MIRROR=https://nodejs.org/download/release
ARG BETTER_SQLITE3_MIRROR
ENV npm_config_registry=${NPM_MIRROR} \
    npm_config_disturl=${NODE_MIRROR} \
    npm_config_better_sqlite3_binary_host_mirror=${BETTER_SQLITE3_MIRROR}
# 同 runtime 阶段：better-sqlite3 预编译拉不到时回退源码编译需要工具链
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
# 依赖源：同 build 阶段（这个阶段也要 npm ci，同样会去拉 better-sqlite3）
ARG NPM_MIRROR=https://registry.npmjs.org
ARG NODE_MIRROR=https://nodejs.org/download/release
ARG BETTER_SQLITE3_MIRROR
ENV npm_config_registry=${NPM_MIRROR} \
    npm_config_disturl=${NODE_MIRROR} \
    npm_config_better_sqlite3_binary_host_mirror=${BETTER_SQLITE3_MIRROR}
# better-sqlite3 预编译二进制托管在 GitHub（国内机器常拉不到）→ npm 回退源码编译，
# 需要 python3 + make + g++（node-gyp）。装上兜底，海外机器仍走预编译不受影响。
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/app.js"]
