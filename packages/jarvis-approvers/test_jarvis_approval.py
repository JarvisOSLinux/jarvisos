"""Run: python3 -m unittest test_jarvis_approval (from this directory)."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

import jarvis_approval as ja

RP = "laptop.tail1234.ts.net"
ORIGIN = f"https://{RP}"
NOW = 1_800_000_000


def make_approval(key, cmds, *, exp=NOW + 60, nonce="n1", origin=ORIGIN, rp=RP,
                  flags=0x05, challenge=None, name="phone", wtype="webauthn.get"):
    auth = hashlib.sha256(rp.encode()).digest() + bytes([flags]) + b"\0\0\0\1"
    client = json.dumps({
        "type": wtype,
        "challenge": challenge or ja.challenge_for(cmds, exp, nonce),
        "origin": origin,
    }).encode()
    sig = key.sign(auth + hashlib.sha256(client).digest(), ec.ECDSA(hashes.SHA256()))
    blob = {"v": 1, "cmds": cmds, "exp": exp, "nonce": nonce, "key": name,
            "authData": ja.b64url_encode(auth),
            "clientDataJSON": ja.b64url_encode(client), "sig": ja.b64url_encode(sig)}
    return ja.b64url_encode(json.dumps(blob).encode())


def cmdline(server, tool, args, approval, sentinel=False):
    parts = ["/usr/bin/dmcp", "call", server, tool]
    if args is not None:
        parts += ["--args", json.dumps(args)]
    parts += ["--approval", approval]
    if sentinel:
        parts.append("--dmcp-internal-elevation-authenticated")
    return " ".join(parts)


class Check(unittest.TestCase):
    def setUp(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.keys = {"phone": self.key.public_key()}
        self.cfg = ja.Config(rp_id=RP, origin=ORIGIN)
        self.state = Path(tempfile.mkdtemp())
        self.h = ja.command_hash("sys", "run", {"command": "pacman -Syu", "n": 1})

    def run_check(self, line, now=NOW):
        ja.check(line, now=now, cfg=self.cfg, keys=self.keys, state_dir=self.state)

    def good(self, **kw):
        a = make_approval(self.key, [self.h], **kw)
        return cmdline("sys", "run", {"n": 1, "command": "pacman -Syu"}, a, sentinel=True)

    def test_valid_approval_passes_despite_key_order_and_sentinel(self):
        self.run_check(self.good())

    def test_args_with_spaces_pass(self):
        a = make_approval(self.key, [self.h])
        self.run_check(cmdline("sys", "run", {"command": "pacman -Syu", "n": 1}, a))

    def test_no_args_command(self):
        h = ja.command_hash("sys", "ping", None)
        a = make_approval(self.key, [h])
        self.run_check(cmdline("sys", "ping", None, a))

    def test_replay_rejected(self):
        line = self.good()
        self.run_check(line)
        with self.assertRaises(ja.Rejected):
            self.run_check(line)

    def test_two_commands_one_approval_each_once(self):
        h2 = ja.command_hash("sys", "run", {"command": "pacman -S vim"})
        a = make_approval(self.key, [self.h, h2])
        self.run_check(cmdline("sys", "run", {"command": "pacman -Syu", "n": 1}, a))
        self.run_check(cmdline("sys", "run", {"command": "pacman -S vim"}, a))

    def test_other_command_rejected(self):
        a = make_approval(self.key, [self.h])
        for line in (
            cmdline("sys", "run", {"command": "rm -rf /", "n": 1}, a),
            cmdline("sys", "other", {"command": "pacman -Syu", "n": 1}, a),
            cmdline("other", "run", {"command": "pacman -Syu", "n": 1}, a),
        ):
            with self.assertRaises(ja.Rejected):
                self.run_check(line)

    def test_expired_and_too_long_rejected(self):
        with self.assertRaises(ja.Rejected):
            self.run_check(self.good(exp=NOW - 1))
        with self.assertRaises(ja.Rejected):
            self.run_check(self.good(exp=NOW + 3600))

    def test_unenrolled_key_rejected(self):
        other = ec.generate_private_key(ec.SECP256R1())
        a = make_approval(other, [self.h])
        with self.assertRaises(ja.Rejected):
            self.run_check(cmdline("sys", "run", {"command": "pacman -Syu", "n": 1}, a))

    def test_wrong_origin_rp_flags_type_challenge_rejected(self):
        for kw in (
            {"origin": "https://evil.example"},
            {"rp": "evil.example"},
            {"flags": 0x01},
            {"flags": 0x04},
            {"wtype": "webauthn.create"},
            {"challenge": ja.b64url_encode(b"x" * 32)},
        ):
            with self.assertRaises(ja.Rejected, msg=str(kw)):
                self.run_check(self.good(nonce=str(kw), **kw))

    def test_tampered_blob_rejected(self):
        a = json.loads(ja.b64url_decode(make_approval(self.key, [self.h])))
        a["exp"] += 1
        blob = ja.b64url_encode(json.dumps(a).encode())
        with self.assertRaises(ja.Rejected):
            self.run_check(cmdline("sys", "run", {"command": "pacman -Syu", "n": 1}, blob))

    def test_garbage_command_lines_rejected(self):
        for line in (
            "", "/usr/bin/dmcp call sys run",
            "/home/x/.cargo/bin/dmcp call sys run --approval AAAA",
            "/usr/bin/dmcp call sys run --approval !!!",
            "/usr/bin/dmcp call sys run --args {bad --approval AAAA",
        ):
            with self.assertRaises(ja.Rejected, msg=line):
                self.run_check(line)

    def test_expired_nonce_records_are_pruned(self):
        ja.use_nonce("old", "c", NOW - 10, NOW - 20, self.state)
        ja.use_nonce("new", "c", NOW + 50, NOW, self.state)
        self.assertEqual(len(list(self.state.iterdir())), 1)


if __name__ == "__main__":
    unittest.main()
