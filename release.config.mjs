// How a chart release is decided and what it is called (charts/lembos/README.md#releases).
//
// Every commit on main that passes the Chart workflow is a candidate: the version comes from the conventional
// commit prefixes since the last tag — feat is a minor, fix and perf a patch, BREAKING CHANGE a major — and a
// main with none of those since the last tag releases nothing. So a Dependabot bump (chore) or a docs change
// never cuts a chart, and adopting a platform release does when it is committed as the fix or feat it is.
//
// The plugins are named in full rather than taken from the default list, because the default list includes
// npm, and this repository publishes a Helm chart, not a package.
export default {
  branches: ["main"],
  tagFormat: "v${version}",
  plugins: [
    "@semantic-release/commit-analyzer",
    [
      "@semantic-release/exec",
      {
        // The version the workflow packages the chart as, written where a later step can read it. Runs in a
        // dry run too, which is how the workflow learns the number without tagging anything. No shell `${…}`
        // here: the plugin renders the command as a lodash template, which takes every one as JavaScript.
        verifyReleaseCmd:
          "[ -z \"$GITHUB_OUTPUT\" ] || printf 'version=%s\\n' '${nextRelease.version}' >> \"$GITHUB_OUTPUT\"",
        // Ahead of the generated notes, so a release page opens on how to install it. APP_VERSION is the
        // workflow's, read from Chart.yaml.
        generateNotesCmd:
          "printf '## Install\\n\\n```shell\\nhelm upgrade --install lembos oci://ghcr.io/lembosproj/charts/lembos --version %s \\\\\\n  --namespace lembos --create-namespace --set global.domain=<your domain>\\n```\\n\\nInstalls Lembos %s: `ghcr.io/lembosproj/platform/{identity,orchestrator,portal,worker,setup}:%s`\\n' '${nextRelease.version}' \"$APP_VERSION\" \"$APP_VERSION\"",
      },
    ],
    "@semantic-release/release-notes-generator",
    [
      "@semantic-release/github",
      {
        // No comments on issues and pull requests: they need write permissions on both for a line nobody
        // asked for, and the release notes already link every commit.
        successCommentCondition: false,
        failCommentCondition: false,
        releasedLabels: false,
        assets: [{ path: "dist/lembos-*.tgz", label: "Helm chart" }],
      },
    ],
  ],
};
