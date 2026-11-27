#!/usr/bin/env bash
# codecommit-setup.sh: local git access to the managed IDP's CodeCommit repos.
#
# Configures git (globally, but only for the CodeCommit host of the region in
# cdk.json) to get credentials from the AWS CLI with your SSO profile:
#
#   credential.https://git-codecommit.<region>.amazonaws.com.helper = ''   (drops osxkeychain etc.)
#   credential.https://git-codecommit.<region>.amazonaws.com.helper = !aws --profile <p> codecommit credential-helper $@
#   credential.https://git-codecommit.<region>.amazonaws.com.UseHttpPath = true
#
# The empty helper matters on macOS: the keychain would cache the temporary
# credentials and git fails with 403 once they expire.
#
# Usage: ./scripts/codecommit-setup.sh [command]
#   setup        (default) configure git and verify access
#   check        show the config and verify access, change nothing
#   clone [dir]  setup, then clone the platform repo
#                (default dir: next to this git repository, ../<repo>)
#   remove       remove the config for the CodeCommit host
#
# Overrides (environment variables):
#   CODECOMMIT_PROFILE   AWS profile (default: $AWS_PROFILE, else default)
#   MANAGED_IDP_REGION   region (default: managedIdp.region in cdk.json)
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

COMMAND="${1:-setup}"
PROFILE="${CODECOMMIT_PROFILE:-${AWS_PROFILE:-$DEFAULT_PROFILE}}"
REGION="${MANAGED_IDP_REGION:-$(cfg region us-west-2)}"
REPO="$(cfg repositoryName lockheadcloud-managed-platform)"
HOST="https://git-codecommit.${REGION}.amazonaws.com"
KEY="credential.${HOST}"
REPO_URL="${HOST}/v1/repos/${REPO}"

for tool in aws git node; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed or not on PATH."
done
# The profile ends up inside a git config value that git runs through a shell.
[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unexpected characters in profile name: $PROFILE"
[[ "$REGION" =~ ^[a-z0-9-]+$ ]] || die "Unexpected region: $REGION"

ensure_login() {
  if aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
    return
  fi
  info "No valid credentials for profile $PROFILE, starting SSO login..."
  aws sso login --profile "$PROFILE"
  aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1 \
    || die "Still no credentials for profile $PROFILE."
}

show_config() {
  echo "  profile: $PROFILE"
  echo "  region:  $REGION"
  echo "  host:    $HOST"
  local helpers
  helpers="$(git config --global --get-all "$KEY.helper" 2>/dev/null || true)"
  if [[ -z "$helpers" ]]; then
    echo "  git:     not configured for this host"
  else
    echo "  git:     helper entries for this host:"
    while IFS= read -r line; do echo "             '${line}'"; done <<<"$helpers"
    echo "           UseHttpPath = $(git config --global --get "$KEY.UseHttpPath" 2>/dev/null || echo unset)"
  fi
}

configure() {
  info "Configuring git credentials for $HOST"
  git config --global --unset-all "$KEY.helper" 2>/dev/null || true
  git config --global "$KEY.helper" ''
  git config --global --add "$KEY.helper" "!aws --profile ${PROFILE} codecommit credential-helper \$@"
  git config --global "$KEY.UseHttpPath" true
  success "Global git config updated (only for $HOST)"
}

# Authenticates against the platform repo. A missing repo still proves that
# authentication works (CodeCommit answers 404 instead of 403).
# Sets REPO_EXISTS=true|false.
REPO_EXISTS=false
verify() {
  info "Verifying access to $REPO_URL"
  local out
  if out="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$REPO_URL" 2>&1)"; then
    REPO_EXISTS=true
    success "Authenticated, and $REPO is reachable ($(grep -c . <<<"$out") refs)."
  elif grep -qiE "not found|does not exist" <<<"$out"; then
    success "Authenticated. $REPO does not exist yet (deploy the stacks first)."
  else
    echo "$out" | tail -3 >&2
    die "Access failed. Run '$0 check', and 'aws sso login --profile $PROFILE' if the session expired."
  fi
}

case "$COMMAND" in
  setup)
    ensure_login
    configure
    verify
    echo "Clone with:  git clone $REPO_URL"
    ;;
  check)
    show_config
    ensure_login
    verify
    ;;
  clone)
    ensure_login
    configure
    verify
    [[ "$REPO_EXISTS" == true ]] || die "Nothing to clone yet: deploy the stacks first (npx cdk deploy --all)."
    TOPLEVEL="$(git -C "$APP_DIR" rev-parse --show-toplevel)"
    TARGET="${2:-$(dirname "$TOPLEVEL")/$REPO}"
    [[ -e "$TARGET" ]] && die "$TARGET already exists."
    info "Cloning into $TARGET"
    git clone "$REPO_URL" "$TARGET"
    success "Cloned. Edit backstage/template.yaml, crds/ or apis/, then commit and push."
    ;;
  remove)
    git config --global --unset-all "$KEY.helper" 2>/dev/null || true
    git config --global --unset-all "$KEY.UseHttpPath" 2>/dev/null || true
    git config --global --remove-section "$KEY" 2>/dev/null || true
    success "Removed git credential config for $HOST"
    ;;
  *)
    die "Unknown command: $COMMAND (use setup | check | clone [dir] | remove)"
    ;;
esac
