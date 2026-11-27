#!/bin/sh
# Creates the CodeCommit repo for a new service and commits the rendered
# golden-path skeleton as its first commit. Run as a Job by the Backstage
# "Onboard a new service" template (the CodeCommit stand-in for publish:gitea).
#
# Inputs (env): NAME, TEAM, LANGUAGE, TIER, REPO_PREFIX, AWS_REGION
# Skeleton:     /skeleton, one file per ConfigMap key, "/" encoded as "__",
#               prefixed "base__" (shared) or "langs__<language>__".
# AWS access:   EKS Pod Identity (service account repo-scaffolder).
#
# Idempotent: an existing repo is reused, and a repo whose main branch already
# exists is left untouched.
set -eu

# Validate inputs at the trust boundary (they end up in sed and JSON).
case "$NAME" in ''|*[!a-z0-9-]*) echo "invalid NAME: $NAME" >&2; exit 2;; esac
case "$TEAM" in ''|*[!a-z0-9-]*) echo "invalid TEAM: $TEAM" >&2; exit 2;; esac
case "$LANGUAGE" in go|node|python|php) ;; *) echo "invalid LANGUAGE: $LANGUAGE" >&2; exit 2;; esac
case "$TIER" in experimental|standard|critical) ;; *) echo "invalid TIER: $TIER" >&2; exit 2;; esac

REPO="${REPO_PREFIX}${NAME}"
SKELETON="${SKELETON_DIR:-/skeleton}"

if aws codecommit get-repository --repository-name "$REPO" >/dev/null 2>&1; then
  echo "repository $REPO exists"
else
  echo "creating repository $REPO"
  aws codecommit create-repository \
    --repository-name "$REPO" \
    --repository-description "$NAME, onboarded via the lockhead.cloud golden path" \
    --tags "lockhead.cloud/team=$TEAM,lockhead.cloud/service=$NAME" >/dev/null
fi

if aws codecommit get-branch --repository-name "$REPO" --branch-name main >/dev/null 2>&1; then
  echo "branch main already exists, nothing to scaffold"
  exit 0
fi

render() {
  sed -e "s/\${{ *values\.name *}}/$NAME/g" \
      -e "s/\${{ *values\.team *}}/$TEAM/g" \
      -e "s/\${{ *values\.language *}}/$LANGUAGE/g" \
      -e "s/\${{ *values\.tier *}}/$TIER/g" "$1"
}

OUT=/tmp/commit.json
printf '{"repositoryName":"%s","branchName":"main","authorName":"lockhead.cloud platform","email":"platform@lockhead.cloud","commitMessage":"Initial scaffold from lockhead.cloud golden path","putFiles":[' "$REPO" > "$OUT"
first=1
count=0
for f in "$SKELETON"/base__* "$SKELETON"/langs__"$LANGUAGE"__*; do
  [ -f "$f" ] || continue
  key=$(basename "$f")
  path=$(printf '%s' "$key" | sed -e 's/^base__//' -e "s/^langs__${LANGUAGE}__//" -e 's/__/\//g')
  content=$(render "$f" | base64 -w0)
  [ "$first" = 1 ] || printf ',' >> "$OUT"
  first=0
  count=$((count + 1))
  printf '{"filePath":"%s","fileContent":"%s"}' "$path" "$content" >> "$OUT"
done
printf ']}' >> "$OUT"

echo "committing $count files to $REPO/main"
aws codecommit create-commit --cli-input-json "file://$OUT" --query commitId --output text
