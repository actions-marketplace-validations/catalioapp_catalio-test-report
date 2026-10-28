# Catalio Test Report

Posts JUnit XML test results to [Catalio](https://catalio.ai), so the acceptance criteria your tests cover show whether those tests ran, passed, failed or were skipped on each commit.

The step never fails your build. If Catalio is unreachable, the credential is wrong, or no report is found, it logs why and exits 0.

## Setup

1. In Catalio, open **Settings → API Credentials → Create Credential**, choose the repository this workflow runs in, and copy the client ID and secret. Test results are only accepted from a credential scoped to the repository they come from.
2. Add them to the repository as the secrets `CATALIO_CLIENT_ID` and `CATALIO_CLIENT_SECRET`.
3. Add the step after your tests, with `if: always()` so failing runs are reported too:

```yaml
- name: Run tests
  run: npm test -- --reporters=default --reporters=jest-junit

- name: Report test results to Catalio
  if: always()
  uses: catalioapp/catalio-test-report@v1
  with:
    client-id: ${{ secrets.CATALIO_CLIENT_ID }}
    client-secret: ${{ secrets.CATALIO_CLIENT_SECRET }}
```

## Inputs

| Input           | Default                       | What it does                                                                                                                |
| --------------- | ----------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `client-id`     |                               | Client ID of a repository-scoped Catalio API credential                                                                     |
| `client-secret` |                               | Its secret                                                                                                                  |
| `reports`       | `**/TEST-*.xml **/junit*.xml` | Globs for the XML files to post, separated by spaces or newlines. `node_modules`, `deps` and `_build` are skipped at any depth |
| `suite`         | file name                     | `unit`, `integration`, `ui` or `e2e`. Unset, each file's name is sent and anything unrecognised is recorded as `e2e`        |
| `app-version`   | detected                      | The tag being built, then `git describe --tags`, then the `version` in `package.json` or `mix.exs`, then `unknown`          |
| `run-key`       |                               | Added to the run id. Set it in matrix jobs that write reports to the same path, or the second job's results replace the first's |
| `base-url`      | `https://catalio.ai`          | Your Catalio URL                                                                                                            |

Commit, branch, pull request number and a link back to the run come from the workflow context. On `pull_request` events the PR's head commit is used, not the merge commit GitHub builds.

## Linking tests to acceptance criteria

Catalio identifies a test by its file and name. To keep a test's history through renames and moves, start its name with the `CT-` id Catalio gives it, for example `CT-1042 rejects an expired token`.

## Requirements

Needs bash 4 or later and `curl`, which GitHub's Linux runners have. On macOS, `/bin/bash` is 3.2, so put a newer bash first on `PATH`. `jq` is used when present.
