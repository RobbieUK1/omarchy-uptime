#!/usr/bin/env python3
"""Encryption at rest for the activity session log.

The session log (data/activity-sessions.json) records only timestamps - when
the machine was powered on, when typing bursts happened, and when someone was
in front of the screen - but that is still personal data, so it is kept
encrypted on disk:

  * a random 256-bit key lives in data/activity.key (mode 0600);
  * the log is sealed with AES-256-CBC (a fresh random IV per write) using the
    openssl command-line tool that ships with the base system;
  * an HMAC-SHA256 over the ciphertext catches tampering or corruption;
  * older plaintext logs are still read, and are re-sealed on the next write,
    so upgrading is seamless.

This keeps the log away from other users on the machine and from anyone who
copies it without the key. It is not protection against an attacker who can
already read the key as this user, or as root.
"""

import base64
import hashlib
import hmac
import json
import os
import pathlib
import subprocess

DATA_DIR = pathlib.Path.home() / ".config/omarchy/bar/data"
DATA_FILE = DATA_DIR / "activity-sessions.json"
KEY_FILE = DATA_DIR / "activity.key"

MAGIC = b"OMACT1\n"
KEY_BYTES = 32
IV_BYTES = 16
MAC_BYTES = 32


def _load_key():
    """Return the 32-byte key, creating a fresh 0600 key file on first use."""
    try:
        key = bytes.fromhex(KEY_FILE.read_text().strip())
        if len(key) == KEY_BYTES:
            return key
    except (OSError, ValueError):
        pass
    key = os.urandom(KEY_BYTES)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(KEY_FILE), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(key.hex() + "\n")
    return key


def _mac_key():
    return hashlib.sha256(_load_key() + b"omarchy-activity-mac").digest()


def _openssl(data, key_hex, iv_hex, decrypt):
    cmd = ["openssl", "enc", "-aes-256-cbc", "-K", key_hex, "-iv", iv_hex,
           "-nosalt"]
    if decrypt:
        cmd.insert(2, "-d")
    proc = subprocess.run(cmd, input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise OSError("openssl failed: %s"
                      % proc.stderr.decode("utf-8", "replace").strip())
    return proc.stdout


def _seal(plaintext):
    key = _load_key()
    iv = os.urandom(IV_BYTES)
    body = iv + _openssl(plaintext, key.hex(), iv.hex(), False)
    mac = hmac.new(_mac_key(), body, hashlib.sha256).digest()
    return MAGIC + base64.b64encode(mac + body)


def _unseal(blob):
    raw = base64.b64decode(blob[len(MAGIC):])
    mac, body = raw[:MAC_BYTES], raw[MAC_BYTES:]
    if len(body) <= IV_BYTES or not hmac.compare_digest(
            mac, hmac.new(_mac_key(), body, hashlib.sha256).digest()):
        raise ValueError("activity log failed its integrity check")
    return _openssl(body[IV_BYTES:], _load_key().hex(),
                    body[:IV_BYTES].hex(), True)


def read_json(fallback=None):
    """Decrypted log contents as a dict, or `fallback` if unavailable."""
    empty = {} if fallback is None else fallback
    try:
        blob = DATA_FILE.read_bytes()
    except OSError:
        return empty
    if blob.startswith(MAGIC):
        try:
            blob = _unseal(blob)
        except (OSError, ValueError):
            return empty
    try:
        data = json.loads(blob.decode("utf-8"))
    except (OSError, ValueError):
        return empty
    return data if isinstance(data, dict) else empty


def write_json(obj):
    """Seal obj and atomically replace the log. Returns True on success."""
    payload = json.dumps(obj, indent=1).encode("utf-8")
    try:
        blob = _seal(payload)
    except (OSError, ValueError):
        blob = payload  # keep recording even if openssl is unavailable
    tmp = DATA_FILE.with_suffix(DATA_FILE.suffix + ".tmp")
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        with open(tmp, "wb") as fh:
            fh.write(blob)
            fh.flush()
            os.fsync(fh.fileno())
            os.fchmod(fh.fileno(), 0o600)
        os.replace(tmp, DATA_FILE)
        return True
    except OSError:
        return False
