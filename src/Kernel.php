<?php

declare(strict_types=1);

namespace App;

/*
 * This file is part of Sulu.
 *
 * (c) Sulu GmbH
 *
 * This source file is subject to the MIT license that is bundled
 * with this source code in the file LICENSE.
 */

use FOS\HttpCache\SymfonyCache\HttpCacheProvider;
use Sulu\Bundle\HttpCacheBundle\Cache\SuluHttpCache;
use Sulu\Component\HttpKernel\SuluKernel;
use Symfony\Component\Config\Loader\LoaderInterface;
use Symfony\Component\DependencyInjection\ContainerBuilder;
use Symfony\Component\HttpKernel\HttpKernelInterface;

class Kernel extends SuluKernel implements HttpCacheProvider
{
    private ?HttpKernelInterface $httpCache = null;

    /**
     * Allows moving the cache off the project dir via APP_CACHE_DIR, e.g. to
     * keep it out of a persistent volume mounted at var/ (the cache is
     * per-image-build and must not survive deploys). Preserves the Sulu
     * layout of one cache dir per context (admin/website/preview).
     */
    public function getCacheDir(): string
    {
        $dir = $_SERVER['APP_CACHE_DIR'] ?? $_ENV['APP_CACHE_DIR'] ?? (\getenv('APP_CACHE_DIR') ?: null);

        if (\is_string($dir) && '' !== $dir) {
            return $dir . \DIRECTORY_SEPARATOR . $this->getContext() . \DIRECTORY_SEPARATOR . $this->environment;
        }

        return parent::getCacheDir();
    }

    protected function configureContainer(ContainerBuilder $container, LoaderInterface $loader): void
    {
        $container->setParameter('container.dumper.inline_class_loader', true);

        parent::configureContainer($container, $loader);
    }

    public function getHttpCache(): HttpKernelInterface
    {
        if (!$this->httpCache instanceof HttpKernelInterface) {
            $this->httpCache = new SuluHttpCache($this);
            // Activate the following for user based caching see also:
            // https://foshttpcachebundle.readthedocs.io/en/latest/features/user-context.html
            //
            // $this->httpCache->addSubscriber(
            //    new \FOS\HttpCache\SymfonyCache\UserContextListener([
            //        'session_name_prefix' => 'SULUSESSID',
            //    ])
            // );
        }

        return $this->httpCache;
    }
}
