# Einz Server 镜像（multi-stage）
# 注意：better-sqlite3 为原生模块，用 Debian (slim) 基座以复用官方预编译二进制，避免 Alpine 编译问题。
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/app.js"]
