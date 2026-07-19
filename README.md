# Sulu CMS 3 + MariaDB for Magic Containers

A [Sulu CMS 3](https://sulu.io/) app (based on the official [sulu/skeleton](https://github.com/sulu/skeleton) 3.0) with MariaDB, running on Apache, ready to deploy on [Bunny Magic Containers](https://bunny.net/magic-containers/).

## What's included

- `Dockerfile` - PHP 8.4 running as an Apache module (mod_php) on Debian in a single container
- `docker/apache.conf` - Apache vhost serving `public/` statically and executing PHP in-process via mod_php
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
   - Set the environment variables — paste this into the **Raw editor** and fill in the `BUNNY_*` values (see the note on CDN credentials below):

     ```env
     APP_ENV=prod
     APP_SECRET=df8ab92c6cdd0776f9717e6c0f3fbb1d
     DATABASE_URL=mysql://sulu:sulu@127.0.0.1:3306/sulu?serverVersion=10.11.14-MariaDB&charset=utf8mb4
     TRUSTED_PROXIES=REMOTE_ADDR
     APP_DATA_DIR=/data
     BUNNY_API_KEY=
     BUNNY_PULL_ZONE_ID=
     BUNNY_SITE_BASE_URL=
     SULU_ADMIN_EMAIL=admin@example.com
     SULU_ADMIN_USER=admin
     SULU_ADMIN_PASSWORD=admin
     ```
4. Add the **db** container:
   - **Image**: `mariadb:10.11.14`
   - Add a **Volume** mounted at `/var/lib/mysql`
   - Set the environment variables (Raw editor):

     ```env
     MARIADB_DATABASE=sulu
     MARIADB_USER=sulu
     MARIADB_PASSWORD=sulu
     MARIADB_ROOT_PASSWORD=root
     ```
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
- **Set the Bunny CDN credentials before the first start** - The `SuluBunnyCdnBundle` is enabled in `prod` and purges the CDN cache whenever content changes. `BUNNY_API_KEY` must be the **account** API key (Account → API Key, not a pull-zone key), `BUNNY_PULL_ZONE_ID` the numeric zone id, `BUNNY_SITE_BASE_URL` the public site URL. With missing or wrong credentials the purge request fails with `401 Unauthorized` — the very first container start then aborts mid-setup (it recovers on restart, but content edits keep logging errors).
- **Change the defaults before going to production** - Set your own `APP_SECRET`, `SULU_ADMIN_PASSWORD`, and database passwords (in `bunny.json` or as environment variables in the Magic Containers dashboard).

## Backup (Bunny Storage)

Optional one-way backup of the database and media to a Bunny Storage zone via
rclone. Disabled by default; enable it by setting env vars on the `app`
container (Magic Containers dashboard or `bunny.json`):

| Variable | Purpose |
|---|---|
| `BACKUP_ENABLED` | `true` turns the backup on |
| `BACKUP_BEFORE_MIGRATE` | full backup before every migration (default `true`) |
| `BACKUP_SCHEDULE` | cron expression for the periodic run (default `0 3 * * *`, container time / UTC) |
| `BACKUP_RETENTION` | number of DB dumps to keep (default `7`) |
| `BACKUP_KEEP_DELETED` | keep deleted/overwritten media under `_deleted/` (default `true`) |
| `BACKUP_BUCKET` | Bunny Storage zone / bucket name |
| `RCLONE_CONFIG_BUNNY_TYPE` | `s3` (default) or `sftp` |
| `RCLONE_CONFIG_BUNNY_PROVIDER` | `Other` for Bunny S3 |
| `RCLONE_CONFIG_BUNNY_ENDPOINT` | `https://<region>-s3.storage.bunnycdn.com` |
| `RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID` | storage zone name |
| `RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY` | storage password |

Ready-to-paste block for the Magic Containers raw env editor — replace the four
`<…>` placeholders (`BACKUP_BUCKET` and `RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID` are
both the storage zone name; `<region>` is the zone's region code, e.g. `de`,
`ny`; the secret is the zone password from Bunny → the zone → FTP & API Access):

```dotenv
BACKUP_ENABLED=true
BACKUP_BEFORE_MIGRATE=true
BACKUP_SCHEDULE=0 3 * * *
BACKUP_RETENTION=7
BACKUP_KEEP_DELETED=true
BACKUP_BUCKET=<storage-zone-name>
RCLONE_CONFIG_BUNNY_TYPE=s3
RCLONE_CONFIG_BUNNY_PROVIDER=Other
RCLONE_CONFIG_BUNNY_ENDPOINT=https://<region>-s3.storage.bunnycdn.com
RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID=<storage-zone-name>
RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY=<storage-zone-password>
```

Leave `BACKUP_ENABLED` empty to load the config without activating the backup
yet.

Everything is written under a `_backup/` prefix in the zone, so the storage zone
can be shared with other content (e.g. CDN media) without colliding. What is
backed up: the MariaDB database (`_backup/db/sulu-<ts>.sql.gz`), media originals
(`var/storage` → `_backup/storage/`) and generated image formats
(`public/uploads` → `_backup/uploads/`). The Loupe search index (`var/indexes`)
is not backed up — it is rebuilt from the database and media.

Bunny's S3-compatible API is currently in closed preview and must be enabled on
the storage zone. Without S3 access, set `RCLONE_CONFIG_BUNNY_TYPE=sftp` and the
matching SFTP host/user/key vars instead — the backup logic is unchanged.

With `BACKUP_KEEP_DELETED=true` (the default), media that is deleted or
overwritten locally is preserved under `_backup/_deleted/<timestamp>/` on the
storage zone. This prefix is **not** pruned automatically and will grow over time —
prune it periodically, or set `BACKUP_KEEP_DELETED=false` to disable versioning.

### Restore

1. Media: `rclone sync bunny:<bucket>/_backup/storage "$APP_DATA_DIR/storage"` and
   the same for `uploads`.
2. Database: `rclone copy bunny:<bucket>/_backup/db/sulu-<ts>.sql.gz .` then
   `gunzip -c sulu-<ts>.sql.gz | mariadb -h 127.0.0.1 -u sulu -psulu sulu`.
3. Rebuild the search index: `bin/adminconsole cmsig:seal:reindex`.
