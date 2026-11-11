"""Tests use random keys and dummy values; actual CI secrets are not provided."""
import base64
import importlib.util
import unittest
from pathlib import Path
from nacl.public import PrivateKey, SealedBox

spec = importlib.util.spec_from_file_location("sync", Path(__file__).with_name("sync-chauffassistant-registry.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class RegistrySyncTests(unittest.TestCase):
    def test_only_authorised_secrets_are_encrypted_for_the_destination(self):
        key = PrivateKey.generate()
        sent = {}

        class FakeGitHub:
            def call(self, method, path, body=None):
                if path == sync.BASE:
                    return {"full_name": sync.REPOSITORY}
                if path.endswith("/public-key"):
                    return {"key_id": "test-key", "key": base64.b64encode(bytes(key.public_key)).decode()}
                name = path.rsplit("/", 1)[-1]
                if method == "PUT":
                    sent[name] = body
                    return None
                return {"name": name}

        values = {"REGISTRY_USER": "test-user", "REGISTRY_PASSWORD": "dummy-password\nwith-special-$-characters", "ORG_PAT": "must-not-be-copied"}
        sync.sync_registry(FakeGitHub(), values)
        self.assertEqual(set(sent), set(sync.SECRET_NAMES))
        for name, body in sent.items():
            self.assertEqual(body["key_id"], "test-key")
            ciphertext = base64.b64decode(body["encrypted_value"])
            self.assertEqual(SealedBox(key).decrypt(ciphertext).decode(), values[name])
            self.assertNotIn(values[name], body["encrypted_value"])

    def test_missing_source_value_stops_before_any_write(self):
        class NoCalls:
            def call(self, *args):
                raise AssertionError("No API request expected")
        with self.assertRaises(RuntimeError):
            sync.sync_registry(NoCalls(), {"REGISTRY_USER": "test-user"})

    def test_wrong_destination_stops_before_key_or_secret_write(self):
        class WrongRepository:
            def call(self, method, path, body=None):
                if path != sync.BASE:
                    raise AssertionError("No write expected")
                return {"full_name": "Other/Repository"}
        with self.assertRaises(RuntimeError):
            sync.sync_registry(WrongRepository(), {"REGISTRY_USER": "test-user", "REGISTRY_PASSWORD": "dummy"})


if __name__ == "__main__":
    unittest.main()
