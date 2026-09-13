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
owner’s eventual execution output is the production result.

## Additional evidence: legacy TCP 22049 rule

The owner's first recovery attempt passed locks, all installed-file checks,
transaction state, byte-identical live rules and backup. It stopped before
service changes at the full desired-namespace check. The subsequent complete
rule listing matches all four diagnostic SHA256 values and is retained as a
test fixture. Replaying the actual 7.2.1 verifier reproduces the failure before
any per-port live check: each filter table contains one extra tagged ACCEPT
for TCP 22049, outside the current desired namespace.

Both INPUT policies are ACCEPT. All other INPUT rules in these exact programs
match individual, different ports; no broader matches or custom chain jumps
are present. The 22049 rule therefore has no effect on the accept/drop result:
its matching packets would also be accepted by the default policy. This is
proved explicitly by a restrictive parser, then bound to the incident's four
raw-program hashes. An unknown extra rule is not covered by this proof.

The revised helper creates a private validation copy with only those two
proven-redundant lines removed. It does not edit the live firewall, sealed
evidence, desired configuration or persisted rules. The native complete
namespace check uses that equivalent copy; its subsequent per-port and
first-match validators continue to read the original live programs. A missing
live subscription DROP or overlapping NAT rule remains a failure. The extra
IPv6 DNAT from UDP 2000–3000 to 42536 remains intact and is disjoint from HY2's
23635–23846 range.

The focused tests replay the original failure and revised verification using
actual production parsers and emulated kernel reads of the exact owner tables.
They test missing live DROP and overlapping foreign NAT rejection, verify no
writer is called, and compare every TCP/UDP destination-port decision before
and after the private transformation. Later read-only service checks are now
reported together, so a separate unmet startup requirement is visible in the
same output instead of being hidden behind the first failed predicate.
