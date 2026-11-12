"""Verify a phone passkey's signature over one root MCP command.

Project-JARVIS#310, idea 4. polkit runs jarvis-approval-check (as the
unprivileged polkitd user) for pkexec of /usr/bin/dmcp. The checker answers yes
only when the command line carries an approval that

  * is signed (WebAuthn ES256) by a key enrolled under /etc/jarvis/approvers,
  * covers this exact server, tool and arguments,
  * has not expired (at most MAX_LIFETIME seconds ahead), and
  * has a nonce nobody has used before.

Anything else exits non-zero and polkit falls back to the password dialog.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

CONFIG_DIR = Path("/etc/jarvis/approvers")
STATE_DIR = Path("/var/lib/jarvis-approvals")
MAX_LIFETIME = 120
FLAG_UP = 0x01
FLAG_UV = 0x04

_CMDLINE = re.compile(
    r"^/usr/bin/dmcp call (?P<server>\S+) (?P<tool>\S+)"
    r"(?: --args (?P<args>.+?))?"
    r" --approval (?P<approval>[A-Za-z0-9_-]+)"
    r"(?: --dmcp-internal-elevation-authenticated)?$",
    re.DOTALL,
)


class Rejected(Exception):
    """The approval does not cover this command."""


@dataclass(frozen=True)
class Config:
    rp_id: str
    origin: str


def b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _canonical(obj: object) -> bytes:
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def command_hash(server: str, tool: str, args: Optional[object]) -> str:
    """Hash of one root command; JARVIS computes the same to build the challenge."""
    body = {"server": server, "tool": tool, "args": {} if args is None else args}
    return hashlib.sha256(_canonical(body)).hexdigest()


def challenge_for(cmds: Iterable[str], exp: int, nonce: str) -> str:
    """The base64url challenge the phone signs for a list of command hashes."""
    body = {"v": 1, "cmds": sorted(cmds), "exp": exp, "nonce": nonce}
    return b64url_encode(hashlib.sha256(_canonical(body)).digest())


def parse_command_line(command_line: str) -> tuple[str, str, object, dict]:
    match = _CMDLINE.match(command_line.strip())
    if not match:
        raise Rejected("not a dmcp call carrying an approval")
    raw_args = match.group("args")
    try:
        args = json.loads(raw_args) if raw_args else {}
        approval = json.loads(b64url_decode(match.group("approval")))
    except (ValueError, TypeError) as exc:
        raise Rejected(f"unreadable argument or approval: {exc}") from exc
    if not isinstance(approval, dict) or approval.get("v") != 1:
        raise Rejected("unknown approval version")
    return match.group("server"), match.group("tool"), args, approval


def load_config(config_dir: Path = CONFIG_DIR) -> Config:
    data = json.loads((config_dir / "config.json").read_text())
    return Config(rp_id=str(data["rp_id"]), origin=str(data["origin"]))


def load_keys(config_dir: Path = CONFIG_DIR) -> dict[str, ec.EllipticCurvePublicKey]:
    keys: dict[str, ec.EllipticCurvePublicKey] = {}
    for path in sorted((config_dir / "keys").glob("*.json")):
        try:
            data = json.loads(path.read_text())
            key = serialization.load_pem_public_key(data["public_key_pem"].encode())
        except (ValueError, KeyError, OSError):
            continue
        if isinstance(key, ec.EllipticCurvePublicKey):
            keys[str(data.get("name", path.stem))] = key
    return keys


def verify_signature(
    approval: dict,
    cfg: Config,
    keys: dict[str, ec.EllipticCurvePublicKey],
) -> None:
    try:
        key = keys[approval["key"]]
        auth_data = b64url_decode(approval["authData"])
        client_raw = b64url_decode(approval["clientDataJSON"])
        signature = b64url_decode(approval["sig"])
        cmds = approval["cmds"]
        exp = int(approval["exp"])
        nonce = str(approval["nonce"])
        client = json.loads(client_raw)
    except (KeyError, ValueError, TypeError) as exc:
        raise Rejected(f"malformed approval: {exc}") from exc

    if not isinstance(cmds, list) or not all(isinstance(c, str) for c in cmds):
        raise Rejected("cmds must be a list of hashes")
    if client.get("type") != "webauthn.get":
        raise Rejected("not a webauthn assertion")
    if client.get("origin") != cfg.origin:
        raise Rejected("wrong origin")
    if client.get("challenge") != challenge_for(cmds, exp, nonce):
        raise Rejected("challenge does not match the approved commands")
    if len(auth_data) < 37:
        raise Rejected("authenticator data too short")
    if auth_data[:32] != hashlib.sha256(cfg.rp_id.encode()).digest():
        raise Rejected("wrong relying party")
    flags = auth_data[32]
    if not (flags & FLAG_UP and flags & FLAG_UV):
        raise Rejected("no user presence and verification")

    signed = auth_data + hashlib.sha256(client_raw).digest()
    try:
        key.verify(signature, signed, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature as exc:
        raise Rejected("bad signature") from exc


def use_nonce(
    nonce: str, cmd: str, exp: int, now: int, state_dir: Path = STATE_DIR
) -> None:
    """Spend one (approval, command) pair; reject one spent before.

    An approval may cover several commands, each runnable once. Prunes records
    that expired.
    """
    state_dir.mkdir(parents=True, exist_ok=True)
    for old in state_dir.iterdir():
        try:
            if int(old.read_text()) < now:
                old.unlink()
        except (ValueError, OSError):
            pass
    marker = state_dir / hashlib.sha256(f"{nonce}:{cmd}".encode()).hexdigest()
    try:
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise Rejected("approval already used") from exc
    with os.fdopen(fd, "w") as handle:
        handle.write(str(exp))


def check(
    command_line: str,
    *,
    now: Optional[int] = None,
    cfg: Optional[Config] = None,
    keys: Optional[dict[str, ec.EllipticCurvePublicKey]] = None,
    state_dir: Path = STATE_DIR,
) -> None:
    """Return normally only when the approval covers this exact command."""
    now = int(time.time()) if now is None else now
    server, tool, args, approval = parse_command_line(command_line)
    cfg = cfg or load_config()
    keys = keys if keys is not None else load_keys()

    verify_signature(approval, cfg, keys)

    exp = int(approval["exp"])
    if exp <= now:
        raise Rejected("approval expired")
    if exp - now > MAX_LIFETIME:
        raise Rejected("approval lasts too long")
    cmd = command_hash(server, tool, args)
    if cmd not in approval["cmds"]:
        raise Rejected("approval does not cover this command")

    use_nonce(str(approval["nonce"]), cmd, exp, now, state_dir)
