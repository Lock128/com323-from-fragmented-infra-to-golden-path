# Security

This repository is demo code for a conference talk (AWS re:Invent 2026, COM323).
It is meant to run on your own machine and in an AWS account you control. It is
not hardened for production or shared environments.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately
through GitHub: **Security** tab of this repository → **Report a vulnerability**.
Include the affected file or script, how to reproduce it, and the impact you see.

You should get a first reply within a week. There are no releases with support
windows; fixes go to `main`.

Vulnerabilities in the projects this demo uses (CNOE idpbuilder, Backstage,
Argo CD, Crossplane, Gitea, kro, ACK and so on) belong with those projects.

## What the demo does on your machine

- **Dashboard action backend** (`local-demo/dashboard-server.py`). It runs shell
  commands, so read this before you start it:
  - It binds to `127.0.0.1` only. Do not expose it or put it behind a proxy.
  - It runs only an allowlist of this repository's own demo scripts, with their
    arguments validated. There is no "run any command" endpoint.
  - The kubectl box allows read verbs only (`get`, `describe`, `logs`, …).
    `DASH_ALLOW_KUBECTL_WRITE=1` lifts that; leave it unset.
  - Browser requests are accepted only from pages on `http://localhost` or
    `http://127.0.0.1`, and only with a `localhost` / `127.0.0.1` `Host`
    header. Other websites open in the same browser get `403`.
  - It has no authentication. Any program running as your user on the same
    machine can call it, as it can call `kubectl` directly.
- **`kubectl proxy`** (started by the `ui.sh` scripts) serves the dashboard pages
  and the Kubernetes API on `localhost` with your kubeconfig credentials, limited
  to `localhost` / `127.0.0.1` hosts. Stop it when you are done
  (`local-demo/target.sh stop all`).
- **kubeconfig files.** Each target has its own file under `~/.kube/`
  (mode `600`). `local-demo/target.sh reset` backs up `~/.kube/config` before
  changing it.
- **`eks-infrastructure-managed/scripts/codecommit-setup.sh`** changes your global
  git config, scoped to the CodeCommit host of one region. `remove` undoes it.

## Known demo shortcuts

These are deliberate and listed so nobody copies them into a real platform:

- Literal demo passwords for Gitea, Backstage/Dex, Postgres and Crossview.
- Argo CD serves plain HTTP behind a port-forward.
- Crossplane's `provider-kubernetes` is bound to `cluster-admin`, and the
  Backstage service account can read every resource in the cluster (it can
  write only `Service` claims and namespaces).
- The security, SRE and reporting "systems" are CRDs and ConfigMaps, not real
  integrations.

The [EKS README](./eks-infrastructure/README.md) lists what to change for a
real platform. The EKS variants create billable AWS resources; delete them with
their `scripts/delete.sh` when you are done.
