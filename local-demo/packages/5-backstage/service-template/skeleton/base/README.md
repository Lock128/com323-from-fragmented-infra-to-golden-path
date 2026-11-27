# ${{ values.name }}

> Scaffolded by the **lockhead.cloud** platform golden path.
> Owner: `${{ values.team }}` · Language: `${{ values.language }}` · Tier: `${{ values.tier }}`

This repository was created automatically when the service was onboarded through
the internal developer portal. You did not have to write the Dockerfile, the Helm
chart, or the CI/CD pipeline — the platform did. The app under `app/` is a
`${{ values.language }}` starter that serves a small branded page plus
`/healthz` and `/api`.

## What the platform set up for you

| Thing | Where |
| --- | --- |
| App source (`${{ values.language }}`) | `app/` |
| Container build | `Dockerfile` |
| Deployable Helm chart | `chart/` |
| CI/CD pipeline | `.gitea/workflows/ci.yaml` |
| Catalog registration | `catalog-info.yaml` |

## What happens on push

1. The CI pipeline builds and (in a real cluster) pushes the image.
2. Argo CD — provisioned for you by the platform — deploys `chart/` into your
   team namespace `team-${{ values.team }}`.
3. The service is already registered with security scanning, SRE on-call, and
   the central service report.

## Accessing it

The chart exposes the service through the cluster ingress at:

```
https://${{ values.name }}.cnoe.localtest.me:8543
```

(or `kubectl port-forward -n team-${{ values.team }} svc/${{ values.name }} 8080:80`).
