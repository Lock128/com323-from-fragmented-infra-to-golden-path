# shellcheck shell=bash
# Shared by the scripts in this folder: reads settings from cdk.json
# (context.managedIdp) so region, cluster and repo names are defined once.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/config.sh"; cfg region

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# cfg <key> [default]: value of context.managedIdp.<key> in cdk.json, overridden
# by managedIdp.<key> in the gitignored cdk.local.json (your own values).
cfg() {
  node -e '
    const fs = require("fs");
    const local = process.argv[1].replace(/cdk\.json$/, "cdk.local.json");
    const c = { ...(require(process.argv[1]).context.managedIdp ?? {}),
                ...(fs.existsSync(local) ? JSON.parse(fs.readFileSync(local, "utf8")).managedIdp ?? {} : {}) };
    const v = c[process.argv[2]];
    process.stdout.write(v === undefined || v === "" ? (process.argv[3] ?? "") : String(v));
  ' "$APP_DIR/cdk.json" "$1" "${2:-}"
}

# cdkjson <key> [<key>...]: value at that key path in cdk.json,
# e.g. cdkjson context @aws-cdk/core:bootstrapQualifier
cdkjson() {
  node -e '
    let v = require(process.argv[1]);
    for (const k of process.argv.slice(2)) v = v == null ? undefined : v[k];
    process.stdout.write(v == null ? "" : String(v));
  ' "$APP_DIR/cdk.json" "$@"
}

# Own CDK bootstrap (stack, assets bucket, ECR repo, deploy roles), separate
# from the self-hosted variant's default CDKToolkit.
# shellcheck disable=SC2034  # used by the scripts that source this file
TOOLKIT_STACK="$(cdkjson toolkitStackName)"
# shellcheck disable=SC2034
BOOTSTRAP_QUALIFIER="$(cdkjson context @aws-cdk/core:bootstrapQualifier)"

# shellcheck disable=SC2034  # used by the scripts that source this file
DEFAULT_PROFILE="default"
