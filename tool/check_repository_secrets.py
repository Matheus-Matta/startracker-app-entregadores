"""Impede que credenciais de publicacao sejam versionadas.

O script nunca imprime o conteudo encontrado. Use ``--history`` no CI para
verificar todos os blobs alcancaveis pelas branches e tags baixadas.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections.abc import Iterable
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]

BLOCKED_FILENAMES = {
    ".env",
    ".release.env",
    "key.properties",
    "play-service-account.json",
    "service-account.json",
}
BLOCKED_SUFFIXES = {
    ".cer",
    ".certsigningrequest",
    ".csr",
    ".jks",
    ".key",
    ".keystore",
    ".mobileprovision",
    ".p12",
    ".p8",
    ".pem",
    ".provisionprofile",
}
TEXT_SUFFIXES = {
    "",
    ".conf",
    ".dart",
    ".env",
    ".gradle",
    ".json",
    ".kts",
    ".md",
    ".pbxproj",
    ".plist",
    ".properties",
    ".ps1",
    ".py",
    ".sh",
    ".txt",
    ".xcconfig",
    ".xml",
    ".yaml",
    ".yml",
}

SENSITIVE_ASSIGNMENT = re.compile(
    r"(?m)^[ \t]*(?P<key>[A-Z][A-Z0-9_]*(?:"
    r"PASSWORD|PRIVATE_KEY|SECRET|TOKEN|KEYSTORE|CERTIFICATES_FILE|"
    r"SERVICE_ACCOUNT"
    r")[A-Z0-9_]*)[ \t]*=[ \t]*(?P<value>[^\r\n]*)$"
)
PRIVATE_KEY_MARKERS = tuple(
    f"-----BEGIN {key_type}PRIVATE KEY-----"
    for key_type in ("", "EC ", "RSA ")
)
SAFE_VALUE_PREFIXES = (
    "COLE_AQUI",
    "EXAMPLE",
    "PLACEHOLDER",
    "SENHA-",
    "SENHA_",
    "SEU_",
    "SEU-",
    "SUA_",
    "SUA-",
)


def git(*args: str, input_text: str | None = None) -> str:
    result = subprocess.run(
        ("git", *args),
        cwd=ROOT,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        message = result.stderr.strip() or "falha desconhecida do Git"
        raise RuntimeError(message)
    return result.stdout


def normalize(path: str) -> str:
    return path.strip().replace("\\", "/")


def path_problem(path: str) -> str | None:
    normalized = normalize(path)
    pure = PurePosixPath(normalized)
    name = pure.name.lower()
    suffix = pure.suffix.lower()

    if name.endswith(".example"):
        return None
    if name in BLOCKED_FILENAMES:
        return "arquivo de credencial"
    if name.startswith(".env."):
        return "arquivo de ambiente"
    if name.startswith("service-account") and name.endswith(".json"):
        return "service account"
    if name.startswith("play-service-account") and name.endswith(".json"):
        return "service account"
    if suffix in BLOCKED_SUFFIXES:
        return f"extensao bloqueada {suffix}"
    return None


def safe_example_value(value: str) -> bool:
    clean = value.strip().strip("'\"").upper()
    return not clean or clean.startswith(SAFE_VALUE_PREFIXES)


def content_problems(content: bytes) -> set[str]:
    if b"\x00" in content:
        return set()
    text = content.decode("utf-8", errors="ignore")
    problems: set[str] = set()

    if any(marker in text for marker in PRIVATE_KEY_MARKERS):
        problems.add("chave privada PEM")

    for match in SENSITIVE_ASSIGNMENT.finditer(text):
        if not safe_example_value(match.group("value")):
            problems.add(f"valor real em {match.group('key')}")

    return problems


def current_files() -> Iterable[tuple[str, bytes]]:
    tracked = git("ls-files", "-z")
    for raw_path in tracked.split("\0"):
        if not raw_path:
            continue
        path = normalize(raw_path)
        file_path = ROOT / Path(path)
        if file_path.is_file():
            yield path, file_path.read_bytes()


def historical_paths() -> set[str]:
    output = git("log", "--all", "--format=", "--name-only", "--diff-filter=AMCR")
    return {normalize(line) for line in output.splitlines() if line.strip()}


def historical_blobs() -> Iterable[tuple[str, bytes]]:
    objects: dict[str, str] = {}
    for line in git("rev-list", "--objects", "--all").splitlines():
        object_id, separator, path = line.partition(" ")
        if separator and path:
            objects.setdefault(object_id, normalize(path))

    if not objects:
        return

    object_ids = list(objects)
    checks = git(
        "cat-file",
        "--batch-check=%(objectname) %(objecttype) %(objectsize)",
        input_text="\n".join(object_ids) + "\n",
    )
    for line in checks.splitlines():
        object_id, object_type, size_text = line.split()
        path = objects[object_id]
        if object_type != "blob" or int(size_text) > 2_000_000:
            continue
        suffix = PurePosixPath(path).suffix.lower()
        if suffix not in TEXT_SUFFIXES and not PurePosixPath(path).name.startswith(".env"):
            continue
        content = subprocess.run(
            ("git", "cat-file", "blob", object_id),
            cwd=ROOT,
            capture_output=True,
            check=True,
        ).stdout
        yield path, content


def scan(history: bool) -> list[str]:
    findings: set[str] = set()

    current = list(current_files())
    files: Iterable[tuple[str, bytes]] = current
    paths = {path for path, _ in current}
    if history:
        paths.update(historical_paths())
        files = historical_blobs()

    for path in paths:
        problem = path_problem(path)
        if problem:
            findings.add(f"{path}: {problem}")

    for path, content in files:
        for problem in content_problems(content):
            findings.add(f"{path}: {problem}")

    return sorted(findings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--history",
        action="store_true",
        help="verifica todos os blobs alcancaveis por branches e tags",
    )
    args = parser.parse_args()

    try:
        findings = scan(args.history)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Falha ao verificar credenciais: {error}", file=sys.stderr)
        return 2

    if findings:
        print("Credenciais ou arquivos proibidos encontrados:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        print("Nenhum valor foi exibido. Remova-o antes do push.", file=sys.stderr)
        return 1

    scope = "historico alcancavel" if args.history else "arquivos rastreados"
    print(f"Verificacao concluida: nenhum segredo em {scope}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
