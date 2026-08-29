# Persistent Renewa inbox agent worker. A long-lived poller: it claims scan_jobs, runs the
# autonomous LangGraph funnel (triage -> agent -> propose), reconciles against the app DB, and
# writes candidates. There is NO HTTP surface -- this is a queue worker, not a server.
#
# TypeScript is executed directly via Node's type stripping (no build/compile step), matching how
# the worker runs locally (`node src/worker.ts`). node:24 has type stripping enabled by default.
FROM node:24-slim

WORKDIR /app

# Install production dependencies first for better layer caching. Uses the committed lockfile;
# devDependencies (typescript/@types) are not needed at runtime since we don't compile.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Application source + queue migrations (run as-is; no build output).
COPY src ./src
COPY migrations ./migrations

ENV NODE_ENV=production
# The autonomous two-tier funnel is the live path. Overridable via Fly [env] / `fly secrets`.
ENV AGENT_MODE=autonomous

# Polls scan_jobs forever. DATABASE_URL and DEEPSEEK_API_KEY are provided at runtime as Fly secrets.
CMD ["node", "src/worker.ts"]
