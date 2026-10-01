# Einz Server 镜像（multi-stage）
# 注意：better-sqlite3 为原生模块，用 Debian (slim) 基座以复用官方预编译二进制，避免 Alpine 编译问题。
#
# ── 构建期网络（2026-10-01 实测补上）────────────────────────────────────────────
# 国内构建机上 `npm ci` 会以这种姿势失败（老板实测，构建耗时 152s 后挂掉）：
#   1) better-sqlite3 的 prebuild 要从 GitHub Releases 下（node-gyp 之前的那一步）→ 超时；
#   2) 于是回退源码编译，node-gyp 又要去 nodejs.org 下 Node 头文件 → 又超时。
# 下面三个镜像变量把这两步也挪到 npmmirror 上，任一步不通都还有备份路径：
#   · npm_config_registry                          —— tarball（package-lock.json 里本来就是这个源）
#   · npm_config_better_sqlite3_binary_host_mirror —— 预编译包，走镜像就不用编译了（省几分钟）
#   · npm_config_disturl                           —— 万不得已回退编译时，Node 头文件也走镜像
# 变量名是 prebuild-install / node-gyp 写死的（见 prebuild-install/util.js getEnvPrefix），别改。
# 海外构建想走官方源：docker build --build-arg NPM_MIRROR=https://registry.npmjs.org \
#   --build-arg NODE_MIRROR=https://nodejs.org/download/release \
#   --build-arg BETTER_SQLITE3_MIRROR=https://github.com/WiseLibs/better-sqlite3/releases/download
FROM node:22-slim AS build
WORKDIR /app
ARG NPM_MIRROR=https://registry.npmmirror.com
ARG NODE_MIRROR=https://npmmirror.com/mirrors/node
ARG BETTER_SQLITE3_MIRROR=https://npmmirror.com/mirrors/better-sqlite3
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
# 构建期网络：同 build 阶段（这个阶段也要 npm ci，同样会去拉 better-sqlite3）
ARG NPM_MIRROR=https://registry.npmmirror.com
ARG NODE_MIRROR=https://npmmirror.com/mirrors/node
ARG BETTER_SQLITE3_MIRROR=https://npmmirror.com/mirrors/better-sqlite3
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
