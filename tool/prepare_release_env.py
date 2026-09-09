"""Prepara arquivos de release a partir do unico .env do GitHub Actions."""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILE = ROOT / ".release.env"
APP_ENV_FILE = ROOT / ".env.production"
RELEASE_DIR = ROOT / ".release"

APP_KEYS = (
    "BACKEND_URL",
    "NOTIFICATIONS_ENABLED",
    "FLEET_WEBSOCKET_PATH",
    "NOTIFICATIONS_WEBSOCKET_PATH",
    "NOTIFICATION_CHANNEL_ID",
    "NOTIFICATION_CHANNEL_NAME",
    "NOTIFICATION_CHANNEL_DESCRIPTION",
)

ANDROID_SIGNING_KEYS = (
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_STORE_PASSWORD",
)

PLAY_KEYS = (
    "PLAY_SERVICE_ACCOUNT_JSON_BASE64",
    "PLAY_TRACK",
    "PLAY_RELEASE_STATUS",
)

IOS_KEYS = (
    "IOS_BUNDLE_ID",
    "IOS_PROVISIONING_PROFILE_NAME",
    "IOS_TEAM_ID",
    "APPSTORE_ISSUER_ID",
    "APPSTORE_API_KEY_ID",
    "APPSTORE_API_PRIVATE_KEY_BASE64",
    "APPSTORE_CERTIFICATES_FILE_BASE64",
    "APPSTORE_CERTIFICATES_PASSWORD",
)


def load_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise ValueError(f"Arquivo ausente: {path.name}")

    values: dict[str, str] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"Linha {number} invalida em {path.name}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ValueError(f"Nome invalido na linha {number}: {key}")
        if key in values:
            raise ValueError(f"Variavel repetida: {key}")
        if "\n" in value or "\r" in value:
            raise ValueError(f"A variavel {key} precisa ficar em uma unica linha")
        values[key] = value
    return values


def require(values: dict[str, str], keys: tuple[str, ...]) -> None:
    missing = [key for key in keys if not values.get(key)]
    placeholders = [key for key in keys if values.get(key, "").startswith("COLE_AQUI_")]
    invalid = missing + placeholders
    if invalid:
        raise ValueError("Preencha no .env: " + ", ".join(invalid))


def decode_base64(values: dict[str, str], key: str) -> bytes:
    try:
        return base64.b64decode(values[key], validate=True)
    except Exception as error:
        raise ValueError(f"{key} nao contem um Base64 valido") from error


def write_app_env(values: dict[str, str]) -> None:
    backend = urlparse(values["BACKEND_URL"])
    if backend.scheme != "https" or not backend.netloc:
        raise ValueError("BACKEND_URL precisa comecar com https://")
    APP_ENV_FILE.write_text(
        "".join(f"{key}={values[key]}\n" for key in APP_KEYS),
        encoding="utf-8",
    )


def escape_java_property(value: str) -> str:
    escaped = value.replace("\\", "\\\\")
    escaped = escaped.replace("=", "\\=").replace(":", "\\:")
    if escaped.startswith(("#", "!", " ")):
        escaped = "\\" + escaped
    return escaped


def prepare_android(values: dict[str, str], *, with_play: bool = True) -> None:
    require(values, APP_KEYS + ANDROID_SIGNING_KEYS)
    if with_play:
        require(values, PLAY_KEYS)
        if values["PLAY_TRACK"] not in {"internal", "alpha", "beta", "production"}:
            raise ValueError("PLAY_TRACK deve ser internal, alpha, beta ou production")
        if values["PLAY_RELEASE_STATUS"] not in {
            "completed",
            "inProgress",
            "halted",
            "draft",
        }:
            raise ValueError("PLAY_RELEASE_STATUS invalido")
    write_app_env(values)

    keystore = decode_base64(values, "ANDROID_KEYSTORE_BASE64")
    if not keystore:
        raise ValueError("ANDROID_KEYSTORE_BASE64 esta vazio")
    (ROOT / "android" / "upload-keystore.jks").write_bytes(keystore)

    key_properties = {
        "storePassword": values["ANDROID_STORE_PASSWORD"],
        "keyPassword": values["ANDROID_KEY_PASSWORD"],
        "keyAlias": values["ANDROID_KEY_ALIAS"],
        "storeFile": "upload-keystore.jks",
    }
    (ROOT / "android" / "key.properties").write_text(
        "".join(
            f"{key}={escape_java_property(value)}\n"
            for key, value in key_properties.items()
        ),
        encoding="utf-8",
    )
    if with_play:
        RELEASE_DIR.mkdir(exist_ok=True)
        service_account_bytes = decode_base64(
            values,
            "PLAY_SERVICE_ACCOUNT_JSON_BASE64",
        )
        try:
            service_account = json.loads(service_account_bytes.decode("utf-8"))
        except Exception as error:
            raise ValueError(
                "PLAY_SERVICE_ACCOUNT_JSON_BASE64 nao contem um JSON valido"
            ) from error
        if not service_account.get("client_email") or not service_account.get(
            "private_key"
        ):
            raise ValueError("O JSON da service account do Google esta incompleto")
        (RELEASE_DIR / "play-service-account.json").write_text(
            json.dumps(service_account),
            encoding="utf-8",
        )
        export_to_github(values, ("PLAY_TRACK", "PLAY_RELEASE_STATUS"))


def prepare_ios(values: dict[str, str]) -> None:
    require(values, APP_KEYS + IOS_KEYS)
    if not re.fullmatch(r"[A-Za-z0-9.-]+", values["IOS_BUNDLE_ID"]):
        raise ValueError("IOS_BUNDLE_ID invalido")
    if not re.fullmatch(r"[A-Z0-9]{10}", values["IOS_TEAM_ID"]):
        raise ValueError("IOS_TEAM_ID deve ter 10 letras/numeros")
    write_app_env(values)
    private_key = decode_base64(values, "APPSTORE_API_PRIVATE_KEY_BASE64").decode("utf-8")
    if "BEGIN PRIVATE KEY" not in private_key:
        raise ValueError("APPSTORE_API_PRIVATE_KEY_BASE64 nao contem uma chave .p8 valida")
    if not decode_base64(values, "APPSTORE_CERTIFICATES_FILE_BASE64"):
        raise ValueError("APPSTORE_CERTIFICATES_FILE_BASE64 esta vazio")

    export_values = dict(values)
    export_values["APPSTORE_API_PRIVATE_KEY"] = private_key
    export_to_github(
        export_values,
        (
            "IOS_BUNDLE_ID",
            "IOS_PROVISIONING_PROFILE_NAME",
            "IOS_TEAM_ID",
            "APPSTORE_ISSUER_ID",
            "APPSTORE_API_KEY_ID",
            "APPSTORE_API_PRIVATE_KEY",
            "APPSTORE_CERTIFICATES_FILE_BASE64",
            "APPSTORE_CERTIFICATES_PASSWORD",
        ),
        secret_keys=(
            "APPSTORE_API_PRIVATE_KEY",
            "APPSTORE_CERTIFICATES_FILE_BASE64",
            "APPSTORE_CERTIFICATES_PASSWORD",
        ),
    )


def github_escape(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def export_to_github(
    values: dict[str, str],
    keys: tuple[str, ...],
    *,
    secret_keys: tuple[str, ...] = (),
) -> None:
    github_env = os.environ.get("GITHUB_ENV")
    if not github_env:
        return

    with Path(github_env).open("a", encoding="utf-8") as output:
        for key in keys:
            delimiter = f"STARTRACKER_{uuid.uuid4().hex}"
            output.write(f"{key}<<{delimiter}\n{values[key]}\n{delimiter}\n")

    for key in secret_keys:
        print(f"::add-mask::{github_escape(values[key])}")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {
        "android",
        "android-build",
        "ios",
    }:
        print(
            "Uso: python tool/prepare_release_env.py android|android-build|ios",
            file=sys.stderr,
        )
        return 2
    try:
        values = load_env(SOURCE_FILE)
        if sys.argv[1] == "android":
            prepare_android(values)
        elif sys.argv[1] == "android-build":
            prepare_android(values, with_play=False)
        else:
            prepare_ios(values)
    except (UnicodeDecodeError, ValueError) as error:
        print(f"Erro de configuracao: {error}", file=sys.stderr)
        return 1
    print(f"Configuracao de {sys.argv[1]} preparada.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
