#!/usr/bin/env bash
# Post JUnit XML reports to Catalio's test-run ingest (POST /api/v1/test-runs).
#
# Observability only: this script always exits 0, so a Catalio outage, a bad
# credential or a missing report can never turn a green build red.
#
# Configured entirely by environment (action.yml maps its inputs onto these):
#   CATALIO_CLIENT_ID / CATALIO_CLIENT_SECRET  repository-scoped API credential
#   CATALIO_REPORTS        whitespace-separated globs; ** recurses
#   CATALIO_SUITE          optional; otherwise each report's file name is sent
#   CATALIO_APP_VERSION    optional; otherwise tag ref, git describe, package.json,
#                          mix.exs, then "unknown"
#   CATALIO_RUN_KEY        optional; disambiguates matrix jobs whose reports share
#                          a file name
#   CATALIO_API_BASE_URL   default https://app.catalio.ai
# plus the usual GITHUB_* variables for commit, branch, PR and run link.
set +e
shopt -s nullglob globstar

log() { printf 'catalio-test-report: %s\n' "$*" >&2; }

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}" 2> /dev/null
  fi
}

base_url="${CATALIO_API_BASE_URL:-}"
base_url="${base_url:-https://app.catalio.ai}"
base_url="${base_url%/}"
client_id="${CATALIO_CLIENT_ID:-}"
client_secret="${CATALIO_CLIENT_SECRET:-}"
patterns="${CATALIO_REPORTS:-**/TEST-*.xml **/junit*.xml}"

# Split on any whitespace, newlines included (a YAML `|` block puts one glob per
# line), with globbing off; then expand each pattern once, so a file matched by
# two patterns is posted once.
set -f
read -r -a pattern_list <<< "${patterns//$'\n'/ }"
set +f

declare -A seen=()
xml_files=()
for pattern in "${pattern_list[@]}"; do
  for file in ${pattern}; do
    case "${file}" in
      node_modules/* | */node_modules/* | deps/* | */deps/* | _build/* | */_build/*) continue ;;
    esac
    if [ -f "${file}" ] && [ -z "${seen[${file}]:-}" ]; then
      seen["${file}"]=1
      xml_files+=("${file}")
    fi
  done
done

if [ ${#xml_files[@]} -eq 0 ]; then
  log "no reports match ${patterns}; skipping ingest"
  summary "Catalio: no JUnit reports matched \`${patterns}\`."
  exit 0
fi

if [ -z "${client_id}" ] || [ -z "${client_secret}" ]; then
  log "client-id/client-secret not set; skipping ingest"
  summary "Catalio: credentials not set, ${#xml_files[@]} report(s) not posted."
  exit 0
fi

# Prints the first "version" string value in a JSON or Elixir project file.
file_version() {
  sed -n -E "$2" "$1" 2> /dev/null | head -n 1
}

detect_app_version() {
  if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    printf '%s' "${GITHUB_REF_NAME}"
    return
  fi

  local described
  described="$(git describe --tags 2> /dev/null)"
  if [ -n "${described}" ]; then
    printf '%s' "${described}"
    return
  fi

  local version=""
  [ -f package.json ] &&
    version="$(file_version package.json 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
  [ -z "${version}" ] && [ -f mix.exs ] &&
    version="$(file_version mix.exs 's/^[[:space:]]*version:[[:space:]]*"([^"]+)".*/\1/p')"
  printf '%s' "${version:-unknown}"
}

app_version="${CATALIO_APP_VERSION:-}"
[ -z "${app_version}" ] && app_version="$(detect_app_version)"

pr_number="${GITHUB_PR_NUMBER:-}"
if [ -z "${pr_number}" ]; then
  pr_number="$(printf '%s' "${GITHUB_REF:-}" | sed -n 's#refs/pull/\([0-9]*\)/.*#\1#p')"
fi

commit_sha="$(printf '%s' "${GITHUB_SHA:-}" | cut -c1-40)"
branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"

run_url=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

# jq when the runner has it; a sed fallback keeps self-hosted runners without jq working.
access_token() {
  if command -v jq > /dev/null 2>&1; then
    jq -r '.access_token // empty' "$1" 2> /dev/null
  else
    sed -n -E 's/.*"access_token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1"
  fi
}

# The secret and the bearer token go to curl through 0600 files, never as
# arguments, which any local user can read from the process list.
work="$(umask 077 && mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf '%s' "${client_secret}" > "${work}/secret"

# Bounded, so an endpoint that accepts the connection and then stalls can't
# hold the job open.
curl_opts=(-sS --connect-timeout 10 --max-time 120)

token_http="$(
  curl "${curl_opts[@]}" -o "${work}/token.json" -w '%{http_code}' -X POST "${base_url}/oauth/token" \
    -H "Accept: application/json" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret@${work}/secret"
)"
token="$(access_token "${work}/token.json")"
if [ -z "${token}" ]; then
  log "token exchange failed (HTTP ${token_http}); skipping ingest"
  summary "Catalio: token exchange failed (HTTP ${token_http}), ${#xml_files[@]} report(s) not posted."
  exit 0
fi

printf 'Authorization: Bearer %s\n' "${token}" > "${work}/auth-header"

posted=0
for xml in "${xml_files[@]}"; do
  stem="$(basename "${xml}" .xml)"
  suite="${CATALIO_SUITE:-${stem}}"
  # The report's path as is, not just its name, so unit/junit.xml and
  # integration/junit.xml in one job stay separate runs. Rewriting the slashes
  # would let a-b/junit.xml and a/b/junit.xml collide.
  report_key="${xml#./}"
  report_key="${report_key%.xml}"
  external_run_id="${GITHUB_RUN_ID:-local}-${CATALIO_RUN_KEY:+${CATALIO_RUN_KEY}-}${report_key}"
  log "posting ${xml} suite=${suite} app_version=${app_version}"
  http_code="$(
    curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' -X POST "${base_url}/api/v1/test-runs" \
      -H "@${work}/auth-header" \
      -F "suite=${suite}" \
      -F "source=github-actions" \
      -F "repo=${GITHUB_REPOSITORY:-}" \
      -F "external_run_id=${external_run_id}" \
      -F "commit_sha=${commit_sha}" \
      -F "pr_number=${pr_number}" \
      -F "branch=${branch}" \
      -F "external_run_url=${run_url}" \
      -F "app_version=${app_version}" \
      -F "report=@${xml}"
  )"
  log "HTTP ${http_code} for ${xml}"
  case "${http_code}" in
    2??) posted=$((posted + 1)) ;;
  esac
done

summary "Catalio: posted ${posted} of ${#xml_files[@]} report(s) (app version \`${app_version}\`)."
exit 0
