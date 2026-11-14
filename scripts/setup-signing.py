#!/usr/bin/env python3
"""Create once, then reuse Henry's private macOS app signing identity. Never prints secrets."""
import os
from pathlib import Path
import secrets
import shutil
import shlex
import subprocess

root = Path(os.environ.get("SIGNING_ROOT", str(Path.home() / ".sign_keys_macos_app")))
os.umask(0o077)
root.mkdir(mode=0o700, parents=True, exist_ok=True)
if root.is_symlink():
    raise SystemExit("Signing directory must not be a symlink")
root.chmod(0o700)
openssl = shutil.which("openssl")

def run(*args, env=None):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env).stdout

try:
    p12 = root / "signing.p12"
    password_file = root / "p12-password"
    keychain_password = root / "keychain-password"
    keychain = root / "codesign.keychain-db"
    certificate = root / "certificate.pem"
    if not p12.exists():
        private_key = root / "private-key.pem"
        if not private_key.exists() and not certificate.exists():
            if password_file.exists() or (root / "identity.sha1").exists():
                raise SystemExit("Partial signing identity found; refusing to replace it")
            password_file.write_text(secrets.token_urlsafe(48) + "\n")
            run(openssl, "req", "-new", "-newkey", "rsa:3072", "-x509", "-sha256", "-days", "3650",
                "-subj", "/CN=Henry Local macOS Apps/", "-keyout", str(private_key),
                "-out", str(certificate), "-passout", "file:" + str(password_file),
                "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "keyUsage=critical,digitalSignature",
                "-addext", "extendedKeyUsage=codeSigning")
        # Resume an interrupted export without rotating the existing private key.
        if run(openssl, "pkey", "-in", str(private_key), "-passin", "file:" + str(password_file), "-pubout") != run(openssl, "x509", "-in", str(certificate), "-pubkey", "-noout"):
            raise SystemExit("Existing private key does not match the certificate")
        run(openssl, "pkcs12", "-export", "-legacy", "-inkey", str(root / "private-key.pem"),
            "-in", str(certificate), "-out", str(p12), "-name", "Henry Local macOS Apps",
            "-passin", "file:" + str(password_file), "-passout", "env:WEFT_P12_PASSWORD",
            env={**os.environ, "WEFT_P12_PASSWORD": password_file.read_text().strip()})
    password = password_file.read_text().strip()
    # Verify the encrypted archive before importing or uploading it.
    run(openssl, "pkcs12", "-legacy", "-in", str(p12), "-passin", "file:" + str(password_file), "-noout")
    fingerprint = run(openssl, "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1").decode().split("=", 1)[1].strip().replace(":", "")
    identity_file = root / "identity.sha1"
    if identity_file.exists() and identity_file.read_text().strip() != fingerprint:
        raise SystemExit("Signing certificate fingerprint changed; refusing identity rotation")
    identity_file.write_text(fingerprint + "\n")
    if not keychain_password.exists():
        keychain_password.write_text(secrets.token_urlsafe(48))
    key_password = keychain_password.read_text().strip()
    if not keychain.exists():
        run("security", "create-keychain", "-p", key_password, str(keychain))
    run("security", "unlock-keychain", "-p", key_password, str(keychain))
    run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
    search = shlex.split(run("security", "list-keychains", "-d", "user").decode())
    if str(keychain) not in search:
        run("security", "list-keychains", "-d", "user", "-s", *search, str(keychain))
    identities = run("security", "find-identity", "-p", "codesigning", str(keychain)).decode()
    if fingerprint not in identities:
        run("security", "import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", key_password, str(keychain))
    valid = run("security", "find-identity", "-v", "-p", "codesigning", str(keychain)).decode()
    if fingerprint not in valid:
        run("security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", str(keychain), str(certificate))
    for path in root.iterdir():
        if path.is_file():
            path.chmod(0o600)
    print("Stable signing identity ready:", fingerprint)
except subprocess.CalledProcessError as error:
    # Child output may contain keychain metadata; never print invocation arguments (passwords).
    raise SystemExit("Signing setup failed in " + str(error.cmd[0]) + ": " + error.stderr.decode(errors="replace")) from None
