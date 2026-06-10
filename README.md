# Newspaper

Local-first personal news intake and generated RSS pipeline.

## Local Development

Run Postgres with Docker, then run Phoenix natively:

```sh
docker compose -f docker-compose.dev.yml up -d postgres
mix setup
mix phx.server
```

The dev database defaults to:

```sh
DATABASE_URL=ecto://postgres:postgres@localhost/newspaper_dev
```

Visit http://localhost:4000.

## Production

The first production target is the `news` host on the local network. The public
app URL is `http://news.home`, served through a host-networked nginx container
on the same machine. Phoenix still listens on port `4000` behind nginx.

Bootstrap the remote directory and environment once:

```sh
ssh news 'mkdir -p ~/docker/news'
rsync -az --exclude=/deps/ --exclude=/_build/ ./ news:~/docker/news/
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

The deploy helper syncs source to `news:~/docker/news`, preserves remote env
files, rebuilds/restarts the app container, and runs release migrations.

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

## V1 Surface

- Intake groups and input feed configuration
- Output feed configuration
- Manual and scheduled global fetch
- Eager raw item capture
- Intake-group dedupe
- Durable generated feed item snapshots
- GUID-based RSS output URLs at `/feeds/:feed_guid.xml`
