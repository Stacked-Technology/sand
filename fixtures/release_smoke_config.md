# Sand release smoke config

`release_smoke_config.json` is the restricted input contract for
`scripts/release-smoke.sh`. It is intentionally JSON (accepted by Sand's YAML
decoder) so the harness can validate the full object before starting anything.

The object must contain exactly one runner whose VM name and
`provisioner.config.runnerName` are the same `sand-release-smoke-*` value. The
runner uses `stopAfter: 1`, a pinned OCI image, no pool, mounts, cache, or
repository scope, and an organization-level GitHub provisioner with
`ephemeral: true`. `extraLabels` must be exactly `sand-release-smoke` and the
unique per-run `sand-release-smoke-*` label. Supply a real private-key path only
when running a smoke; the checked-in fixture uses `/dev/null` solely for the
non-network `sand validate` contract check.
