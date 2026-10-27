#!/usr/bin/env bats
#
# post.sh must never fail the caller, whatever state Catalio or the report is in.

setup() {
  SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/post.sh"
  DIR="$(mktemp -d)"
  cd "${DIR}" || exit 1
}

teardown() {
  rm -rf "${DIR}"
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
