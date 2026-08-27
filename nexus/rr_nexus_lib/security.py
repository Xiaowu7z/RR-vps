"""TOTP and WebAuthn primitives used by RR Nexus.

Registration is only available from an authenticated, CSRF-protected session.
The authenticator attestation chain is intentionally not used as an identity
source; RR validates the relying-party data and stores the credential public
key.  Authentication signatures are verified with python3-cryptography.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import struct
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any


def b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def b64url_decode(value: str) -> bytes:
    if not isinstance(value, str) or len(value) > 65536:
        raise ValueError("invalid base64url value")
    try:
        raw = (value + "=" * (-len(value) % 4)).encode("ascii")
        return base64.b64decode(raw, altchars=b"-_", validate=True)
    except (UnicodeEncodeError, ValueError, base64.binascii.Error) as exc:
        raise ValueError("invalid base64url value") from exc


def generate_totp_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode("ascii").rstrip("=")


def _totp_digest(secret: str, counter: int) -> bytes:
    padded = secret.strip().upper() + "=" * (-len(secret.strip()) % 8)
    key = base64.b32decode(padded, casefold=True)
    return hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()


def totp_code(secret: str, timestamp: int | None = None, digits: int = 6) -> str:
    counter = int(time.time() if timestamp is None else timestamp) // 30
    digest = _totp_digest(secret, counter)
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10**digits)).zfill(digits)


def verify_totp(secret: str, code: str, timestamp: int | None = None) -> bool:
    normalized = str(code or "").replace(" ", "").strip()
    if not normalized.isdigit() or len(normalized) != 6:
        return False
    now = int(time.time() if timestamp is None else timestamp)
    try:
        return any(
            hmac.compare_digest(totp_code(secret, now + step * 30), normalized)
            for step in (-1, 0, 1)
        )
    except (ValueError, TypeError, base64.binascii.Error):
        return False


def totp_uri(secret: str, username: str, issuer: str = "RR Nexus") -> str:
    label = urllib.parse.quote(f"{issuer}:{username}", safe="")
    query = urllib.parse.urlencode(
        {"secret": secret, "issuer": issuer, "algorithm": "SHA1", "digits": 6, "period": 30}
    )
    return f"otpauth://totp/{label}?{query}"


class _CborDecoder:
    def __init__(self, raw: bytes):
        self.raw = raw
        self.offset = 0

    def _take(self, size: int) -> bytes:
        if size < 0 or self.offset + size > len(self.raw):
            raise ValueError("truncated CBOR")
        value = self.raw[self.offset : self.offset + size]
        self.offset += size
        return value

    def _length(self, additional: int) -> int | None:
        if additional < 24:
            return additional
        if additional == 24:
            return self._take(1)[0]
        if additional == 25:
            return struct.unpack(">H", self._take(2))[0]
        if additional == 26:
            return struct.unpack(">I", self._take(4))[0]
        if additional == 27:
            return struct.unpack(">Q", self._take(8))[0]
        if additional == 31:
            return None
        raise ValueError("unsupported CBOR length")

    def _at_break(self) -> bool:
        if self.offset >= len(self.raw):
            raise ValueError("truncated indefinite CBOR value")
        return self.raw[self.offset] == 0xFF

    def value(self) -> Any:
        initial = self._take(1)[0]
        major, additional = initial >> 5, initial & 31
        length = self._length(additional)
        if major in (0, 1):
            if length is None:
                raise ValueError("invalid CBOR integer")
            return length if major == 0 else -1 - length
        if major in (2, 3):
            if length is None:
                chunks: list[bytes] = []
                while not self._at_break():
                    part = self.value()
                    if not isinstance(part, (bytes, str)):
                        raise ValueError("invalid CBOR chunk")
                    chunks.append(part.encode() if isinstance(part, str) else part)
                self.offset += 1
                raw = b"".join(chunks)
            else:
                raw = self._take(length)
            return raw if major == 2 else raw.decode("utf-8")
        if major == 4:
            items: list[Any] = []
            if length is None:
                while not self._at_break():
                    items.append(self.value())
                self.offset += 1
            else:
                items = [self.value() for _ in range(length)]
            return items
        if major == 5:
            result: dict[Any, Any] = {}
            if length is None:
                while not self._at_break():
                    result[self.value()] = self.value()
                self.offset += 1
            else:
                for _ in range(length):
                    result[self.value()] = self.value()
            return result
        if major == 6:
            if length is None:
                raise ValueError("invalid CBOR tag")
            return self.value()
        if major == 7:
            if additional == 20:
                return False
            if additional == 21:
                return True
            if additional in (22, 23):
                return None
        raise ValueError("unsupported CBOR value")


def decode_cbor(raw: bytes) -> Any:
    decoder = _CborDecoder(raw)
    value = decoder.value()
    if decoder.offset != len(raw):
        raise ValueError("invalid CBOR")
    return value


def decode_cbor_prefix(raw: bytes) -> tuple[Any, int]:
    """Decode one CBOR item and return its exact encoded length."""
    decoder = _CborDecoder(raw)
    value = decoder.value()
    return value, decoder.offset


def _client_data(raw: bytes, expected_type: str, challenge: str, origin: str) -> dict[str, Any]:
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid clientDataJSON") from exc
    if data.get("type") != expected_type:
        raise ValueError("invalid WebAuthn ceremony type")
    if not hmac.compare_digest(str(data.get("challenge", "")), challenge):
        raise ValueError("WebAuthn challenge mismatch")
    if str(data.get("origin", "")).rstrip("/") != origin.rstrip("/"):
        raise ValueError("WebAuthn origin mismatch")
    return data


def _load_crypto() -> tuple[Any, Any, Any, Any, Any]:
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
    except ImportError as exc:
        raise RuntimeError("python3-cryptography is required for passkeys") from exc
    return hashes, serialization, ec, ed25519, (padding, rsa)


def webauthn_available() -> bool:
    try:
        _load_crypto()
        return True
    except RuntimeError:
        return False


def cose_public_key(cose: dict[Any, Any]) -> tuple[bytes, int]:
    hashes, serialization, ec, ed25519, pair = _load_crypto()
    _padding, rsa = pair
    kty = int(cose.get(1, 0))
    alg = int(cose.get(3, 0))
    if kty == 2 and alg == -7 and cose.get(-1) == 1:
        x = int.from_bytes(cose[-2], "big")
        y = int.from_bytes(cose[-3], "big")
        key = ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()
    elif kty == 3 and alg == -257:
        key = rsa.RSAPublicNumbers(
            int.from_bytes(cose[-2], "big"), int.from_bytes(cose[-1], "big")
        ).public_key()
    elif kty == 1 and alg == -8 and cose.get(-1) == 6:
        key = ed25519.Ed25519PublicKey.from_public_bytes(cose[-2])
    else:
        raise ValueError("unsupported passkey algorithm")
    pem = key.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    return pem, alg


@dataclass(frozen=True)
class RegisteredCredential:
    credential_id: bytes
    public_key_pem: bytes
    algorithm: int
    sign_count: int
    transports: str


def parse_registration(
    client_data_b64: str,
    attestation_b64: str,
    expected_challenge: str,
    origin: str,
    rp_id: str,
    transports: list[str] | None = None,
) -> RegisteredCredential:
    client_raw = b64url_decode(client_data_b64)
    _client_data(client_raw, "webauthn.create", expected_challenge, origin)
    attestation = decode_cbor(b64url_decode(attestation_b64))
    if not isinstance(attestation, dict) or not isinstance(attestation.get("authData"), bytes):
        raise ValueError("invalid attestation object")
    auth_data = attestation["authData"]
    if len(auth_data) < 55:
        raise ValueError("truncated authenticator data")
    if not hmac.compare_digest(auth_data[:32], hashlib.sha256(rp_id.encode()).digest()):
        raise ValueError("passkey RP ID mismatch")
    flags = auth_data[32]
    if not flags & 0x01 or not flags & 0x04 or not flags & 0x40:
        raise ValueError("passkey user verification or attested data missing")
    sign_count = int.from_bytes(auth_data[33:37], "big")
    offset = 53
    credential_length = int.from_bytes(auth_data[offset : offset + 2], "big")
    offset += 2
    credential_id = auth_data[offset : offset + credential_length]
    offset += credential_length
    if not credential_id or len(credential_id) > 1024:
        raise ValueError("invalid credential id")
    cose, cose_length = decode_cbor_prefix(auth_data[offset:])
    if not isinstance(cose, dict):
        raise ValueError("invalid credential public key")
    offset += cose_length
    if flags & 0x80:
        extensions = decode_cbor(auth_data[offset:])
        if not isinstance(extensions, dict):
            raise ValueError("invalid authenticator extensions")
    elif offset != len(auth_data):
        raise ValueError("unexpected authenticator data suffix")
    pem, algorithm = cose_public_key(cose)
    accepted = {"usb", "nfc", "ble", "internal", "hybrid"}
    transport_text = ",".join(sorted(set(transports or []) & accepted))
    return RegisteredCredential(credential_id, pem, algorithm, sign_count, transport_text)


def verify_authentication(
    client_data_b64: str,
    authenticator_data_b64: str,
    signature_b64: str,
    expected_challenge: str,
    origin: str,
    rp_id: str,
    public_key_pem: bytes,
    algorithm: int,
    previous_sign_count: int,
) -> int:
    client_raw = b64url_decode(client_data_b64)
    _client_data(client_raw, "webauthn.get", expected_challenge, origin)
    auth_data = b64url_decode(authenticator_data_b64)
    signature = b64url_decode(signature_b64)
    if len(auth_data) < 37:
        raise ValueError("truncated authenticator data")
    if not hmac.compare_digest(auth_data[:32], hashlib.sha256(rp_id.encode()).digest()):
        raise ValueError("passkey RP ID mismatch")
    if not auth_data[32] & 0x01 or not auth_data[32] & 0x04:
        raise ValueError("passkey user verification missing")
    sign_count = int.from_bytes(auth_data[33:37], "big")
    if previous_sign_count and sign_count and sign_count <= previous_sign_count:
        raise ValueError("passkey signature counter did not advance")
    signed = auth_data + hashlib.sha256(client_raw).digest()
    hashes, serialization, ec, ed25519, pair = _load_crypto()
    padding, rsa = pair
    key = serialization.load_pem_public_key(public_key_pem)
    if algorithm == -7 and isinstance(key, ec.EllipticCurvePublicKey):
        key.verify(signature, signed, ec.ECDSA(hashes.SHA256()))
    elif algorithm == -257 and isinstance(key, rsa.RSAPublicKey):
        key.verify(signature, signed, padding.PKCS1v15(), hashes.SHA256())
    elif algorithm == -8 and isinstance(key, ed25519.Ed25519PublicKey):
        key.verify(signature, signed)
    else:
        raise ValueError("stored passkey algorithm mismatch")
    return sign_count
