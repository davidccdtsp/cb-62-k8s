FROM node:20-alpine AS builder
WORKDIR /app
COPY backend-nest/package*.json ./
RUN npm ci --ignore-scripts
COPY backend-nest/tsconfig.json .
COPY backend-nest/src ./src
RUN npx tsc

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY backend-nest/package*.json ./
RUN npm ci --omit=dev --ignore-scripts
EXPOSE 3000
CMD ["node", "-r", "./dist/tracing.js", "dist/main.js"]
