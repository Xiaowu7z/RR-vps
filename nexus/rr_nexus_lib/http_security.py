"""HTTPS helpers that prevent server-side requests to non-public networks."""

from __future__ import annotations

import http.client
import ipaddress
import socket
import ssl
import urllib.parse
from dataclasses import dataclass
from typing import Callable, Iterable


MAX_HTTPS_URL_LENGTH = 2048


class UnsafeTargetError(ValueError):
    """Raised when an outbound URL could reach a non-public target."""


class ResponseTooLargeError(OSError):
    """Raised when an outbound peer exceeds the bounded response size."""


@dataclass(frozen=True)
class PublicHttpsTarget:
    host: str
    port: int
    request_target: str
    addresses: tuple[str, ...]


def _public_addresses(
    host: str,
    port: int,
    resolver: Callable[..., Iterable[tuple]] = socket.getaddrinfo,
) -> tuple[str, ...]:
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        try:
            records = resolver(host, port, type=socket.SOCK_STREAM)
        except (OSError, UnicodeError) as exc:
            raise UnsafeTargetError("target_resolution_failed") from exc
        raw_addresses = [str(record[4][0]).split("%", 1)[0] for record in records]
    else:
        raw_addresses = [str(literal)]

    addresses: list[str] = []
    for raw in raw_addresses:
        try:
            address = ipaddress.ip_address(raw)
        except ValueError as exc:
            raise UnsafeTargetError("target_resolution_invalid") from exc
        # Reject the complete set if even one DNS answer is local/private.
        # This prevents an attacker from hiding a private answer behind a
        # second public record and relying on address-selection order.
        if not address.is_global:
            raise UnsafeTargetError("target_not_public")
        canonical = str(address)
        if canonical not in addresses:
            addresses.append(canonical)
    if not addresses:
        raise UnsafeTargetError("target_resolution_empty")
    return tuple(addresses)


def public_https_target(
    url: str,
    resolver: Callable[..., Iterable[tuple]] = socket.getaddrinfo,
) -> PublicHttpsTarget:
    """Validate an HTTPS URL and resolve it exclusively to public IPs."""
    if not isinstance(url, str) or not 1 <= len(url) <= MAX_HTTPS_URL_LENGTH:
        raise UnsafeTargetError("invalid_target_url")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in url):
        raise UnsafeTargetError("invalid_target_url")
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port or 443
    except ValueError as exc:
        raise UnsafeTargetError("invalid_target_url") from exc
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise UnsafeTargetError("https_required")
    if parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise UnsafeTargetError("ambiguous_target_url")
    if not 1 <= port <= 65535:
        raise UnsafeTargetError("invalid_target_port")
    try:
        host = parsed.hostname.rstrip(".").encode("idna").decode("ascii").lower()
    except (UnicodeError, AttributeError) as exc:
        raise UnsafeTargetError("invalid_target_host") from exc
    if not host or len(host) > 253:
        raise UnsafeTargetError("invalid_target_host")
    addresses = _public_addresses(host, port, resolver)
    request_target = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
    return PublicHttpsTarget(host=host, port=port, request_target=request_target, addresses=addresses)


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """TLS connection whose TCP peer is the address already validated above."""

    def __init__(self, host: str, port: int, connect_ip: str, timeout: float):
        super().__init__(host, port=port, timeout=timeout, context=ssl.create_default_context())
        self._connect_ip = connect_ip

    def connect(self) -> None:
        # Do not resolve ``self.host`` again here: pinning the validated address
        # closes the DNS-rebinding/TOCTOU window while retaining hostname TLS.
        raw_socket = socket.create_connection(
            (self._connect_ip, self.port), self.timeout, self.source_address
        )
        try:
            self.sock = self._context.wrap_socket(raw_socket, server_hostname=self.host)
        except Exception:
            raw_socket.close()
            raise


def https_post(
    url: str,
    body: bytes,
    headers: dict[str, str],
    timeout: float = 10,
    max_response_bytes: int = 1024 * 1024,
    resolver: Callable[..., Iterable[tuple]] = socket.getaddrinfo,
) -> tuple[int, bytes]:
    """POST to a public HTTPS peer without redirects or DNS re-resolution."""
    target = public_https_target(url, resolver=resolver)
    connection = _PinnedHTTPSConnection(
        target.host, target.port, target.addresses[0], timeout=timeout
    )
    try:
        connection.request("POST", target.request_target, body=body, headers=dict(headers))
        response = connection.getresponse()
        declared_length = response.getheader("Content-Length")
        if declared_length:
            try:
                if int(declared_length) > max_response_bytes:
                    raise ResponseTooLargeError("response_too_large")
            except ValueError:
                pass
        response_body = response.read(max_response_bytes + 1)
        if len(response_body) > max_response_bytes:
            raise ResponseTooLargeError("response_too_large")
        return response.status, response_body
    finally:
        connection.close()
