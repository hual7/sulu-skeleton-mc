<?php

declare(strict_types=1);

namespace App\Controller\Website;

use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Externally-triggerable backup endpoints.
 *
 * Bunny Magic Containers scales idle pods to zero, so an in-container cron
 * cannot reliably fire the scheduled backup — if the pod is asleep at the
 * scheduled minute, the tick is simply missed (which is why the container-side
 * cron was dropped). These endpoints let external schedulers (the "Backup db"
 * and "Backup media" GitHub Actions workflows) run docker/backup.sh
 * *inside the running pod* — the only place the MariaDB sidecar and the
 * node-local media volume are reachable — and without a redeploy (a redeploy
 * risks the pod landing on a fresh, empty MC volume; see the deployment notes).
 *
 * Security: guarded by a shared secret in BACKUP_TRIGGER_TOKEN. When that env
 * var is unset/empty the routes respond 404, so the triggers are off by default
 * and never expose an unauthenticated shell entry point. The token is compared
 * in constant time and only POST is accepted. The endpoints run a fixed binary
 * with a fixed, code-defined scope argument (no request-derived input), so there
 * is no command-injection surface.
 */
final class BackupController
{
    private const SCRIPT = '/usr/local/bin/backup';

    /**
     * Full backup: database dump + media sync.
     */
    #[Route('/_ops/backup', name: 'app_ops_backup', methods: ['POST'])]
    public function backup(Request $request): Response
    {
        return $this->run($request, 'full');
    }

    /**
     * Database only: dump + retention (used by the scheduled "Backup db"
     * workflow). No media sync.
     */
    #[Route('/_ops/backup-db', name: 'app_ops_backup_db', methods: ['POST'])]
    public function backupDb(Request $request): Response
    {
        return $this->run($request, 'db');
    }

    /**
     * Media only: push var/storage and public/uploads to the storage zone
     * (used by the scheduled "Backup media" workflow). No database dump.
     */
    #[Route('/_ops/backup-media', name: 'app_ops_backup_media', methods: ['POST'])]
    public function backupMedia(Request $request): Response
    {
        return $this->run($request, 'media');
    }

    /**
     * @param 'full'|'media' $scope fixed, code-defined argument passed to backup.sh
     */
    private function run(Request $request, string $scope): Response
    {
        $expected = (string) ($_SERVER['BACKUP_TRIGGER_TOKEN']
            ?? $_ENV['BACKUP_TRIGGER_TOKEN']
            ?? (\getenv('BACKUP_TRIGGER_TOKEN') ?: ''));

        // Feature disabled unless a token is configured.
        if ('' === $expected) {
            return $this->plain('backup trigger not configured', Response::HTTP_NOT_FOUND);
        }

        $provided = (string) $request->headers->get('X-Backup-Token', '');
        if ('' === $provided || !\hash_equals($expected, $provided)) {
            return $this->plain('forbidden', Response::HTTP_FORBIDDEN);
        }

        if (!\is_executable(self::SCRIPT)) {
            return $this->plain('backup script not found at ' . self::SCRIPT, Response::HTTP_INTERNAL_SERVER_ERROR);
        }

        // The media sync can take a little while; don't let PHP's default
        // execution cap abort it, and keep going even if the client hangs up.
        \set_time_limit(0);
        \ignore_user_abort(true);

        $output = [];
        $exitCode = 0;
        // Merge stderr so rclone/mariadb-dump diagnostics reach the response
        // body (and thus the GitHub Actions log). The scope is a fixed literal.
        \exec(self::SCRIPT . ' ' . $scope . ' 2>&1', $output, $exitCode);

        // backup.sh deliberately exits 0 even on internal failures (it must
        // never abort the container when run from the entrypoint). So a clean
        // exit code is not proof of success — scan the log for the ERROR:
        // marker it prints via fail() to surface a real problem to the caller.
        $hadError = 0 !== $exitCode || [] !== \preg_grep('/ERROR:/', $output);
        $status = $hadError ? Response::HTTP_INTERNAL_SERVER_ERROR : Response::HTTP_OK;

        return $this->plain(\implode("\n", $output), $status);
    }

    private function plain(string $body, int $status): Response
    {
        $response = new Response($body . "\n", $status);
        $response->headers->set('Content-Type', 'text/plain; charset=utf-8');
        $response->headers->set('Cache-Control', 'no-store, private');
        $response->headers->set('X-Robots-Tag', 'noindex');

        return $response;
    }
}
