# Harbor wrapper chart

## Purpose

Install upstream Harbor chart 1.18.0, application 2.14.0, without changes to its
templates. Add five InfisicalStaticSecrets and the existing Traefik IngressRoute.
Harbor uses external PostgreSQL (`pg-prod` CNPG cluster) and S3 storage (MinIO).
This wrapper also installs our custom Redis chart from
`oci://ghcr.io/raulstechtips/charts/redis`, pinned to
`0.1.0-feature-devsecops-190-087d631-8eb3efb-5`.
The upstream Harbor Redis remains disabled (`harbor.redis.type: external`).

## Before first install

1. Make sure these exist: the Infisical operator with its v1beta1 StaticSecret CRD,
   Traefik, and `default/infisical-prod-universal-auth`.
2. Make sure the external services are ready:
   - PostgreSQL has an empty `registry` database and the user `pg-harbor-admin`.
     The Secret `pg-harbor-database-credentials-secret` (key `password`) exists in
     namespace `harbor`.
   - The S3 bucket exists.
   - The Secret `harbor-redis-secret` has key `REDIS_PASSWORD`, or
     `redisSecret.enabled: true` synchronizes it from Infisical `/harbor/redis`.
     Harbor and the new Redis pod use this same credential source.
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
| `redis` | Custom Redis dependency; standalone, existing credential Secret, TLS disabled |

Secret sync and routing are off by default. Redis is installed by default.
`cluster-config/apps/dev/harbor.yaml` enables
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
| `REDIS_PASSWORD` | registry and registryctl (`REGISTRY_REDIS_PASSWORD`), and the bundled Redis server |
| `_REDIS_URL_CORE` | core and jobservice |
| `_REDIS_URL_REG` | core |
| `JOB_SERVICE_POOL_REDIS_URL` | jobservice (overrides `redis_url` in its `config.yml`) |

The Deployments read these keys through `extraEnvVars`. A Kubernetes `env` entry
takes precedence over the same key from `envFrom`, so these values replace the
URLs from the ConfigMaps. The URL addresses and database indexes come from
`harbor.redis.external`. If you change them there, the Secret follows.

## Bundled Redis

The initial integration uses one standalone Redis pod with persistent storage.
There are no Sentinel pods or Sentinel volumes. TLS is disabled for this internal
Harbor connection. The client Service is `harbor-redis` on port `6379`, in the
Harbor release namespace. `redis.fullnameOverride` fixes this Service name;
keep it and `harbor.redis.external.addr` in agreement if you change either value.
Do not use the old `redis-harbor-master` endpoint in environment overrides.

Redis mounts `harbor-redis-secret` key `REDIS_PASSWORD` as its password file.
The dependency does not generate another password or create another Infisical
sync. Leave `redis.auth.infisical.enabled` disabled. If you change the credential
Secret name, also update `redisSecret.secretName`, `redis.auth.existingSecret`,
and every Harbor `extraEnvVars` Secret reference.

The Redis NetworkPolicy permits same-namespace clients with
`app.kubernetes.io/instance` equal to the release name. The upstream Harbor core,
jobservice and registry pod templates carry this label. No extra namespace-wide
allow rule is needed. A separate client egress policy must also permit TCP 6379.

This wrapper does not configure Sentinel clients. A later Sentinel integration
must update Harbor's address, master set and authenticated URL format together.
The master set must match the Redis dependency's release-derived master name.

This change does not migrate data, stop the old Redis release, or change the live
cluster. Plan those operations separately before deploying over an existing
Harbor install.

## Local checks

Authenticate Helm to GHCR with an account that can read the pinned package.
Do not put a registry token in a command argument or a values file.

```sh
helm dependency update charts --skip-refresh
helm unittest charts
helm lint charts --strict
helm lint charts --strict -f charts/ci/all-on-values.yaml
helm template harbor charts --namespace harbor -f charts/ci/all-on-values.yaml \
  | kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -skip InfisicalSecret,InfisicalStaticSecret,InfisicalPushSecret,CustomResourceDefinition
```

The unit tests check the Redis endpoint, single pod, shared password mount,
plaintext connection, NetworkPolicy and Harbor Secret references. The values
schema is checked by Helm lint and template.

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
new URL keys. The bundled Redis reads only `REDIS_PASSWORD`.

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

The Redis password was stored in ConfigMaps before the Secret-based wiring.
Plan any later password change in Infisical together with a restart of Redis
and Harbor.
