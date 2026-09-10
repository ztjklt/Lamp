FROM node:22-alpine AS build
WORKDIR /workspace
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS runtime
ENV NODE_ENV=production \
    PORT=8080 \
    LAMP_AGENT_HOST=0.0.0.0
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --from=build /workspace/dist ./dist
USER node
EXPOSE 8080
CMD ["node", "--experimental-loader=@opentelemetry/instrumentation/hook.mjs", "--import", "./dist/observability/instrumentation.js", "dist/api/server.js"]
