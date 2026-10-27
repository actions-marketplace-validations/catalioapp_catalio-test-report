#!/usr/bin/env bats
#
# post.sh must never fail the caller, whatever state Catalio or the report is in.

setup() {
  SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/post.sh"
  DIR="$(mktemp -d)"
  cd "${DIR}" || exit 1
}

teardown() {
  [ -n "${STUB_PID:-}" ] && kill "${STUB_PID}" 2> /dev/null
  rm -rf "${DIR}"
}

# Starts test/stub_server.py on a free port and sets BASE_URL to it.
start_stub() {
  python3 "$(dirname "${BATS_TEST_FILENAME}")/stub_server.py" "${DIR}" &
  STUB_PID=$!
  for _ in $(seq 50); do
    [ -s "${DIR}/port" ] && break
    sleep 0.1
  done
  BASE_URL="http://127.0.0.1:$(cat "${DIR}/port")"
}

# Runs post.sh with only the environment a test names, so the GITHUB_* values
# of the CI job running these tests can't leak in.
run_clean() {
  run env -i PATH="${PATH}" HOME="${HOME}" no_proxy='*' NO_PROXY='*' "$@" bash "${SCRIPT}"
}

@test "exits 0 when no report matches" {
  run env CATALIO_REPORTS="reports/*.xml" CATALIO_CLIENT_ID= CATALIO_CLIENT_SECRET= bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no reports match reports/*.xml; skipping ingest"* ]]
}

@test "exits 0 when credentials are missing" {
  mkdir reports && printf '<testsuites/>\n' > reports/unit.xml
  run env CATALIO_REPORTS="reports/*.xml" CATALIO_CLIENT_ID= CATALIO_CLIENT_SECRET= bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"client-id/client-secret not set; skipping ingest"* ]]
}

@test "exits 0 when the token endpoint is down" {
  mkdir reports && printf '<testsuites/>\n' > reports/unit.xml
  run env \
    CATALIO_REPORTS="reports/*.xml" \
    CATALIO_CLIENT_ID=client \
    CATALIO_CLIENT_SECRET=secret \
    CATALIO_APP_VERSION=0.1.0 \
    CATALIO_API_BASE_URL="http://127.0.0.1:1" \
    http_proxy= HTTP_PROXY= \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"token exchange failed (HTTP 000)"* ]]
}

@test "the default globs find TEST-*.xml and junit*.xml at any depth, skipping node_modules" {
  mkdir -p a/b node_modules/pkg
  printf '<testsuites/>\n' > a/b/TEST-com.example.FooTest.xml
  printf '<testsuites/>\n' > junit.xml
  printf '<testsuites/>\n' > node_modules/pkg/junit.xml
  run env -u CATALIO_REPORTS GITHUB_STEP_SUMMARY="${DIR}/summary.md" \
    CATALIO_CLIENT_ID= CATALIO_CLIENT_SECRET= bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat summary.md)" = "Catalio: credentials not set, 2 report(s) not posted." ]
}

@test "a file matched by two patterns counts once" {
  printf '<testsuites/>\n' > junit.xml
  run env CATALIO_REPORTS="*.xml junit*.xml" GITHUB_STEP_SUMMARY="${DIR}/summary.md" \
    CATALIO_CLIENT_ID= CATALIO_CLIENT_SECRET= bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat summary.md)" = "Catalio: credentials not set, 1 report(s) not posted." ]
}

@test "exits 0 when the token endpoint returns HTTP 500" {
  mkdir reports && printf '<testsuites/>\n' > reports/unit.xml
  STUB_TOKEN_STATUS=500 start_stub
  run_clean CATALIO_REPORTS="reports/*.xml" CATALIO_CLIENT_ID=client CATALIO_CLIENT_SECRET=secret \
    CATALIO_APP_VERSION=0.1.0 CATALIO_API_BASE_URL="${BASE_URL}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"token exchange failed (HTTP 500); skipping ingest"* ]]
}

@test "exits 0 when ingest returns HTTP 500 after a token" {
  mkdir reports && printf '<testsuites/>\n' > reports/unit.xml
  STUB_INGEST_STATUS=500 start_stub
  run_clean CATALIO_REPORTS="reports/*.xml" CATALIO_CLIENT_ID=client CATALIO_CLIENT_SECRET=secret \
    CATALIO_APP_VERSION=0.1.0 CATALIO_API_BASE_URL="${BASE_URL}" GITHUB_RUN_ID=99
  [ "$status" -eq 0 ]
  [[ "$output" != *"token exchange failed"* ]]
  [[ "$output" == *"catalio-test-report: HTTP 500 for reports/unit.xml"* ]]
}

@test "one POST per report, carrying the run's commit, branch, PR, link and version" {
  mkdir reports
  printf '<testsuites name="ui"/>\n' > reports/ui.xml
  printf '<testsuites name="unit"/>\n' > reports/unit-p2.xml
  sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  start_stub
  run_clean CATALIO_REPORTS="reports/*.xml" CATALIO_CLIENT_ID=client CATALIO_CLIENT_SECRET='s3cr&t=+' \
    CATALIO_APP_VERSION=0.1.0 CATALIO_API_BASE_URL="${BASE_URL}" CATALIO_RUN_KEY=linux \
    GITHUB_SHA="${sha}" GITHUB_PR_NUMBER=3967 GITHUB_HEAD_REF=feature/x \
    GITHUB_REPOSITORY=acme/widgets GITHUB_RUN_ID=1234 GITHUB_SERVER_URL=https://github.com \
    GITHUB_STEP_SUMMARY="${DIR}/summary.md"
  [ "$status" -eq 0 ]

  common="\"app_version\": \"0.1.0\", \"branch\": \"feature/x\", \"commit_sha\": \"${sha}\""
  url='"external_run_url": "https://github.com/acme/widgets/actions/runs/1234"'
  rest='"pr_number": "3967", "repo": "acme/widgets"'
  src='"source": "github-actions"'
  token='{"authorization": null, "fields": {"client_id": "client", "client_secret": "s3cr&t=+", "grant_type": "client_credentials"}, "path": "/oauth/token"}'
  ui="{\"authorization\": \"Bearer tok\", \"fields\": {${common}, \"external_run_id\": \"1234-linux-reports/ui\", ${url}, ${rest}, \"report\": \"ui.xml:<testsuites name=\\\"ui\\\"/>\", ${src}, \"suite\": \"ui\"}, \"path\": \"/api/v1/test-runs\"}"
  unit="{\"authorization\": \"Bearer tok\", \"fields\": {${common}, \"external_run_id\": \"1234-linux-reports/unit-p2\", ${url}, ${rest}, \"report\": \"unit-p2.xml:<testsuites name=\\\"unit\\\"/>\", ${src}, \"suite\": \"unit-p2\"}, \"path\": \"/api/v1/test-runs\"}"

  [ "$(cat requests.jsonl)" = "$(printf '%s\n%s\n%s' "${token}" "${ui}" "${unit}")" ]
  [ "$(cat summary.md)" = 'Catalio: posted 2 of 2 report(s) (app version `0.1.0`).' ]
}

@test "reports given one glob per line are all found" {
  mkdir unit integration
  printf '<testsuites/>\n' > unit/a.xml
  printf '<testsuites/>\n' > integration/b.xml
  run env CATALIO_REPORTS=$'unit/*.xml\nintegration/*.xml' GITHUB_STEP_SUMMARY="${DIR}/summary.md" \
    CATALIO_CLIENT_ID= CATALIO_CLIENT_SECRET= bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat summary.md)" = "Catalio: credentials not set, 2 report(s) not posted." ]
}

@test "deps and _build are skipped below the root too" {
  mkdir -p apps/web/deps/x apps/web/_build/test apps/web/test
  printf '<testsuites/>\n' > apps/web/deps/x/junit.xml
  printf '<testsuites/>\n' > apps/web/_build/test/junit.xml
  printf '<testsuites/>\n' > apps/web/test/junit.xml
  run env -u CATALIO_REPORTS GITHUB_STEP_SUMMARY="${DIR}/summary.md" \
    CATALIO_CLIENT_ID= CATALIO_CLIENT_SECRET= bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat summary.md)" = "Catalio: credentials not set, 1 report(s) not posted." ]
}

@test "reports with the same file name in different directories get different run ids" {
  mkdir unit integration
  printf '<testsuites/>\n' > unit/junit.xml
  printf '<testsuites/>\n' > integration/junit.xml
  start_stub
  run_clean CATALIO_REPORTS="*/junit.xml" CATALIO_CLIENT_ID=client CATALIO_CLIENT_SECRET=secret \
    CATALIO_APP_VERSION=0.1.0 CATALIO_API_BASE_URL="${BASE_URL}" GITHUB_RUN_ID=7
  [ "$status" -eq 0 ]
  ids="$(grep -o '"external_run_id": "[^"]*"' requests.jsonl)"
  [ "${ids}" = "$(printf '%s\n%s' '"external_run_id": "7-integration/junit"' '"external_run_id": "7-unit/junit"')" ]
}

@test "the client secret and bearer token never appear in curl's arguments" {
  mkdir reports && printf '<testsuites/>\n' > reports/unit.xml
  mkdir bin
  real_curl="$(command -v curl)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/curl-args"\nexec "%s" "$@"\n' "${DIR}" "${real_curl}" > bin/curl
  chmod +x bin/curl
  start_stub
  run env -i PATH="${DIR}/bin:${PATH}" HOME="${HOME}" no_proxy='*' NO_PROXY='*' \
    CATALIO_REPORTS="reports/*.xml" CATALIO_CLIENT_ID=client CATALIO_CLIENT_SECRET=hunter2 \
    CATALIO_APP_VERSION=0.1.0 CATALIO_API_BASE_URL="${BASE_URL}" bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(grep -c . curl-args)" -eq 2 ]
  # `! grep` can't fail a bats test (errexit ignores negated commands), so count.
  [ "$(grep -c -e hunter2 -e 'Bearer tok' curl-args)" -eq 0 ]
  [ "$(grep -c '"client_secret": "hunter2"' requests.jsonl)" -eq 1 ]
  [ "$(grep -c '"authorization": "Bearer tok"' requests.jsonl)" -eq 1 ]
}
