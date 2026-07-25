# Newspaper

Local-first personal news intake and generated RSS pipeline.

## Local Development

Set up Postgres and the Phoenix app from the repo root:

```sh
scripts/setup-dev.sh
scripts/server-dev.sh
```

The dev database defaults to:

```sh
DATABASE_URL=ecto://postgres:postgres@localhost/newspaper_dev
```

Visit http://localhost:4000.

Root-level helper scripts run Mix commands from the Phoenix app in
`newspaper/`:

```sh
scripts/test.sh
scripts/precommit.sh
```

## Production

The first production target is the `news` host on the local network. The public
app URL is `http://news.home`, served through a host-networked nginx container
on the same machine. Phoenix still listens on port `4000` behind nginx.

Bootstrap the remote git checkout and environment once after pushing this repo
to GitHub:

```sh
REPO_URL=git@github.com:ianwalther/news.git scripts/bootstrap-prod-git.sh
```

If `~/docker/news` already exists from a pre-git file-copy deploy, move it aside
and preserve its `.env.prod` with:

```sh
REPO_URL=git@github.com:ianwalther/news.git REPLACE_EXISTING=1 scripts/bootstrap-prod-git.sh
```

Then create or update the prod env file on the host:

```sh
ssh news 'cd ~/docker/news && cp .env.prod.example .env.prod'
# edit ~/docker/news/.env.prod on the host:
# - set SECRET_KEY_BASE
# - set POSTGRES_PASSWORD
# - set PHX_HOST=news.home and PHX_URL_PORT=80
# - keep DATABASE_URL's password in sync with POSTGRES_PASSWORD
```

Deploy from this checkout:

```sh
scripts/deploy-prod.sh
```

The deploy helper SSHes to `news`, updates `~/docker/news` from `origin/master`
with `git pull --ff-only`, builds the app image, runs database migrations in a
one-off container, and then replaces the app container.

Run idempotent production seeds separately when desired:

```sh
scripts/seed-prod.sh
```

The underlying production commands are:

```sh
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --build
docker compose --env-file .env.prod -f docker-compose.prod.yml exec app /app/bin/migrate
```

Later, production can point at a shared network Postgres instance by changing
`DATABASE_URL`.

## Current Surface

- Optional intake groups, independent input feeds, and output-feed configuration
- Manual and scheduled conditional feed collection with eager raw item capture
- URL and feed-stable-ID dedupe within grouped or independent intake boundaries
- Durable generated feed item snapshots and GUID-based RSS endpoints
- Site-scoped simple/headless extraction with escalation, pacing, and retry history
- Ollama-backed article title and summary digestion
- Live processing, article, failure, and operation visibility
