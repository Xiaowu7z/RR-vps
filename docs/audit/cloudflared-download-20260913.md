# Cloudflared download recovery — 2026-09-13

## Report and scope

The owner reported that RR-vps 7.2.4 stopped during a fresh Debian-family amd64 installation on AWS after selecting all protocols and Argo. Curl returned HTTP 403 while fetching Cloudflared release metadata, before node ports or domains were configured. Response headers/body from that host were not supplied, so API rate limiting is a possible cause, not an established diagnosis of AWS infrastructure.

The owner requested an integrated repair. This change is restricted to Cloudflared dependency acquisition and release metadata. It does not connect to the owner's servers or the retired test VPS hosts.

## Behavior

- Reuse an installed Cloudflared version that meets the existing minimum version check.
- Preserve the transaction guard: an update cannot download/install a missing dependency.
- Request upstream metadata once. On HTTP 403/429, 5xx, or an allowed network/transport failure, select an embedded, fixed official release.
- Reject other request errors and successful responses with invalid metadata. A fallback is not used to hide a checksum, size, package or post-install version failure.
- Keep HTTPS verification and the same size/SHA256/DEB/version checks for both download paths. No GitHub token, package repository or third-party mirror is added.
- Parse the final HTTP response headers for actionable rate-limit diagnostics, including HTTP/2 status lines.

## Official fallback pins

The upstream 2026.9.1 release body and GitHub asset digests were compared on 2026-09-13. Each URL is under `https://github.com/cloudflare/cloudflared/releases/download/2026.9.1/`.

| Asset | Bytes | SHA256 |
| --- | ---: | --- |
| cloudflared-linux-amd64.deb | 19160216 | 3be76adc4185d36a0bfb4c2dd8663292f0ed363797f2180333b513b43c81d419 |
| cloudflared-linux-arm64.deb | 17667370 | 2a870d5bf6ea74d16c0923b804eabbf4943f1fd7c63a5c20fd41cc66b629c725 |

Source: https://github.com/cloudflare/cloudflared/releases/tag/2026.9.1

## Verification contract

`tests/test-cloudflared-supply-chain.sh` exercises the actual installer function with isolated network/package fixtures: API success, rate limiting and transport failures, invalid metadata, damaged fallback packages, unsupported architectures, preinstalled versions and transaction refusal. Existing update side-effect tests continue to cover the transaction boundary.

The 7.2.4 recovery receipt, helper and original bundle are preserved byte for byte. The recovery-evidence gate verifies that historical evidence separately, binds the new candidate's exact artifacts, and restricts payload changes to the runtime version and Cloudflared download section. It must not describe this as a successful AWS reinstall or a fresh three-host test.

Publication still requires full CI (including Debian 12, Ubuntu 22.04 and Ubuntu 24.04 container jobs) and the recovery-evidence workflow on the same final main commit. The existing immutable release publisher and installed 7.2.1 update guards retain their checks.

No AWS end-to-end installation or public Argo connectivity success is claimed by this record. Those require the owner's subsequent real-server result.
