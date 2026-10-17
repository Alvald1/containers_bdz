import importlib.util
import io
import json
import pathlib
import unittest
from http.client import IncompleteRead
from unittest.mock import ANY, Mock, patch
from urllib.error import URLError


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts/ensure-registry.py"
SPEC = importlib.util.spec_from_file_location("ensure_registry", SCRIPT)
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)

PROJECT_ID = "7c2b32ba-0194-445b-afc3-a406a4f0171e"
REGISTRY_ID = "b18350ec-6230-48a5-9555-09221e53499a"
NAME = "containers-bdz-7c2b32ba"
ACTIVE = {
    "id": REGISTRY_ID,
    "name": NAME,
    "isPublic": False,
    "registryType": "DOCKER",
    "registryMode": "REGISTRY_MODE_LOCAL",
    "tariff": "BASIC",
    "status": "ACTIVE",
}


class EnsureRegistryTests(unittest.TestCase):
    def setUp(self):
        self.request = Mock()
        self.enterContext(patch.object(registry.time, "sleep"))
        self.enterContext(patch.object(registry.time, "monotonic", return_value=0))

    def test_existing_active_registry_is_reused_without_creation(self):
        self.request.side_effect = [{"registries": [ACTIVE]}, ACTIVE]

        result = registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertEqual(result, REGISTRY_ID)
        self.assertNotIn("POST", [call.args[0] for call in self.request.call_args_list])

    def test_existing_registry_on_next_page_is_found(self):
        self.request.side_effect = [
            {"registries": [], "nextPageToken": "second"},
            {"registries": [ACTIVE]},
            ACTIVE,
        ]

        result = registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertEqual(result, REGISTRY_ID)
        self.assertIn("pageToken=second", self.request.call_args_list[1].args[1])
        self.assertNotIn("POST", [call.args[0] for call in self.request.call_args_list])

    def test_existing_registry_with_wrong_tariff_is_rejected(self):
        self.request.return_value = {"registries": [{**ACTIVE, "tariff": "PREMIUM"}]}

        with self.assertRaises(registry.RegistryError):
            registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertNotIn("POST", [call.args[0] for call in self.request.call_args_list])

    def test_create_waits_for_operation_and_active_registry(self):
        self.request.side_effect = [
            {"registries": []},
            {"id": "operation-1", "done": False},
            {"id": "operation-1", "resourceId": REGISTRY_ID, "done": True},
            {**ACTIVE, "status": "CREATING"},
            ACTIVE,
        ]

        result = registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertEqual(result, REGISTRY_ID)
        self.request.assert_any_call("POST", "/v1/registries", {
            "projectId": PROJECT_ID, "name": NAME, "isPublic": False,
            "registryType": "DOCKER", "registryMode": "REGISTRY_MODE_LOCAL",
            "tariff": "BASIC",
        }, timeout=ANY)
        self.assertEqual(self.request.call_count, 5)

    def test_operation_error_is_not_reported_as_active(self):
        self.request.side_effect = [
            {"registries": []},
            {"id": "operation-1", "done": False},
            {"id": "operation-1", "done": True, "error": {"code": 13, "message": "private-server-detail"}},
        ]

        with self.assertRaises(registry.RegistryError) as error:
            registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertNotIn("private-server-detail", str(error.exception))
        self.assertEqual(self.request.call_count, 3)

    def test_unknown_create_outcome_is_read_back_without_second_create(self):
        self.request.side_effect = [
            {"registries": []},
            registry.ApiError("Connection failed", uncertain=True),
            {"registries": [ACTIVE]},
            ACTIVE,
        ]

        result = registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertEqual(result, REGISTRY_ID)
        self.assertEqual([call.args[0] for call in self.request.call_args_list].count("POST"), 1)

    def test_unknown_create_without_readback_reports_uncertainty(self):
        self.request.side_effect = [
            {"registries": []},
            registry.ApiError("Connection failed", uncertain=True),
            {"registries": []},
        ]

        with self.assertRaisesRegex(registry.RegistryError, "неизвестен"):
            registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertEqual([call.args[0] for call in self.request.call_args_list].count("POST"), 1)

    def test_transport_error_does_not_disclose_credentials(self):
        with patch.object(registry, "urlopen", side_effect=URLError("private-auth-secret")):
            with self.assertRaises(registry.ApiError) as error:
                registry.request_json("POST", registry.IAM_URL, {"secret": "private-auth-secret"})

        self.assertNotIn("private-auth-secret", str(error.exception))

    def test_truncated_response_has_unknown_outcome_without_raw_body(self):
        with patch.object(registry, "urlopen", side_effect=IncompleteRead(b"private-token")):
            with self.assertRaises(registry.ApiError) as error:
                registry.request_json("POST", registry.API_URL + "/v1/registries", {})

        self.assertTrue(error.exception.uncertain)
        self.assertNotIn("private-token", str(error.exception))

    def test_creating_registry_times_out_without_an_extra_request(self):
        registry.time.monotonic.side_effect = [0, 0, 0, 179, 180]
        self.request.side_effect = [{"registries": [ACTIVE]}, {**ACTIVE, "status": "CREATING"}]

        with self.assertRaisesRegex(registry.RegistryError, "180 секунд"):
            registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertEqual(self.request.call_count, 2)
        registry.time.sleep.assert_called_once_with(1)

    def test_invalid_registry_uuid_is_not_returned(self):
        self.request.return_value = {"registries": [{**ACTIVE, "id": "not-a-uuid"}]}

        with self.assertRaises(registry.RegistryError):
            registry.ensure_registry(PROJECT_ID, NAME, self.request)

        self.assertNotIn("POST", [call.args[0] for call in self.request.call_args_list])

    def test_cli_stdout_contains_only_verified_uuid(self):
        output = io.StringIO()
        self.enterContext(patch.dict(registry.os.environ, {"AUTH_KEY_ID": "key", "AUTH_SECRET": "secret"}))
        self.enterContext(patch.object(registry.sys, "stdin", io.StringIO(json.dumps({"project_id": PROJECT_ID, "name": NAME}))))
        self.enterContext(patch.object(registry.sys, "stdout", output))
        self.enterContext(patch.object(registry, "request_json", return_value={"access_token": "private-token"}))
        self.enterContext(patch.object(registry, "ensure_registry", return_value=REGISTRY_ID))

        result = registry.main()

        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), REGISTRY_ID + "\n")


if __name__ == "__main__":
    unittest.main()
