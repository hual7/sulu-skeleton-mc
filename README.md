# Sulu CMS 3 + MariaDB for Magic Containers

A [Sulu CMS 3](https://sulu.io/) app (based on the official [sulu/skeleton](https://github.com/sulu/skeleton) 3.0) with MariaDB, running on Apache, ready to deploy on [Bunny Magic Containers](https://bunny.net/magic-containers/).

## What's included

- `Dockerfile` - PHP 8.4 + Apache (mod_php) in a single container
- `docker/apache.conf` - Apache vhost serving `public/` with Symfony routing
- `docker/php.ini` - PHP tuning (memory limit, upload sizes for media)
- `docker/entrypoint.sh` - Warms the cache at runtime, waits for the database, runs `sulu:build prod` on an empty database, creates the admin user, then starts Apache — all idempotent, so every restart is safe
- `docker-compose.yml` - Local development setup with app and MariaDB
- `bunny.json` - Magic Containers app config with app and database containers
- `.github/workflows/deploy.yml` - GitHub Actions workflow to build, push to GitHub Container Registry, and deploy to Magic Containers

## Run locally

```bash
docker compose up --build
```

The first start takes a few minutes (cache warmup + database setup run automatically — no manual migrations needed).

- Website: [http://localhost:8000](http://localhost:8000)
- Admin: [http://localhost:8000/admin](http://localhost:8000/admin) — login `admin` / `admin`

## Deploy to Magic Containers

### 1. Fork and push

Fork this repository and push to the `main` branch. The GitHub Actions workflow will automatically build the Docker image and push it to `ghcr.io/<your-username>/<your-repo>` tagged with both `latest` and the commit SHA.

### 2. Make the package public

Go to your GitHub profile > **Packages** > select the package > **Package settings** > change visibility to **Public**.

### 3. Create an app on Magic Containers

1. Log in to the [bunny.net dashboard](https://dash.bunny.net) and navigate to **Magic Containers**.
2. Click **Create App**.
3. Add the **app** container:
   - **Registry**: GitHub Container Registry (`ghcr.io`)
   - **Image**: `ghcr.io/<your-username>/<your-repo>:latest`
   - Add an **Endpoint** on port `80`
   - Add a **Volume** mounted at `/data` (persists media originals, the search index and generated image formats)
   - Set the environment variables (see `bunny.json`): `APP_DATA_DIR=/data`, `APP_ENV`, `APP_SECRET`, `DATABASE_URL`, `TRUSTED_PROXIES`, `SULU_ADMIN_EMAIL`, `SULU_ADMIN_USER`, `SULU_ADMIN_PASSWORD`
4. Add the **db** container:
   - **Image**: `mariadb:10.11.14`
   - Set the environment variables (`MARIADB_DATABASE`, `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_ROOT_PASSWORD`)
   - Add a **Volume** mounted at `/var/lib/mysql`
5. Confirm and deploy.

### 4. Test it

Once deployed, you'll get a `*.bunny.run` URL:

```bash
curl https://mc-xxx.bunny.run
```

The Sulu admin is available at `https://mc-xxx.bunny.run/admin`.

## Fallback: single shared volume

The two dedicated volumes above are the recommended setup. If your Magic Containers plan limits you to one volume per app, share it between both containers instead — but each container must stay inside its own subdirectory (two processes writing to the volume root will corrupt each other):

1. Mount the shared volume at `/data` in **both** containers.
2. **app** container: set `APP_DATA_DIR=/data/app` (instead of `/data`) so the app data lands in its own subdirectory.
3. **db** container: set the startup command to `docker-entrypoint.sh mariadbd --datadir=/data/mysql` so MariaDB initializes and keeps its data in its own subdirectory.

MariaDB only initializes an empty data directory — once set up, deploys never touch it. The same applies to the Sulu setup: `sulu:build prod` and the admin user creation only run when the database is empty, never on later deploys or restarts.

## Continuous deployment

The workflow automatically deploys to Magic Containers on every push to `main`. Configure the following in your repository settings:

- **Variable** `APP_ID` - your Magic Containers app ID
- **Secret** `BUNNYNET_API_KEY` - your bunny.net API key

## Important notes for Magic Containers

- **`DATABASE_URL` must use `127.0.0.1`, not `localhost`** - Magic Containers share a localhost network between containers. However, PHP/PDO interprets `localhost` as a Unix socket connection, which fails. Always use `127.0.0.1` to force TCP.
- **Don't cache config at build time** - The `Dockerfile` does not warm the Symfony cache. The cache is built at container startup via the entrypoint script so it picks up runtime environment variables.
- **Only `var/storage`, `var/indexes` and `public/uploads` live on the volume** - The entrypoint symlinks media originals (`var/storage`, flysystem), the Loupe search index (`var/indexes`) and generated image formats (`public/uploads`) into `APP_DATA_DIR`. Without the volume, uploads and the search index are lost on every deploy.
- **The Symfony cache is container-local, not on the volume** - `APP_CACHE_DIR=/var/cache/sulu` (set in the `Dockerfile`) keeps the cache out of the persistent volume; it is rebuilt on every container start, and the entrypoint removes any stale `var/cache` leftovers from the volume.
- **Setup is idempotent** - `sulu:build prod` only runs when the database is empty, and the admin user is only created if it doesn't exist. Restarts and redeploys are safe.
- **`TRUSTED_PROXIES=REMOTE_ADDR`** - makes Symfony trust the Bunny edge proxy so `X-Forwarded-Proto` is honored and generated URLs use `https`.
- **Change the defaults before going to production** - Set your own `APP_SECRET`, `SULU_ADMIN_PASSWORD`, and database passwords (in `bunny.json` or as environment variables in the Magic Containers dashboard).
