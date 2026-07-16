# Sulu Skeleton 3.0 für Bunny Magic Containers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein deploybares Template-Repo: Sulu Skeleton 3.0.7 auf `php:8.4-apache` + MariaDB 11, lauffähig lokal via Docker Compose und auf Bunny Magic Containers (`bunny.json`, GitHub-Actions-Deploy nach ghcr.io).

**Architecture:** Ein `app`-Container (Apache + mod_php, DocumentRoot `public/`), ein `db`-Container (`mariadb:11`). Der Entrypoint macht das komplette Setup zur Laufzeit (Cache, DB-Wait, `sulu:build prod`, Admin-User) — idempotent, damit jeder Restart safe ist. Kein Config-Caching zur Build-Zeit, damit Runtime-Env-Vars von Magic Containers greifen.

**Tech Stack:** Sulu 3.0.7 (Symfony 7), PHP 8.4, Apache mod_php, MariaDB 11, Docker/Compose, GitHub Actions, ghcr.io, Bunny Magic Containers.

## Global Constraints

- Sulu Skeleton Version: **3.0.7** (Tag `3.0.7` von sulu/skeleton, identisch mit Branch `3.0` Stand heute, Commit `96aedfa`)
- Basis-Image: **`php:8.4-apache`** — kein nginx, kein FPM, kein supervisord
- DB-Image: **`mariadb:11`**
- In `bunny.json` MUSS der DB-Host **`127.0.0.1`** sein (nicht `localhost` — PDO nähme sonst Unix-Socket); in `docker-compose.yml` ist der Host `db`
- Console-Kommandos im Container laufen als **`www-data`** (`runuser -u www-data --`), nie als root (sonst gehören Cache-Dateien root und Apache kann nicht schreiben)
- Verifizierte Sulu-3.0-Kommandos (aus sulu/sulu 3.0 Quellcode):
  - `sulu:build prod --no-interaction` → Builder: database, fixtures, system_collections, security, homepage (KEIN User)
  - `sulu:security:role:create <name> <system>` → legt Rolle mit vollen Permissions (127) auf allen Security-Contexts an; Exit 1 wenn Rolle existiert
  - `sulu:security:user:create <username> <firstName> <lastName> <email> <locale> <role> <password>`
  - System für Admin-Rollen heißt `Sulu`; Webspace-Default-Locale ist `en`
- `doctrine/doctrine-fixtures-bundle` ist prod-Dependency im Skeleton → `sulu:build prod` funktioniert im `--no-dev`-Image
- APP_SECRET für bunny.json/docker-compose: `df8ab92c6cdd0776f9717e6c0f3fbb1d` (Platzhalter fürs Template, README weist auf Austausch hin)
- Arbeitsverzeichnis: `/Users/alex/Data/DEV/sulu/sulu-skeleton-mc`, Skeleton-Quelle liegt bereits geklont unter `$SCRATCH/sulu-skeleton` (`/private/tmp/claude-501/-Users-alex-Data-DEV-sulu-sulu-skeleton-mc/df973f37-6ab3-479f-9d94-dc4580506100/scratchpad/sulu-skeleton`)

---

### Task 1: Sulu Skeleton 3.0.7 importieren

**Files:**
- Create: gesamter Skeleton-Baum (`assets/`, `bin/`, `config/`, `migrations/`, `public/`, `src/`, `templates/`, `tests/`, `translations/`, `var/`, `composer.json`, `symfony.lock`, `.env`, `.env.dev`, `.env.stage`, `.env.test`, `phpstan.dist.neon`, `phpunit.dist.xml`, `rector.php`, `LICENSE`, `.gitignore`, `.github/workflows/test-application.yaml`)
- Delete (nicht übernehmen): `compose.yaml`, `compose.override.yaml`, Skeleton-`README.md` (eigenes README kommt in Task 8)
- Modify: `.gitignore` (Zeile `composer.lock` entfernen, damit der Lock committed werden kann)

**Interfaces:**
- Produces: lauffähiges Sulu-Projekt-Layout mit `bin/adminconsole`, `bin/websiteconsole`, `bin/console`, `public/index.php`, `public/build/` (vorgebaute Admin-UI) — alle späteren Tasks bauen darauf auf

- [ ] **Step 1: Skeleton auf Tag 3.0.7 checkouten und Dateien kopieren**

```bash
cd "$SCRATCH/sulu-skeleton" && git fetch --depth 1 origin tag 3.0.7 && git checkout 3.0.7
cd /Users/alex/Data/DEV/sulu/sulu-skeleton-mc
rsync -a --exclude '.git' --exclude 'compose.yaml' --exclude 'compose.override.yaml' --exclude 'README.md' "$SCRATCH/sulu-skeleton/" ./
```

- [ ] **Step 2: `composer.lock` aus `.gitignore` entfernen**

In `.gitignore` die Zeile `composer.lock` löschen (Edit-Tool, exakte Zeile im Block `# composer`).

- [ ] **Step 3: Verifizieren, dass die Admin-UI vorgebaut ist und die Kern-Dateien da sind**

Run: `ls public/build/admin/ | head -5 && ls bin/ && test ! -f compose.yaml && echo OK`
Expected: JS/CSS-Dateien der Admin-UI, `adminconsole console console.php phpunit websiteconsole`, `OK`

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "Import Sulu Skeleton 3.0.7"
```

---

### Task 2: composer.lock generieren

**Files:**
- Create: `composer.lock`

**Interfaces:**
- Consumes: `composer.json` aus Task 1
- Produces: `composer.lock` — vom Dockerfile (Task 3) für reproduzierbare Builds benutzt

- [ ] **Step 1: Lock-File in einem Composer-Container generieren (ohne Install)**

```bash
docker run --rm -v "$PWD":/app -w /app composer:2 composer update --no-install --no-scripts --ignore-platform-reqs --no-progress
```

Expected: endet mit `Writing lock file`. (`--ignore-platform-reqs`, weil das Composer-Image nicht alle PHP-Extensions hat — die Versionsauflösung bleibt korrekt, geprüft wird beim `composer install` im echten Image in Task 3.)

- [ ] **Step 2: Verifizieren, dass Sulu 3.0.7 gelockt wurde**

Run: `python3 -c "import json; pkgs={p['name']:p['version'] for p in json.load(open('composer.lock'))['packages']}; print(pkgs['sulu/sulu'])"`
Expected: `3.0.7`

- [ ] **Step 3: Commit**

```bash
git add composer.lock && git commit -m "Add composer.lock for reproducible builds"
```

---

### Task 3: Dockerfile, Apache-vHost und .dockerignore

**Files:**
- Create: `Dockerfile`, `docker/apache.conf`, `.dockerignore`

**Interfaces:**
- Consumes: `composer.json`, `composer.lock`, `symfony.lock` (Tasks 1–2)
- Produces: Image mit App unter `/var/www/html`, Apache auf Port 80, DocumentRoot `/var/www/html/public`; erwartet `/entrypoint.sh` (kommt in Task 4 — bis dahin baut das Image, startet aber nicht)

- [ ] **Step 1: `docker/apache.conf` schreiben**

```apache
<VirtualHost *:80>
    DocumentRoot /var/www/html/public

    <Directory /var/www/html/public>
        AllowOverride None
        Require all granted
        FallbackResource /index.php
    </Directory>

    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"

    ErrorLog /dev/stderr
    CustomLog /dev/stdout combined
</VirtualHost>
```

- [ ] **Step 2: `.dockerignore` schreiben**

```
.git
.github
docs
.env.local
.env.local.php
.env.*.local
var/
vendor/
node_modules/
public/bundles/
public/uploads/
tests/
.phpunit.cache
docker-compose.yml
bunny.json
README.md
```

Hinweis: Symfonys committete `.env` (Defaults, keine Secrets) bleibt bewusst im Image — echte Env-Vars von Magic Containers überschreiben `.env`-Werte (Symfony-Standardverhalten). Nur die `.local`-Varianten werden ausgeschlossen.

- [ ] **Step 3: `Dockerfile` schreiben**

```dockerfile
FROM php:8.4-apache

RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip \
        libicu-dev libzip-dev libpng-dev libjpeg62-turbo-dev libwebp-dev libfreetype6-dev \
    && docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl gd zip exif opcache \
    && a2enmod rewrite headers \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html

COPY composer.json composer.lock symfony.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-progress

COPY . .

RUN composer dump-autoload --optimize --no-dev \
    && mkdir -p var public/uploads \
    && chown -R www-data:www-data var public/uploads

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

CMD ["/entrypoint.sh"]
```

- [ ] **Step 4: Platzhalter-Entrypoint anlegen, damit der Build durchläuft** (wird in Task 4 ersetzt)

```bash
mkdir -p docker && printf '#!/bin/sh\nexec apache2-foreground\n' > docker/entrypoint.sh
```

- [ ] **Step 5: Image bauen**

Run: `docker build -t sulu-skeleton-mc:dev .`
Expected: Build endet erfolgreich; `composer install` läuft ohne Platform-Req-Fehler durch (beweist, dass alle nötigen PHP-Extensions im Image sind).

- [ ] **Step 6: Commit**

```bash
git add Dockerfile docker/apache.conf .dockerignore docker/entrypoint.sh
git commit -m "Add Apache-based Dockerfile"
```

---

### Task 4: Entrypoint mit idempotentem Sulu-Setup

**Files:**
- Modify: `docker/entrypoint.sh` (Platzhalter aus Task 3 ersetzen)

**Interfaces:**
- Consumes: Env-Vars `SULU_ADMIN_USER`, `SULU_ADMIN_PASSWORD`, `SULU_ADMIN_EMAIL` (Defaults `admin`/`admin`/`admin@example.com`), `DATABASE_URL`
- Produces: Container, der beim Start wartet/initialisiert/started — Grundlage für Compose (Task 5) und bunny.json (Task 6)

- [ ] **Step 1: `docker/entrypoint.sh` schreiben**

```sh
#!/bin/sh
set -e

cd /var/www/html

: "${SULU_ADMIN_USER:=admin}"
: "${SULU_ADMIN_PASSWORD:=admin}"
: "${SULU_ADMIN_EMAIL:=admin@example.com}"

# var/ may be a freshly mounted, empty volume — recreate the layout and
# make it writable for www-data before running any console command.
mkdir -p var/cache var/log var/share var/indexes var/sessions public/uploads
chown www-data:www-data var var/cache var/log var/share var/indexes var/sessions public/uploads

console() {
    runuser -u www-data -- php "$@"
}

echo "Preparing application (cache, assets, media dirs)..."
console bin/adminconsole cache:clear
console bin/websiteconsole cache:clear
console bin/console assets:install public
console bin/adminconsole sulu:media:init

echo "Waiting for database..."
i=0
until console bin/adminconsole doctrine:query:sql "SELECT 1" > /dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "ERROR: database was not reachable after 60 seconds, giving up." >&2
        exit 1
    fi
    sleep 1
done
echo "Database is ready."

if ! console bin/adminconsole doctrine:query:sql "SELECT 1 FROM se_users LIMIT 1" > /dev/null 2>&1; then
    echo "Empty database detected, running sulu:build prod..."
    console bin/adminconsole sulu:build prod --no-interaction
fi

if ! console bin/adminconsole doctrine:query:sql "SELECT username FROM se_users WHERE username = '${SULU_ADMIN_USER}'" 2> /dev/null | grep -q "${SULU_ADMIN_USER}"; then
    echo "Creating admin user '${SULU_ADMIN_USER}'..."
    console bin/adminconsole sulu:security:role:create Admin Sulu || true
    console bin/adminconsole sulu:security:user:create \
        "${SULU_ADMIN_USER}" Admin Sulu "${SULU_ADMIN_EMAIL}" en Admin "${SULU_ADMIN_PASSWORD}"
fi

exec apache2-foreground
```

Begründungen, die im Code nicht sichtbar sind: `sulu:build prod` legt KEINEN User an (nur das dev-Target tut das) — deshalb die zwei getrennten idempotenten Blöcke. `role:create Admin Sulu` vergibt volle Permissions (127) auf alle Security-Contexts; `|| true`, weil das Kommando mit Exit 1 endet, wenn die Rolle schon existiert (z. B. nach abgebrochenem Erststart).

- [ ] **Step 2: Image neu bauen**

Run: `docker build -t sulu-skeleton-mc:dev .`
Expected: erfolgreich.

- [ ] **Step 3: Commit**

```bash
git add docker/entrypoint.sh && git commit -m "Add idempotent Sulu setup entrypoint"
```

---

### Task 5: Trusted Proxies + docker-compose.yml, lokaler End-to-End-Test

**Files:**
- Modify: `config/packages/framework.yaml` (trusted_proxies via Env-Var aktivieren)
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: Image aus Task 3/4
- Produces: lauffähiger lokaler Stack auf `http://localhost:8000`; `TRUSTED_PROXIES`-Env-Var, die `bunny.json` (Task 6) setzt

- [ ] **Step 1: `config/packages/framework.yaml` erweitern**

Unter dem `framework:`-Schlüssel direkt nach `http_method_override: true` einfügen:

```yaml
    # Behind the Bunny CDN / a reverse proxy: trust the immediate peer so
    # X-Forwarded-Proto is honored and generated URLs use https.
    trusted_proxies: '%env(default::TRUSTED_PROXIES)%'
```

(`default::` ohne Fallback-Variable ⇒ `null`, wenn `TRUSTED_PROXIES` nicht gesetzt ist — lokal bleibt also alles beim Standardverhalten.)

- [ ] **Step 2: `docker-compose.yml` schreiben**

```yaml
services:
  app:
    build: .
    ports:
      - "8000:80"
    environment:
      - APP_ENV=prod
      - APP_SECRET=df8ab92c6cdd0776f9717e6c0f3fbb1d
      - DATABASE_URL=mysql://sulu:sulu@db:3306/sulu?serverVersion=11.8.2-MariaDB&charset=utf8mb4
      - SULU_ADMIN_EMAIL=admin@example.com
      - DEFAULT_URI=http://localhost:8000
    volumes:
      - appvar:/var/www/html/var
    depends_on:
      db:
        condition: service_healthy

  db:
    image: mariadb:11
    environment:
      MARIADB_DATABASE: sulu
      MARIADB_USER: sulu
      MARIADB_PASSWORD: sulu
      MARIADB_ROOT_PASSWORD: root
    volumes:
      - dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  appvar:
  dbdata:
```

- [ ] **Step 3: Stack starten und Setup-Log beobachten**

Run: `docker compose up --build -d && docker compose logs -f app` (Log-Follow nach dem Apache-Start mit Ctrl-C beenden bzw. mit Timeout laufen lassen)
Expected im app-Log, in dieser Reihenfolge: `Preparing application`, `Waiting for database`, `Database is ready`, `Empty database detected, running sulu:build prod`, `Creating admin user 'admin'`, danach Apache-Startzeilen. Keine PHP-Exceptions.

- [ ] **Step 4: Website und Admin prüfen**

Run: `curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/ && echo && curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/admin && echo`
Expected: `200` und `200`.

- [ ] **Step 5: Admin-Login end-to-end prüfen** (Sulu-Login ist ein JSON-POST; CSRF läuft über Cookie)

Im Browser (`http://localhost:8000/admin`) mit `admin`/`admin` einloggen — Admin-UI muss laden und Navigation (Webspaces, Media, Contacts, Settings) zeigen (beweist, dass die Rolle Permissions hat).

- [ ] **Step 6: Idempotenz prüfen (Restart)**

Run: `docker compose restart app && docker compose logs --tail 50 app`
Expected: Log zeigt WEDER `Empty database detected` NOCH `Creating admin user` (beide Checks greifen), endet mit Apache-Start; `curl` auf `/` liefert weiterhin `200`.

- [ ] **Step 7: Commit**

```bash
git add config/packages/framework.yaml docker-compose.yml
git commit -m "Add docker-compose setup and trusted proxy support"
```

---

### Task 6: bunny.json

**Files:**
- Create: `bunny.json`

**Interfaces:**
- Consumes: Env-Var-Kontrakt des Entrypoints (Task 4), `TRUSTED_PROXIES` (Task 5)
- Produces: Magic-Containers-App-Definition, auf die das README (Task 8) verweist

- [ ] **Step 1: `bunny.json` schreiben**

```json
{
    "id": "sulu-mariadb",
    "name": "Sulu + MariaDB",
    "description": "Sulu CMS 3 with MariaDB on Apache, deployed to Magic Containers.",
    "icon": "code",
    "containers": [
        {
            "name": "app",
            "imageNamespace": "{{github.repository_owner}}",
            "imageName": "{{github.repository_name}}",
            "imageTag": "latest",
            "endpoints": [
                {
                    "displayName": "HTTP",
                    "type": "CDN",
                    "containerPort": 80
                }
            ],
            "environment": {
                "APP_ENV": "prod",
                "APP_SECRET": "df8ab92c6cdd0776f9717e6c0f3fbb1d",
                "DATABASE_URL": "mysql://sulu:sulu@127.0.0.1:3306/sulu?serverVersion=11.8.2-MariaDB&charset=utf8mb4",
                "TRUSTED_PROXIES": "REMOTE_ADDR",
                "SULU_ADMIN_EMAIL": "admin@example.com",
                "SULU_ADMIN_USER": "admin",
                "SULU_ADMIN_PASSWORD": "admin"
            },
            "volumes": [
                {
                    "mountPath": "/var/www/html/var"
                }
            ]
        },
        {
            "name": "db",
            "imageNamespace": "library",
            "imageName": "mariadb",
            "imageTag": "11",
            "environment": {
                "MARIADB_DATABASE": "sulu",
                "MARIADB_USER": "sulu",
                "MARIADB_PASSWORD": "sulu",
                "MARIADB_ROOT_PASSWORD": "root"
            },
            "volumes": [
                {
                    "mountPath": "/var/lib/mysql"
                }
            ]
        }
    ]
}
```

(Struktur 1:1 vom Laravel-Template übernommen; App-Volume auf `/var/www/html/var` ist der Sulu-spezifische Zusatz — dort liegen Media-Originale in `var/share` und der Loupe-Suchindex in `var/indexes`. `TRUSTED_PROXIES=REMOTE_ADDR` lässt Symfony dem Bunny-Edge-Proxy vertrauen, damit `X-Forwarded-Proto: https` greift.)

- [ ] **Step 2: JSON validieren**

Run: `python3 -m json.tool bunny.json > /dev/null && echo VALID`
Expected: `VALID`

- [ ] **Step 3: Commit**

```bash
git add bunny.json && git commit -m "Add Magic Containers app definition"
```

---

### Task 7: GitHub-Actions-Deploy-Workflow

**Files:**
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: Dockerfile (Task 3); Repo-Variable `APP_ID`, Secret `BUNNYNET_API_KEY` (vom Nutzer zu konfigurieren)
- Produces: Image `ghcr.io/<owner>/<repo>:{latest,<sha>}`, automatisches Deploy des `app`-Containers

- [ ] **Step 1: `.github/workflows/deploy.yml` schreiben** (1:1-Muster des Laravel-Templates)

```yaml
name: Build and Deploy to Magic Containers
on:
  push:
    branches:
      - main
jobs:
  build:
    name: Build and deploy
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - name: Docker login
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository }}:${{ github.sha }}
            ghcr.io/${{ github.repository }}:latest
      - name: Deploy to Magic Containers
        uses: BunnyWay/actions/container-update-image@main
        with:
          app_id: ${{ vars.APP_ID }}
          api_key: ${{ secrets.BUNNYNET_API_KEY }}
          container: app
          image_tag: ${{ github.sha }}
```

- [ ] **Step 2: YAML validieren**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml')); print('VALID')"`
Expected: `VALID` (falls PyYAML fehlt: `docker run --rm -v "$PWD":/w -w /w mikefarah/yq '.jobs.build.steps | length' .github/workflows/deploy.yml` → `4`)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml && git commit -m "Add build-and-deploy workflow for Magic Containers"
```

---

### Task 8: README.md

**Files:**
- Create: `README.md` (ersetzt das in Task 1 bewusst nicht übernommene Skeleton-README)

**Interfaces:**
- Consumes: alle vorherigen Tasks (beschreibt deren Artefakte)

- [ ] **Step 1: `README.md` schreiben** — Struktur des Laravel-Template-READMEs, angepasst auf Sulu. Muss enthalten:

1. Titel „Sulu CMS 3 + MariaDB for Magic Containers" + Kurzbeschreibung mit Links auf sulu.io und bunny.net/magic-containers
2. „What's included": Dockerfile (PHP 8.4 + Apache/mod_php), docker/apache.conf, docker/entrypoint.sh (wartet auf DB, `sulu:build prod`, legt Admin an), docker-compose.yml, bunny.json, deploy.yml
3. „Run locally": `docker compose up --build`, URL `http://localhost:8000`, Admin unter `http://localhost:8000/admin` mit `admin`/`admin` — Hinweis, dass das Setup automatisch läuft (keine manuellen Migrations nötig)
4. „Deploy to Magic Containers": Fork & Push → Package public machen → App im Bunny-Dashboard anlegen. Beide Container dokumentieren: app (ghcr-Image, Endpoint Port 80, Env-Vars aus bunny.json inkl. `TRUSTED_PROXIES=REMOTE_ADDR`, **Volume auf `/var/www/html/var`**) und db (`mariadb:11`, `MARIADB_*`-Vars, Volume `/var/lib/mysql`)
5. „Continuous deployment": Repo-Variable `APP_ID`, Secret `BUNNYNET_API_KEY`
6. „Important notes for Magic Containers" (übernommen + Sulu-spezifisch):
   - `DATABASE_URL` muss `127.0.0.1` verwenden, nicht `localhost` (PDO/Unix-Socket)
   - Config wird zur Laufzeit gecacht, nicht im Image (Runtime-Env-Vars)
   - App-Volume auf `/var/www/html/var` nötig: Media-Uploads (`var/share`) und Suchindex (`var/indexes`) liegen im Dateisystem
   - Setup ist idempotent: `sulu:build prod` nur bei leerer DB, Admin-User nur wenn er fehlt
   - **Vor Produktivbetrieb ändern:** `APP_SECRET`, `SULU_ADMIN_PASSWORD`, DB-Passwörter (in bunny.json bzw. als Env-Vars im Dashboard)

- [ ] **Step 2: Commit**

```bash
git add README.md && git commit -m "Add template README"
```

---

### Task 9: Finale End-to-End-Verifikation (frischer Zustand)

**Files:** keine neuen — reine Verifikation der Erfolgskriterien aus dem Spec

- [ ] **Step 1: Kompletten Stack von null aufbauen** (simuliert Erstinstallation eines Nutzers)

```bash
docker compose down -v && docker compose up --build -d
```

Warten bis `docker compose logs app` den Apache-Start zeigt (Setup dauert beim Erststart 1–3 Minuten inkl. sulu:build).

- [ ] **Step 2: Alle Erfolgskriterien durchgehen**

- `curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/` → `200` (Sulu-Homepage)
- `curl -s http://localhost:8000/ | grep -io '<title>[^<]*'` → nicht leer
- `curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/admin` → `200` (Login-Seite)
- Browser-Login `admin`/`admin` auf `/admin` → Admin-UI mit Navigation
- `docker compose restart app` → Logs ohne `Empty database detected` / `Creating admin user`, `/` weiterhin `200`
- `python3 -m json.tool bunny.json > /dev/null && echo VALID` → `VALID`

- [ ] **Step 3: Arbeitsstand aufräumen und final committen**

```bash
git status --short   # muss leer sein; falls nicht: fehlende Dateien committen
docker compose down
```

---

## Self-Review (durchgeführt)

- **Spec-Coverage:** Skeleton-Import (T1/T2), Dockerfile/Apache (T3), Entrypoint (T4), Compose + Trusted Proxies (T5), bunny.json inkl. App-Volume (T6), Workflow (T7), README (T8), Erfolgskriterien (T9) — alle Spec-Abschnitte abgedeckt.
- **Platzhalter:** keine TBDs; der einzige „Platzhalter" ist der bewusst zweistufige Entrypoint in T3 Step 4, der in T4 ersetzt wird (nötig, damit T3 unabhängig baubar/reviewbar ist).
- **Konsistenz:** Env-Var-Namen (`SULU_ADMIN_USER/PASSWORD/EMAIL`, `DATABASE_URL`, `TRUSTED_PROXIES`, `APP_SECRET`) sind über T4/T5/T6/T8 identisch; Volume-Pfad `/var/www/html/var` identisch in T5/T6/T8; Rolle heißt durchgängig `Admin` im System `Sulu`.
