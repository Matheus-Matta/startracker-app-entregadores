import base64
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tool import prepare_release_env as release


class PrepareReleaseEnvTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.release_directory = self.root / ".release"
        (self.root / "android").mkdir()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def paths(self):
        return patch.multiple(
            release,
            ROOT=self.root,
            APP_ENV_FILE=self.root / ".env.production",
            RELEASE_DIR=self.release_directory,
        )

    def test_android_build_does_not_require_google_play_credentials(self):
        values = {
            "BACKEND_URL": "https://example.com",
            "NOTIFICATIONS_ENABLED": "true",
            "FLEET_WEBSOCKET_PATH": "/ws/fleet/",
            "NOTIFICATIONS_WEBSOCKET_PATH": "/ws/notifications/",
            "NOTIFICATION_CHANNEL_ID": "delivery_updates",
            "NOTIFICATION_CHANNEL_NAME": "Delivery updates",
            "NOTIFICATION_CHANNEL_DESCRIPTION": "Delivery status updates",
            "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"test-keystore").decode(),
            "ANDROID_KEY_ALIAS": "upload",
            "ANDROID_KEY_PASSWORD": "test-key-password",
            "ANDROID_STORE_PASSWORD": "test-store-password",
        }

        with self.paths(), patch.dict(release.os.environ, {"GITHUB_ENV": ""}):
            release.prepare_android(values, with_play=False)

        self.assertTrue((self.root / ".env.production").is_file())
        self.assertTrue((self.root / "android" / "key.properties").is_file())
        self.assertEqual(
            (self.root / "android" / "upload-keystore.jks").read_bytes(),
            b"test-keystore",
        )
        self.assertFalse((self.release_directory / "play-service-account.json").exists())

    def test_app_build_does_not_require_android_or_google_credentials(self):
        values = {
            "BACKEND_URL": "https://example.com",
            "NOTIFICATIONS_ENABLED": "true",
            "FLEET_WEBSOCKET_PATH": "/ws/fleet/",
            "NOTIFICATIONS_WEBSOCKET_PATH": "/ws/notifications/",
            "NOTIFICATION_CHANNEL_ID": "delivery_updates",
            "NOTIFICATION_CHANNEL_NAME": "Delivery updates",
            "NOTIFICATION_CHANNEL_DESCRIPTION": "Delivery status updates",
        }

        with self.paths():
            release.prepare_app(values)

        self.assertTrue((self.root / ".env.production").is_file())
        self.assertFalse((self.root / "android" / "key.properties").exists())
        self.assertFalse((self.root / "android" / "upload-keystore.jks").exists())

    def test_google_play_preparation_does_not_require_android_build_values(self):
        service_account = {
            "type": "service_account",
            "project_id": "test-project",
            "client_email": "release@example.com",
            "private_key": "test-only",
        }
        values = {
            "PLAY_SERVICE_ACCOUNT_JSON_BASE64": base64.b64encode(
                json.dumps(service_account).encode()
            ).decode(),
            "PLAY_TRACK": "internal",
            "PLAY_RELEASE_STATUS": "completed",
        }

        with self.paths(), patch.dict(release.os.environ, {"GITHUB_ENV": ""}):
            release.prepare_google_play(values)

        generated = json.loads(
            (self.release_directory / "play-service-account.json").read_text()
        )
        self.assertEqual(generated, service_account)


if __name__ == "__main__":
    unittest.main()
