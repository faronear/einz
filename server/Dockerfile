# Einz Server 镜像（multi-stage）
# 注意：better-sqlite3 为原生模块，用 Debian (slim) 基座以复用官方预编译二进制，避免 Alpine 编译问题。
FROM node:22-slim AS build
WORKDIR /app
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
# better-sqlite3 预编译二进制托管在 GitHub（国内机器常拉不到）→ npm 回退源码编译，
# 需要 python3 + make + g++（node-gyp）。装上兜底，海外机器仍走预编译不受影响。
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/app.js"]
