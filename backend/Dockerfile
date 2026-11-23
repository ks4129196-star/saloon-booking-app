# Salon Finder API: production image. Works on Render, Railway, Fly.io,
# Koyeb or any host that runs containers.
#
#   docker build -t salon-api backend
#   docker run -p 4000:4000 --env-file backend/.env -e NODE_ENV=production salon-api
#
# On start it applies any new database migrations, then serves on $PORT.

FROM node:24-slim

# Prisma's migration engine needs OpenSSL.
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
# Dev dependencies are kept: the Prisma CLI runs migrations at start.
RUN npm ci --include=dev --no-audit --no-fund

COPY prisma.config.ts tsconfig.json ./
COPY prisma ./prisma
COPY src ./src
# Generating the Prisma client only needs a placeholder database address.
RUN DATABASE_URL=postgresql://build:build@localhost:5432/build npm run build

ENV NODE_ENV=production
ENV PORT=4000
EXPOSE 4000

# Run as the unprivileged "node" user.
RUN chown -R node:node /app
USER node

CMD ["sh", "-c", "npx prisma migrate deploy && node dist/server.js"]
