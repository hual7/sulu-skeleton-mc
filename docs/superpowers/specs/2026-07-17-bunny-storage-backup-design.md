# Backup nach Bunny Storage (S3) via rclone — Design

**Datum:** 2026-07-17
**Status:** Approved (pending spec review)

## Ziel

Einweg-Backup (Disaster-Recovery) des sulu-skeleton-mc-Deployments auf Bunny
Magic Containers nach **Bunny Storage** über die **S3-kompatible API**. Das
Backup umfasst die Datenbank und die Medien; es läuft periodisch **im
App-Container** per Cron und ist **opt-in** (deaktiviert, solange keine
Credentials gesetzt sind).

Nicht-Ziele: Zwei-Wege-Sync, Auslagern des Storage-Layers (Flysystem-Adapter),
Restore-Automatik. Restore erfolgt manuell (siehe Abschnitt Restore).

## Kontext & Randbedingungen

- App-Container besitzt `/data`-Volume (`APP_DATA_DIR=/data`): `var/storage`
  (Medien-Originale, Flysystem), `var/indexes` (Loupe-Suchindex),
  `public/uploads` (generierte Bildformate).
- DB-Container: MariaDB `10.11.14`, Datadir-Volume `/var/lib/mysql`. Vom
  App-Container aus über `127.0.0.1:3306` erreichbar (siehe `DATABASE_URL`).
- MC-Eigenheiten (siehe Memory): Volumes erzwingen root-Ownership und ignorieren
  chown; zwei Container dürfen nie in dieselbe Volume-Root schreiben →
  Backup-Job gehört in den App-Container, nicht in einen separaten Container.
- MC hat keine nativen Sidecars/Cronjobs → Cron läuft in-Container.
- **Bunny S3** ist Closed Preview; Zugang vorhanden. Endpoint-Format:
  `https://<region>-s3.storage.bunnycdn.com`, `provider=Other`,
  `access_key_id=<Storage-Zone-Name>`, `secret_access_key=<Storage-Passwort>`.
  S3-Kompatibilität muss bei Zonen-Erstellung aktiviert sein.
- Das Backup wird gegen ein **generisches rclone-Remote `bunny:`** gebaut. Ob
  dieses S3 oder (Fallback) SFTP spricht, ist reine Env-Config. Default: S3.

## Backup-Umfang

| Quelle | Ziel im Remote | Methode | Begründung |
|---|---|---|---|
| MariaDB `sulu` | `bunny:<bucket>/db/sulu-<ts>.sql.gz` | `mariadb-dump` + gzip + `rclone copy` | Content/Struktur/Medien-Metadaten, kritisch |
| `var/storage` | `bunny:<bucket>/storage/` | `rclone sync` | Medien-Originale, nicht reproduzierbar |
| `public/uploads` | `bunny:<bucket>/uploads/` | `rclone sync` | generierte Formate, reproduzierbar aber teuer |
| `var/indexes` | — | ausgelassen | Loupe-Index aus DB+Medien reproduzierbar |

## Komponenten

### 1. Dockerfile
Zwei zusätzliche Alpine-Pakete in der bestehenden `apk add --no-cache`-Zeile
(runtime, kein Build-Overhead):
- `rclone` — Transfer nach Bunny Storage
- `mariadb-client` — liefert `mariadb-dump` (mysqldump)

### 2. `docker/backup.sh` (neu)
Idempotentes, in sich abgeschlossenes Skript. Bricht bei Fehlern **nie** den
Container ab (Fehler nur geloggt, Exit-Code an crond geht verloren).

Ablauf:
1. `flock` auf `/var/lock/backup.lock` (non-blocking) → überlappende Läufe
   werden übersprungen.
2. Guard: wenn `BACKUP_ENABLED != true` → Exit 0.
3. **DB-Dump:** Host/Port/User/Passwort/DB aus `DATABASE_URL` parsen,
   `mariadb-dump --single-transaction --quick` → `gzip` → temporäre Datei in
   `$APP_CACHE_DIR/backup/` (nicht auf dem Volume). Bei Erfolg `rclone copy`
   nach `bunny:$BACKUP_BUCKET/db/`. Danach Temp-Datei löschen.
4. **DB-Retention:** Remote-Dumps unter `db/` per `rclone lsf` auflisten, nach
   Timestamp sortieren, alle bis auf die neuesten `BACKUP_RETENTION` (Default 7)
   löschen.
5. **Medien:** `rclone sync var/storage bunny:$BACKUP_BUCKET/storage` und
   `rclone sync public/uploads bunny:$BACKUP_BUCKET/uploads`. Wenn
   `BACKUP_KEEP_DELETED=true` (Default): zusätzlich
   `--backup-dir bunny:$BACKUP_BUCKET/_deleted/<date>` → lokal
   gelöschte/überschriebene Dateien landen versioniert statt sofort weg zu sein.
6. Logging mit Zeitstempel nach stdout (landet im Container-Log).

Symlink-Hinweis: `var/storage` und `public/uploads` sind im APP_DATA_DIR-Modus
Symlinks nach `/data`. rclone folgt Symlinks nur mit `--copy-links` / `-L` —
das Skript setzt `-L`, damit die Symlink-Ziele gesynct werden.

### 3. `docker/entrypoint.sh`
- Wenn `BACKUP_ENABLED=true` **und** die S3-Credentials nicht leer sind:
  - Crontab schreiben (`$BACKUP_SCHEDULE /usr/local/bin/backup`), Default-Schedule
    `0 3 * * *` (täglich 03:00, Container-Zeit).
  - `crond` als **viertes überwachtes Kind** neben `php-fpm` und `httpd`
    starten; PID in die Supervise-Loop und ins TERM/INT/QUIT-Trap aufnehmen.
- Sonst: kein crond, Verhalten unverändert.
- rclone-Config kommt vollständig aus `RCLONE_CONFIG_BUNNY_*`-Env-Vars (kein
  Config-File, keine Secrets auf Platte). `backup.sh` wird als
  `/usr/local/bin/backup` verlinkt (analog `clear-caches`).

### 4. `bunny.json`
Neue Env-Vars im `app`-Container mit leeren/sicheren Defaults (Backup damit
standardmäßig **aus**):

```
BACKUP_ENABLED=""                       # "true" schaltet das Backup an
BACKUP_SCHEDULE="0 3 * * *"             # Cron-Ausdruck
BACKUP_RETENTION="7"                    # Anzahl aufbewahrter DB-Dumps
BACKUP_KEEP_DELETED="true"              # gelöschte Medien versioniert aufbewahren
BACKUP_BUCKET=""                        # Storage-Zone / Bucket-Name im Remote
RCLONE_CONFIG_BUNNY_TYPE="s3"
RCLONE_CONFIG_BUNNY_PROVIDER="Other"
RCLONE_CONFIG_BUNNY_ENDPOINT=""         # https://<region>-s3.storage.bunnycdn.com
RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID=""    # Storage-Zone-Name
RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY="" # Storage-Passwort
```

### 5. README
Kurzer Abschnitt: Backup aktivieren (Env-Vars), Schedule, Restore-Prozedur.

## Fehlerbehandlung

- Backup-Fehler dürfen den Container nie beeinträchtigen: `backup.sh` fängt
  Fehler ab, loggt sie, endet mit Exit 0 gegenüber crond.
- `flock` verhindert überlappende Läufe (langer Sync + nächster Cron-Tick).
- Leere/fehlende Credentials → Backup deaktiviert, keine crond-Prozesse.
- Der DB-Dump geht nach `$APP_CACHE_DIR/backup/` (außerhalb des Volumes), damit
  ein voller/kaputter Dump nie das Datenvolume belastet und beim Neustart weg ist.

## Restore (manuell, dokumentiert)

1. Medien: `rclone sync bunny:<bucket>/storage <APP_DATA_DIR>/storage` und
   `.../uploads`.
2. DB: `rclone copy bunny:<bucket>/db/sulu-<ts>.sql.gz .` →
   `gunzip -c ... | mariadb -h 127.0.0.1 -u sulu -p sulu`.
3. Suchindex neu aufbauen: `bin/adminconsole massive:search:index` bzw.
   Loupe-Reindex-Command.

## Testkriterien

- Image baut mit `rclone` und `mariadb-dump` vorhanden.
- Ohne `BACKUP_ENABLED=true`: kein crond-Prozess, App-Verhalten unverändert
  (php-fpm + httpd wie bisher, Supervise-Loop terminiert sauber bei SIGTERM).
- Mit gesetzten Credentials + `BACKUP_ENABLED=true`:
  - `backup` manuell im Container → DB-Dump landet unter `db/`, Medien unter
    `storage/`/`uploads/` im Remote.
  - Retention: >N Dumps → älteste werden gelöscht.
  - `BACKUP_KEEP_DELETED=true`: lokal gelöschte Datei erscheint unter `_deleted/`.
- Symlink-Modus (APP_DATA_DIR): Sync erfasst die Symlink-Ziele (`-L`).
- SIGTERM: crond wird mitbeendet, Container stoppt ohne SIGKILL-Verzögerung.

## Offene Punkte / Risiken

- Bunny S3 Closed Preview: Endpoint-/Auth-Verhalten kann sich ändern. Remote ist
  bewusst env-konfiguriert und backend-agnostisch (`bunny:`), damit ein Wechsel
  auf SFTP nur eine Env-Änderung ist.
- Container-Zeitzone bestimmt den Cron-Zeitpunkt; `BACKUP_SCHEDULE` ist bei Bedarf
  entsprechend zu wählen.
