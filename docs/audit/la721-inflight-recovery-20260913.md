# Los Angeles 7.2.1 interrupted firewall transaction

## Observed incident

The affected primary server is `DMIT-4AcBKDwTCc` (Ubuntu 24.04). The owner's
2026-09-13 15:07 UTC read-only diagnostic reports RR 7.2.1. The reported runtime
hashes match the official 7.2.1 bundle; the new recovery operation must verify
the complete installed manifest before using any installed helper.

At 14:48:23 UTC the firewall writer saved a `firewall-inflight-v1` record. It
recorded Sing-box and Nexus as active/enabled and the standalone subscription
server as running. The health timer was already inactive/disabled. Systemd
logs show the quarantine guard stopping Sing-box at 14:48:24. Repeated guard
activation then reached the service/path start limit.

The diagnostic establishes that all four complete live IPv4/IPv6 filter/NAT
programs equal the saved pre-operation programs. The current configuration
digest equals the digest sealed with that evidence. Its lock scan found no
matching open descriptors or kernel lock owners; this observation is not a
substitute for acquiring the actual locks during recovery. Saved persistence
files were fingerprinted, not compared semantically with live rules.

The September 7 update transaction is committed, with its firewall-finalize
completion record present. The September 13 interruption is a separate
firewall transaction. Connection EOF messages preceding the stop do not
establish the cause of the service stop.

## Confirmed code problems and limits

The 7.2.1 main menu runs a health check. For each enabled nonempty hopping
configuration that check unconditionally calls `install_hop_rules`. The
firewall transaction stops ingress even when the existing rules are correct.
LA has enabled HY2 hopping. This makes ordinary menu entry capable of entering
the disruptive transaction path.

The guard uses a `PathExists` unit and a oneshot service. The marker remains
present when the guard exits; the path therefore triggers it again. The
owner's systemd logs confirm repeated activation and start-limit failure.
The old systemctl fixtures did not model this path-trigger behavior.

The evidence does not establish exactly why the original writer exited before
settling its in-flight record. Do not describe its exit cause as proved, or
describe the health-only patch as a fix for every firewall writer failure.

## Recovery contract

The dedicated helper is for this fingerprinted 7.2.1 incident. It must acquire
the real update and firewall locks, recheck the recorded state, back up local
evidence and identities, and verify service startup requirements before
ending the orphaned operation. It must not impersonate the old writer PID,
convert an unverified record to another recovery format, rebuild firewall
rules, save a new persistence file, or regenerate subscriptions or credentials.

The prevention patch changes only health-check hop handling: the real
validator observes the configured rules in a subshell. A validation failure
is reported without invoking a firewall writer or stopping ingress. The
patched file has a separately recorded digest; the official manifest is not
rewritten to disguise the emergency patch as pristine release bytes.

Successful recovery restores the recorded Sing-box/Nexus enablement and
running state and the existing local subscription server. The health timer
remains disabled as recorded. Rule programs, persistence files and identity
configuration must remain unchanged. A failed attempt must preserve evidence
and report its precise phase and any uncertain cleanup.

## Release boundary

The current formal v7.2.5 uses the same faulty health module as v7.2.1. Updating
a locally patched host to v7.2.5 would overwrite this prevention patch. Do not
recommend that update as the solution to this incident. A later formal
release must integrate the permanent corrections and satisfy its applicable
release gates; publishing this dedicated recovery helper is not that release.

The recovery branch does not move `main`, the Latest release, or existing
immutable tags. No live server access is available to the implementers. Local
regression tests cannot be reported as a successful production recovery; the
owner's eventual execution output is the production result.
