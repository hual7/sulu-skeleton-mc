# Sulu Skeleton 3.0 für Bunny Magic Containers — Design

**Datum:** 2026-07-16
**Status:** Approved

## Ziel

Ein deploybares Template-Repository analog zu
[jamie-at-bunny/mc-template-laravel-with-mariadb](https://github.com/jamie-at-bunny/mc-template-laravel-with-mariadb),
aber mit **Sulu Skeleton 3.0 (latest, aktuell 3.0.7)** statt Laravel, **Apache (mod_php)** statt
Nginx/PHP-FPM und **MariaDB 11** als Datenbank. Zielplattform: Bunny Magic Containers,
lokale Entwicklung via Docker Compose.

## Gewählter Ansatz

Ein einzelner `app`-Container auf Basis von `php:8.4-apache` (mod_php, kein supervisord,
kein FPM) plus ein `db`-Container mit `mariadb:11`. Verworfene Alternativen:
Apache + PHP-FPM via supervisord (unnötig komplex) und getrennte Apache/FPM-Container
(kein shared Filesystem auf Magic Containers).

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| PHP-Version | 8.4 (`php:8.4-apache`), Sulu 3.0 verlangt ^8.2 |
| Admin-User | Automatisch beim ersten Start aus `SULU_ADMIN_USER` / `SULU_ADMIN_PASSWORD` / `SULU_ADMIN_EMAIL` (Default `admin`/`admin`), idempotent |
| CI/CD | GitHub Actions wie im Template: Build → ghcr.io (`latest` + Commit-SHA) → Deploy via `BunnyWay/actions/container-update-image` |
| Sulu-Code | Skeleton 3.0.7 wird ins Repo committed (wie das Laravel-Template die App committet), inkl. `composer.lock` |

## Repository-Struktur

```
sulu-skeleton-mc/
├── <Sulu Skeleton 3.0.7: assets/, bin/, config/, migrations/, public/, src/, templates/, …>
├── Dockerfile
├── .dockerignore
├── docker/
│   ├── apache.conf          # vHost: DocumentRoot public/, Rewrite für Symfony-Routing
│   └── entrypoint.sh
├── bunny.json               # Magic-Containers-App-Definition (app + db)
├── docker-compose.yml       # Lokale Entwicklung (Port 8000)
├── .github/workflows/deploy.yml
└── README.md
```

## Komponenten

### Dockerfile (`php:8.4-apache`)

- PHP-Extensions für Sulu: `pdo_mysql`, `intl`, `gd`, `zip`, `opcache` (+ `exif` für Media)
- `a2enmod rewrite`, DocumentRoot → `/var/www/html/public`
- Composer aus `composer:2`-Image kopiert; `composer install --no-dev --optimize-autoloader`
- **Kein** Config-Caching zur Build-Zeit (Runtime-Env-Vars von Magic Containers müssen greifen)
- Schreibrechte für `www-data` auf `var/` und `public/uploads`

### docker/entrypoint.sh

Reihenfolge beim Container-Start (jeder Schritt idempotent, Restart-safe):

1. Minimal-`.env` anlegen (`.env` ist via `.dockerignore` aus dem Image ausgeschlossen)
2. Symfony-Cache warmup (`cache:clear --env prod`) — zur Laufzeit, damit Env-Vars greifen
3. Auf MariaDB warten (Retry-Loop mit Timeout ~60s; bei Timeout Abbruch mit klarer Fehlermeldung)
4. Wenn DB-Schema fehlt (Existenz-Check auf Sulu-Tabelle): `bin/adminconsole sulu:build prod --no-interaction`
5. Wenn kein Admin-User existiert: Admin-Rolle + User aus `SULU_ADMIN_USER`/`SULU_ADMIN_PASSWORD`/`SULU_ADMIN_EMAIL` anlegen (exakte Console-Kommandos werden bei der Implementierung im Container verifiziert; Fallback: `sulu:security:user:create`)
6. `exec apache2-foreground`

### bunny.json

Zwei Container, Muster wie im Laravel-Template:

- **app**: `ghcr.io/{{github.repository_owner}}/{{github.repository_name}}:latest`,
  CDN-Endpoint auf Port 80. Env-Vars: `APP_ENV=prod`, `APP_SECRET`,
  `DATABASE_URL=mysql://sulu:sulu@127.0.0.1:3306/sulu?serverVersion=11-MariaDB&charset=utf8mb4`,
  `SULU_ADMIN_EMAIL`, `SULU_ADMIN_USER`, `SULU_ADMIN_PASSWORD`, `DEFAULT_URI`.
  **Wichtig:** `127.0.0.1`, nicht `localhost` (PDO würde Unix-Socket versuchen).
  **Volume** auf `/var/www/html/var` — dort liegen Media-Originale (`var/share`,
  via `APP_SHARE_DIR`) und der Loupe-Suchindex (`var/indexes`); ohne Volume wären
  Uploads nach jedem Deploy weg. `public/uploads` enthält nur regenerierbare
  Bildformate und braucht keine Persistenz.
- **db**: `library/mariadb:11`, Env `MARIADB_DATABASE=sulu`, `MARIADB_USER=sulu`,
  `MARIADB_PASSWORD=sulu`, `MARIADB_ROOT_PASSWORD=root`, Volume auf `/var/lib/mysql`.

### docker-compose.yml

Wie Template: `app` (Build aus Dockerfile, Port `8000:80`, `DB_HOST=db` via `DATABASE_URL`),
`db` (mariadb:11 mit Healthcheck `healthcheck.sh --connect --innodb_initialized`), Named Volume.

### .github/workflows/deploy.yml

1:1-Muster des Templates: checkout → docker login ghcr → build & push (`latest` + SHA) →
`BunnyWay/actions/container-update-image` mit `vars.APP_ID` und `secrets.BUNNYNET_API_KEY`.

### README.md

Angepasste Version des Template-READMEs: Lokal starten, Fork & Push, Package public machen,
App in Magic Containers anlegen (beide Container inkl. Volumes), Admin-Login unter `/admin`,
Hinweise zu `127.0.0.1`, Runtime-Config-Caching, `.env`-Ausschluss, automatischem Setup.

## Sulu-spezifische Abweichungen vom Laravel-Template

- `DATABASE_URL` (eine Variable) statt `DB_*`-Einzelvariablen
- Sulu 3.0 nutzt kein PHPCR mehr — eine einzige MariaDB, Init via `sulu:build`
- App-Container braucht ein Volume für Media-Uploads (Laravel brauchte keins)
- Admin-UI liegt vorgebaut in `public/build` (kein Node-Build im Docker-Image nötig)
- Setup-Kommando ist `sulu:build prod` statt `php artisan migrate`

## Verifikation / Erfolgskriterien

1. `docker compose up --build` läuft ohne Fehler durch
2. `http://localhost:8000` liefert die Sulu-Website (Standard-Homepage)
3. `http://localhost:8000/admin` zeigt das Admin-Login; Login mit `admin`/`admin` funktioniert
4. Container-Restart (`docker compose restart app`) läuft ohne Fehler (Idempotenz)
5. `bunny.json` ist valides JSON und folgt dem Schema des Templates
