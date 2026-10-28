"""Tests for the ServiceNow sign-in modes: SN_USE_USERNAME_PASSWORD=true (Basic) and false (OAuth, the default).
Run:  python -m unittest discover -s tests -v   (from the project folder)"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import monitor  # noqa: E402
import requests  # noqa: E402

BASE_ENV = {"SN_INSTANCE": "acme", "AZURE_STORAGE_ACCOUNT_URL": "https://stacct.blob.core.windows.net"}


def config_with(extra: dict) -> dict:
    env = dict(BASE_ENV)
    env.update(extra)
    with mock.patch.dict(os.environ, env, clear=True):
        return monitor.load_config()


class SignInModes(unittest.TestCase):
    def setUp(self):
        monitor._sn_token.update({"value": None, "expires_at": 0.0})

    def test_default_is_oauth(self):
        cfg = config_with({"SN_CLIENT_ID": "id", "SN_CLIENT_SECRET": "secret"})
        self.assertFalse(cfg["sn_use_username_password"])

    def test_username_password_mode_sends_basic_auth_and_no_token(self):
        cfg = config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "svc_user", "SN_PASSWORD": "pw"})
        session = requests.Session()
        with mock.patch.object(monitor, "get_oauth_token") as token:
            monitor.authenticate(cfg, session)
            token.assert_not_called()
        import base64
        self.assertEqual(session.headers["Authorization"], "Basic " + base64.b64encode(b"svc_user:pw").decode("ascii"))

    def test_oauth_mode_sends_bearer_token(self):
        cfg = config_with({"SN_CLIENT_ID": "id", "SN_CLIENT_SECRET": "secret"})
        session = requests.Session()
        with mock.patch.object(monitor, "get_oauth_token", return_value={"value": "tok", "expires_at": 1e12}):
            monitor.authenticate(cfg, session)
        self.assertEqual(session.headers["Authorization"], "Bearer tok")
        self.assertIsNone(session.auth)

    def test_username_password_mode_needs_both_values(self):
        with self.assertRaises(ValueError) as ctx:
            config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "svc_user"})
        self.assertIn("SN_PASSWORD", str(ctx.exception))
        self.assertNotIn("SN_CLIENT_ID", str(ctx.exception))

    def test_oauth_mode_needs_client_values(self):
        with self.assertRaises(ValueError) as ctx:
            config_with({})
        self.assertIn("SN_CLIENT_ID", str(ctx.exception))


class UsernamePasswordRobustness(unittest.TestCase):
    def test_password_with_accents_and_symbols_is_sent_as_utf8(self):
        cfg = config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "svc_user", "SN_PASSWORD": "pässwörd#1"})
        session = requests.Session()
        monitor.authenticate(cfg, session)
        import base64
        expected = "Basic " + base64.b64encode("svc_user:pässwörd#1".encode("utf-8")).decode("ascii")
        self.assertEqual(session.headers["Authorization"], expected)

    def test_password_is_not_trimmed_and_username_is_stripped(self):
        cfg = config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "  svc_user  ", "SN_PASSWORD": "pw with space "})
        self.assertEqual(cfg["sn_username"], "svc_user")
        self.assertEqual(cfg["sn_password"], "pw with space ")

    def test_certificate_check_can_be_turned_off(self):
        self.assertFalse(config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "u", "SN_PASSWORD": "p", "SN_VERIFY_SSL": "false"})["sn_verify_ssl"])
        self.assertTrue(config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "u", "SN_PASSWORD": "p"})["sn_verify_ssl"])

    def test_no_stray_oauth_token_request_in_username_mode(self):
        cfg = config_with({"SN_USE_USERNAME_PASSWORD": "true", "SN_USERNAME": "u", "SN_PASSWORD": "p"})
        with mock.patch.object(monitor.requests, "post") as post:
            monitor.authenticate(cfg, requests.Session())
            post.assert_not_called()


if __name__ == "__main__":
    unittest.main()
