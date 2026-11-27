# Scaffolded by the lockhead.cloud platform — you did not write this. (Node.js / TypeScript)
FROM node:20-alpine AS build
WORKDIR /src
COPY app/package.json ./
RUN npm install
COPY app/tsconfig.json ./
COPY app/src ./src
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY app/package.json ./
RUN npm install --omit=dev
COPY --from=build /src/dist ./dist
EXPOSE 8080
ENV PORT=8080
ENTRYPOINT ["node", "dist/index.js"]
