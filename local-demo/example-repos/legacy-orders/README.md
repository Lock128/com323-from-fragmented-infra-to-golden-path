# legacy-orders (PHP)

An **existing** service that predates the lockhead.cloud platform. It's a small
PHP (Apache) app with its own Helm chart — exactly the kind of brownfield service
a team already has in Git.

It is **not** scaffolded by the golden path. During the demo it's seeded into
Gitea at cluster start (`seed-example-repos.sh`, run by `start.sh`), then onboarded
through the **"Onboard an existing service"** path — you point the platform at this
repo and declare one `Service` CR. The same Crossplane Composition provisions the
Argo CD Application and the security / SRE / reporting registrations.

```
app/            PHP source (index.php — a tiny orders API)
Dockerfile      php:8.3-apache image
chart/          Helm chart that deploys the service
catalog-info.yaml   Backstage catalog entry (so register picks it up)
.gitea/workflows/ci.yaml   the CI the team already had
```

Onboard it:

```bash
# scripted / GitOps
./demo/onboard-existing.sh                 # defaults to this repo (legacy-orders)
# or via the portal: Create → "Onboard an existing service"
```
