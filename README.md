# Harbor wrapper chart

## Purpose

Install upstream Harbor chart 1.18.0, application 2.14.0, without changes to its
templates. Add five InfisicalStaticSecrets and the existing Traefik IngressRoute.
Harbor uses external services: PostgreSQL (`pg-prod` CNPG cluster), S3 storage
(MinIO), and Redis (`redis-harbor`). This chart does not install them.

## Before first install

1. Make sure these exist: the Infisical operator with its v1beta1 StaticSecret CRD,
   Traefik, and `default/infisical-prod-universal-auth`.
2. Make sure the external services are ready:
   - PostgreSQL has an empty `registry` database and the user `pg-harbor-admin`.
     The Secret `pg-harbor-database-credentials-secret` (key `password`) exists in
     namespace `harbor`.
   - The S3 bucket exists.
   - Redis runs at `redis-harbor-master.harbor.svc.cluster.local:6379` with the
     password from Infisical `/harbor/redis`.
3. Make sure the Infisical project has these keys:

   | Path | Keys |
   | --- | --- |
   | `/harbor/app` | `HARBOR_ADMIN_PASSWORD`, `HARBOR_SECRET_KEY` |
   | `/harbor/registry` | `HARBOR_REGISTRY_PASSWD`, `HARBOR_REGISTRY_HTPASSWD` |
   | `/harbor/redis` | `HARBOR_REDIS_PASSWORD` |
   | `/minio/users/longhorn` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

4. Make sure the TLS Secret (for example `prod-raulstechtips-tls`) is available in
   namespace `harbor`.
5. Publish the chart to GHCR through CI. Set `targetRevision` in
   `cluster-config/argo/dev/harbor.yaml` to the CI chart version.
6. When you adopt an existing install, do the steps in Adoption notes first.
7. Sync the Application manually. Check that the StaticSecrets have synced, all
   Deployments are healthy, you can log in, and `docker login` / `docker push` work.

## Values reference

| Key | Use |
| --- | --- |
| `infisical.authRef` | Existing InfisicalAuth name and namespace |
| `infisical.projectSlug`, `environmentSlug` | Environment connection |
| `adminSecret`, `secretKey`, `registrySecret`, `s3Secret` | Enabled switch, target name, path, recursive flag, refresh interval, key mapping |
| `redisSecret` | Enabled switch, target name, path, recursive flag, refresh interval, and the Infisical key of the Redis password |
| `ingressRoute` | Enabled switch, host, TLS Secret, entry points, class, middlewares |
| `harbor` | Values passed unchanged to the dependency |

Wrapper features are off by default. `cluster-config/apps/dev/harbor.yaml` enables
them and gives the environment values: host, external URL, S3 bucket and endpoint,
and database host. No secret values are stored in these files. The CI values use
fake connection names and `example.test` hosts.

The dependency values contain only differences from upstream defaults. The images
use the full `docker.io/` name, because the live Deployments use it.

## Redis password

Harbor puts the Redis password into the Redis URLs in its ConfigMaps. With
`redis.external.existingSecret`, the chart reads the Secret with `lookup`. Argo CD
renders without cluster access, so `lookup` returns nothing. It also makes
`helm lint --strict` fail. Thus this chart does not set a Redis password or
`existingSecret` in the dependency values. The ConfigMaps hold URLs with no password.

`templates/redis-secret.yaml` makes the Secret `harbor-redis-secret` with these keys:

| Key | Read by |
| --- | --- |
| `REDIS_PASSWORD` | registry and registryctl (`REGISTRY_REDIS_PASSWORD`), and the `redis-harbor` server |
| `_REDIS_URL_CORE` | core and jobservice |
| `_REDIS_URL_REG` | core |
| `JOB_SERVICE_POOL_REDIS_URL` | jobservice (overrides `redis_url` in its `config.yml`) |

The Deployments read these keys through `extraEnvVars`. A Kubernetes `env` entry
takes precedence over the same key from `envFrom`, so these values replace the
URLs from the ConfigMaps. The URL addresses and database indexes come from
`harbor.redis.external`. If you change them there, the Secret follows.

When you replace `redis-harbor` with a Redis that has Sentinel, change
`harbor.redis.external` and the URL format in `templates/redis-secret.yaml` together.

## Upgrades

Change the pinned dependency version in `charts/Chart.yaml`, run
`/opt/homebrew/bin/helm dependency update charts`, and keep `charts/Chart.lock`.
Review the upstream default images and all changed defaults. Check that the new
Harbor version still reads `_REDIS_URL_CORE`, `_REDIS_URL_REG` and
`JOB_SERVICE_POOL_REDIS_URL` from the environment. Run the wrapper checks, then
render with the apps/dev values and compare to live. CI publishes to GHCR and
updates the Argo chart version. Sync stays manual.

## Adoption notes

The local evidence is in `.omo/evidence/wrappers/harbor/` in the HomeLab workspace.

Old InfisicalSecrets own the live Secrets (`creationPolicy: Owner`). If Argo prunes
them, Kubernetes also deletes the Secrets, and Harbor stops. Before the first sync,
delete them with orphan deletion so that the Secrets stay:

```sh
kubectl delete infisicalsecret -n harbor --cascade=orphan \
  infisical-secret-harbor-admin-credentials-secret \
  infisical-secret-harbor-secret-key \
  infisical-secret-harbor-registry-secret \
  infisical-secret-harbor-s3-secret \
  infisical-secret-harbor-redis-secret
```

`infisical-secret-harbor-redis-secret` was applied by hand. No Argo app tracks it.

The new StaticSecrets use the live Secret names, paths, keys and Opaque type, with
`creationPolicy: Orphan` and a 60-second refresh. `harbor-redis-secret` gets three
new URL keys. `redis-harbor` still reads only `REDIS_PASSWORD`.

The Application keeps the live name, release name, namespace, history limit, and
`ignoreDifferences`. The upstream chart makes random values for `harbor-core`,
`harbor-jobservice`, `harbor-registry` and `harbor-registryctl` Secrets and for the
checksum annotations at each render.

Expected differences from live:

- 5 NEW StaticSecrets, and 4 old tracked InfisicalSecrets to PRUNE (orphan-delete
  them first).
- The 3 Redis URLs in `harbor-core` and `harbor-jobservice-env`, the jobservice
  `config.yml` URL, and the registry `config.yml` password line no longer hold the
  password.
- New `env` entries for the Redis URLs in core and jobservice, and
  `REGISTRY_REDIS_PASSWORD` in the registry container (registryctl already has it).
- Wrapper labels on the IngressRoute.
- None for replicas: the chart default is 3 for core, jobservice, portal and
  registry, and `apps/dev/harbor.yaml` sets 2 to match live.

The Redis password was stored in ConfigMaps before this change. Think about
changing it in Infisical after the move. Then restart `redis-harbor` and Harbor.
