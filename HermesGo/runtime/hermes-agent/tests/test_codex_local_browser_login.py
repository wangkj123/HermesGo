import json
import os
import tempfile
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from hermes_cli import auth, auth_commands, web_server


class CodexLocalBrowserLoginTests(unittest.TestCase):
    def setUp(self):
        self._clear_oauth_sessions()
        self.addCleanup(self._clear_oauth_sessions)

    def _clear_oauth_sessions(self):
        with web_server._oauth_sessions_lock:
            web_server._oauth_sessions.clear()

    def test_codex_cli_browser_login_uses_browser_oauth_flow_and_persists_tokens(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            browser_login_result = {
                "tokens": {
                    "access_token": "local-access-token",
                    "refresh_token": "local-refresh-token",
                },
                "last_refresh": "2026-04-19T00:00:00Z",
                "base_url": auth.DEFAULT_CODEX_BASE_URL,
                "auth_mode": "chatgpt-browser",
                "source": "oauth-browser",
            }

            with patch.object(auth, "get_hermes_home", return_value=hermes_home):
                with patch.object(auth, "_codex_browser_oauth_login", return_value=browser_login_result) as browser_login:
                    creds = auth._codex_cli_browser_login(open_browser=True)

                browser_login.assert_called_once_with(open_browser=True)
                self.assertEqual(creds["tokens"]["access_token"], "local-access-token")
                self.assertEqual(creds["tokens"]["refresh_token"], "local-refresh-token")

                auth_store = auth._load_auth_store()
                state = auth_store["providers"]["openai-codex"]
                self.assertEqual(state["tokens"]["access_token"], "local-access-token")
                self.assertEqual(state["tokens"]["refresh_token"], "local-refresh-token")
                self.assertEqual(state["auth_mode"], "chatgpt-browser")

    def test_auth_add_command_device_auth_forces_fresh_codex_login(self):
        fake_creds = {
            "tokens": {
                "access_token": "fresh-access-token",
                "refresh_token": "fresh-refresh-token",
            },
            "last_refresh": "2026-04-19T00:00:00Z",
            "base_url": auth.DEFAULT_CODEX_BASE_URL,
            "auth_mode": "chatgpt-browser",
            "source": "oauth-browser",
        }

        class FakePool:
            def __init__(self):
                self._entries = []

            def entries(self):
                return list(self._entries)

            def add_entry(self, entry):
                self._entries.append(entry)

        args = SimpleNamespace(
            provider="openai-codex",
            auth_type=None,
            label=None,
            api_key=None,
            portal_url=None,
            inference_url=None,
            client_id=None,
            scope=None,
            device_auth=True,
            no_browser=True,
            timeout=None,
            insecure=False,
            ca_bundle=None,
        )

        with patch.object(auth_commands, "load_pool", return_value=FakePool()):
            with patch.object(auth_commands.auth_mod, "_codex_cli_browser_login", return_value=fake_creds) as login:
                auth_commands.auth_add_command(args)

        login.assert_called_once_with(open_browser=False, force_fresh_login=True)

    def test_codex_browser_oauth_login_opens_authorize_url_and_returns_tokens(self):
        import threading

        class FakeResponse:
            def __init__(self, status_code, payload):
                self.status_code = status_code
                self._payload = payload

            def json(self):
                return self._payload

        class FakeClient:
            def __init__(self, responses):
                self._responses = list(responses)
                self.calls = []

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def post(self, url, **kwargs):
                self.calls.append((url, kwargs))
                return self._responses.pop(0)

        token_client = FakeClient([
            FakeResponse(200, {
                "access_token": "browser-access-token",
                "refresh_token": "browser-refresh-token",
                "token_type": "Bearer",
                "expires_in": 3600,
                "scope": "chatgpt",
            }),
        ])

        fake_server = SimpleNamespace(
            server_address=("127.0.0.1", 43210),
            serve_forever=lambda: None,
            shutdown=lambda: None,
            server_close=lambda: None,
        )

        with patch.object(auth, "_generate_pkce_pair", return_value=("code-verifier-123", "code-challenge-123")):
            with patch.object(auth, "_create_codex_oauth_callback_server", return_value=(fake_server, "http://localhost:43210/auth/callback", {"code": None, "state": None, "error": None}, threading.Event())) as create_server:
                with patch.object(auth, "_wait_for_codex_oauth_callback", return_value="authorization-code-123") as wait_callback:
                    with patch.object(auth.httpx, "Client", side_effect=[token_client]):
                        with patch.object(auth.webbrowser, "open", return_value=True) as open_browser:
                            with patch.object(auth, "_bring_browser_window_to_front", return_value=True):
                                creds = auth._codex_browser_oauth_login(open_browser=True)

        opened_url = open_browser.call_args.args[0]
        self.assertIn("https://auth.openai.com/oauth/authorize?", opened_url)
        self.assertIn("client_id=" + auth.CODEX_OAUTH_CLIENT_ID, opened_url)
        self.assertIn("redirect_uri=http%3A%2F%2Flocalhost%3A43210%2Fauth%2Fcallback", opened_url)
        self.assertIn("code_challenge=code-challenge-123", opened_url)
        self.assertIn("codex_cli_simplified_flow=true", opened_url)
        create_server.assert_called_once_with(preferred_port=1455)
        wait_callback.assert_called_once()
        token_call = token_client.calls[0]
        self.assertEqual(token_call[0], auth.CODEX_OAUTH_TOKEN_URL)
        self.assertEqual(token_call[1]["data"]["code"], "authorization-code-123")
        self.assertEqual(token_call[1]["data"]["code_verifier"], "code-verifier-123")
        self.assertEqual(token_call[1]["data"]["redirect_uri"], "http://localhost:43210/auth/callback")
        self.assertEqual(creds["tokens"]["access_token"], "browser-access-token")
        self.assertEqual(creds["tokens"]["refresh_token"], "browser-refresh-token")
        self.assertEqual(creds["source"], "oauth-browser")
        self.assertEqual(creds["auth_mode"], "chatgpt-browser")

    def test_codex_cli_browser_login_falls_back_to_device_code_login_when_browser_oauth_fails(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            fallback_creds = {
                "tokens": {
                    "access_token": "device-access-token",
                    "refresh_token": "device-refresh-token",
                },
                "last_refresh": "2026-04-19T00:00:00Z",
                "base_url": auth.DEFAULT_CODEX_BASE_URL,
                "auth_mode": "chatgpt",
                "source": "device-code",
            }

            with patch.object(auth, "get_hermes_home", return_value=hermes_home):
                with patch.object(auth, "_codex_browser_oauth_login", side_effect=auth.AuthError("oauth failed", provider="openai-codex", code="oauth_callback_timeout", relogin_required=True)) as browser_login:
                    with patch.object(auth, "_codex_device_code_login", return_value=fallback_creds) as device_login:
                        creds = auth._codex_cli_browser_login(open_browser=True, force_fresh_login=True)

        browser_login.assert_called_once_with(open_browser=True)
        device_login.assert_called_once_with(open_browser=True, preload_security_settings=True)
        self.assertEqual(creds["tokens"]["access_token"], "device-access-token")
        self.assertEqual(creds["source"], "device-code")

    def test_codex_device_code_login_prefers_browser_autofill_helper(self):
        class FakeResponse:
            def __init__(self, status_code, payload):
                self.status_code = status_code
                self._payload = payload

            def json(self):
                return self._payload

            def raise_for_status(self):
                if self.status_code >= 400:
                    raise RuntimeError(f"status {self.status_code}")

        class FakeClient:
            def __init__(self, responses):
                self._responses = list(responses)
                self.calls = []

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def post(self, url, **kwargs):
                self.calls.append((url, kwargs))
                return self._responses.pop(0)

        device_client = FakeClient([
            FakeResponse(200, {
                "device_auth_id": "device-auth-123",
                "user_code": "ABCD-EFGH",
                "verification_uri_complete": "https://auth.openai.com/codex/device?user_code=ABCD-EFGH",
                "interval": 5,
                "expires_in": 900,
            }),
        ])
        poll_client = FakeClient([
            FakeResponse(200, {
                "authorization_code": "authorization-code-123",
                "code_verifier": "code-verifier-123",
            }),
        ])
        token_client = FakeClient([
            FakeResponse(200, {
                "access_token": "device-access-token",
                "refresh_token": "device-refresh-token",
                "token_type": "Bearer",
                "scope": "chatgpt",
            }),
        ])

        with patch.object(auth, "_attempt_codex_device_code_browser_autofill", return_value=True) as autofill:
            with patch.object(auth.httpx, "Client", side_effect=[device_client, poll_client, token_client]):
                with patch.object(auth.time, "sleep", return_value=None):
                    creds = auth._codex_device_code_login(open_browser=True, preload_security_settings=True)

        autofill.assert_called_once_with(
            "https://auth.openai.com/codex/device?user_code=ABCD-EFGH",
            "ABCD-EFGH",
        )
        self.assertEqual(creds["tokens"]["access_token"], "device-access-token")
        self.assertEqual(creds["source"], "device-code")
        self.assertEqual(creds["auth_mode"], "chatgpt")

    def test_wait_for_codex_oauth_callback_returns_code(self):
        import threading
        from urllib.request import urlopen

        result = {}

        server, redirect_uri, shared_result, done = auth._create_codex_oauth_callback_server(preferred_port=0)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()

        def _request():
            with urlopen(f"{redirect_uri}?code=test-code&state=test-state", timeout=5) as resp:
                result["body"] = resp.read().decode("utf-8")

        request_worker = threading.Thread(target=_request, daemon=True)
        request_worker.start()
        code = auth._wait_for_codex_oauth_callback(
            expected_state="test-state",
            server=server,
            worker=worker,
            result=shared_result,
            done=done,
            timeout_seconds=5,
        )
        request_worker.join(timeout=5)

        self.assertEqual(code, "test-code")
        self.assertIn("Authorization Successful", result["body"])

    def test_resolve_codex_cli_executable_prefers_bundled_launcher(self):
        resolved = auth._resolve_codex_cli_executable()
        self.assertTrue(resolved.lower().endswith("codex.cmd"))
        self.assertTrue(Path(resolved).is_file())

    def test_resolve_codex_runtime_credentials_reads_local_cli_tokens(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            local_auth_path = hermes_home / "codex" / "auth.json"
            local_auth_path.parent.mkdir(parents=True, exist_ok=True)
            local_auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "access_token": "local-access-token",
                            "refresh_token": "local-refresh-token",
                        },
                        "last_refresh": "2026-04-19T00:00:00Z",
                    }
                ),
                encoding="utf-8",
            )

            with patch.object(auth, "get_hermes_home", return_value=hermes_home):
                creds = auth.resolve_codex_runtime_credentials()
                auth_store = auth._load_auth_store()

            self.assertEqual(creds["api_key"], "local-access-token")
            state = auth_store["providers"]["openai-codex"]
            self.assertEqual(state["tokens"]["access_token"], "local-access-token")
            self.assertEqual(state["tokens"]["refresh_token"], "local-refresh-token")

    def test_codex_cli_browser_login_reuses_local_cli_tokens(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            local_auth_path = hermes_home / "codex" / "auth.json"
            local_auth_path.parent.mkdir(parents=True, exist_ok=True)
            local_auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "access_token": "local-access-token",
                            "refresh_token": "local-refresh-token",
                        },
                        "last_refresh": "2026-04-19T00:00:00Z",
                    }
                ),
                encoding="utf-8",
            )

            with patch.object(auth, "get_hermes_home", return_value=hermes_home):
                with patch.object(auth.subprocess, "Popen") as popen:
                    creds = auth._codex_cli_browser_login(open_browser=False)
                    auth_store = auth._load_auth_store()

            popen.assert_not_called()
            self.assertEqual(creds["tokens"]["access_token"], "local-access-token")
            state = auth_store["providers"]["openai-codex"]
            self.assertEqual(state["tokens"]["access_token"], "local-access-token")

    def test_codex_cli_browser_login_ignores_shared_cli_tokens_without_local_state(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            user_home = Path(tmp_dir) / "user-home"
            shared_auth_path = user_home / ".codex" / "auth.json"
            shared_auth_path.parent.mkdir(parents=True, exist_ok=True)
            shared_auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "access_token": "shared-access-token",
                            "refresh_token": "shared-refresh-token",
                        },
                        "last_refresh": "2026-04-19T00:00:00Z",
                    }
                ),
                encoding="utf-8",
            )

            with patch.object(auth, "get_hermes_home", return_value=hermes_home):
                with patch.object(
                    auth,
                    "_codex_browser_oauth_login",
                    return_value={
                        "tokens": {
                            "access_token": "device-access-token",
                            "refresh_token": "device-refresh-token",
                        },
                        "last_refresh": "2026-04-19T00:00:00Z",
                        "base_url": auth.DEFAULT_CODEX_BASE_URL,
                        "auth_mode": "chatgpt-browser",
                        "source": "oauth-browser",
                    },
                ) as browser_login:
                    creds = auth._codex_cli_browser_login(open_browser=False)

            browser_login.assert_called_once_with(open_browser=False)
            self.assertEqual(creds["tokens"]["access_token"], "device-access-token")

    def test_clear_provider_auth_only_removes_local_codex_files(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            user_home = Path(tmp_dir) / "user-home"
            codex_home = Path(tmp_dir) / "codex-home"

            with patch.dict(os.environ, {"HERMES_HOME": str(hermes_home)}, clear=False):
                local_auth_path = auth._get_local_codex_auth_path()
                local_auth_path.write_text(
                    json.dumps(
                        {
                            "tokens": {
                                "access_token": "local-access-token",
                                "refresh_token": "local-refresh-token",
                            },
                            "last_refresh": "2026-04-19T00:00:00Z",
                        }
                    ),
                    encoding="utf-8",
                )
                local_lock_path = auth._get_local_codex_home() / "auth.lock"
                local_lock_path.write_text("lock", encoding="utf-8")
                shared_auth_path = user_home / ".codex" / "auth.json"
                shared_auth_path.parent.mkdir(parents=True, exist_ok=True)
                shared_auth_path.write_text(
                    json.dumps(
                        {
                            "tokens": {
                                "access_token": "shared-access-token",
                                "refresh_token": "shared-refresh-token",
                            },
                            "last_refresh": "2026-04-19T00:00:00Z",
                        }
                    ),
                    encoding="utf-8",
                )
                shared_lock_path = user_home / ".codex" / "auth.lock"
                shared_lock_path.write_text("lock", encoding="utf-8")
                env_auth_path = codex_home / "auth.json"
                env_auth_path.parent.mkdir(parents=True, exist_ok=True)
                env_auth_path.write_text(
                    json.dumps(
                        {
                            "tokens": {
                                "access_token": "env-access-token",
                                "refresh_token": "env-refresh-token",
                            },
                            "last_refresh": "2026-04-19T00:00:00Z",
                        }
                    ),
                    encoding="utf-8",
                )
                env_lock_path = codex_home / "auth.lock"
                env_lock_path.write_text("lock", encoding="utf-8")
                auth._save_codex_tokens(
                    {
                        "access_token": "stored-access-token",
                        "refresh_token": "stored-refresh-token",
                    },
                    "2026-04-19T00:00:00Z",
                )

                with patch.dict(os.environ, {"CODEX_HOME": str(codex_home)}, clear=False):
                    with patch.object(auth.Path, "home", return_value=user_home):
                        self.assertTrue(auth.clear_provider_auth("openai-codex"))

                auth_store = auth._load_auth_store()
                self.assertIn("suppressed_sources", auth_store)
                self.assertIn("openai-codex", auth_store["suppressed_sources"])
                self.assertIn("codex_cli_local", auth_store["suppressed_sources"]["openai-codex"])
                self.assertFalse(local_auth_path.exists())
                self.assertFalse(local_lock_path.exists())
                self.assertTrue(shared_auth_path.exists())
                self.assertTrue(shared_lock_path.exists())
                self.assertTrue(env_auth_path.exists())
                self.assertTrue(env_lock_path.exists())
                self.assertNotIn("openai-codex", auth._load_auth_store().get("providers", {}))
                self.assertIsNone(auth._import_codex_cli_tokens())
                self.assertFalse(auth.get_codex_auth_status()["logged_in"])

    def test_start_oauth_login_for_codex_uses_browser_flow_and_switch_account(self):
        created_threads = []

        class FakeThread:
            def __init__(self, target, args=(), kwargs=None, daemon=None, name=None):
                self.target = target
                self.args = args
                self.kwargs = kwargs or {}
                self.daemon = daemon
                self.name = name
                self.started = False
                created_threads.append(self)

            def start(self):
                self.started = True

        with patch.object(web_server.threading, "Thread", FakeThread):
            with TestClient(web_server.app) as client:
                response = client.post(
                    "/api/providers/oauth/openai-codex/start",
                    headers={"Authorization": f"Bearer {web_server._SESSION_TOKEN}"},
                    json={"switch_account": True},
                )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["flow"], "browser")
        self.assertTrue(payload["switch_account"])
        self.assertTrue(created_threads)
        self.assertIs(created_threads[0].target, web_server._codex_browser_login_worker)
        self.assertEqual(created_threads[0].args, (payload["session_id"], True))
        self.assertTrue(created_threads[0].started)

        with web_server._oauth_sessions_lock:
            session = dict(web_server._oauth_sessions[payload["session_id"]])
        self.assertEqual(session["provider"], "openai-codex")
        self.assertEqual(session["flow"], "browser")
        self.assertTrue(session["switch_account"])

    def test_codex_browser_login_worker_clears_expected_local_state(self):
        for switch_account in (False, True):
            with self.subTest(switch_account=switch_account):
                self._clear_oauth_sessions()
                session_id, _ = web_server._new_oauth_session("openai-codex", "browser")
                clear_calls = []
                local_clear_calls = []
                login_calls = []

                with patch.object(
                    auth,
                    "clear_provider_auth",
                    side_effect=lambda provider_id=None: clear_calls.append(provider_id) or True,
                ):
                    with patch.object(
                        auth,
                        "_clear_local_codex_auth_files",
                        side_effect=lambda: local_clear_calls.append(True) or True,
                    ):
                        with patch.object(
                            auth,
                            "_codex_cli_browser_login",
                            side_effect=lambda open_browser=True, **kwargs: login_calls.append((open_browser, kwargs)) or {"ok": True},
                        ):
                            web_server._codex_browser_login_worker(
                                session_id,
                                switch_account=switch_account,
                            )

                self.assertEqual(len(login_calls), 1)
                self.assertEqual(login_calls[0][0], True)
                self.assertIsInstance(login_calls[0][1], dict)
                self.assertEqual(login_calls[0][1].get("force_fresh_login"), switch_account)
                if switch_account:
                    self.assertEqual(clear_calls, ["openai-codex"])
                    self.assertEqual(local_clear_calls, [])
                else:
                    self.assertEqual(clear_calls, [])
                    self.assertEqual(local_clear_calls, [True])

                with web_server._oauth_sessions_lock:
                    session = dict(web_server._oauth_sessions[session_id])
                self.assertEqual(session["status"], "approved")
                self.assertIsNone(session["error_message"])


class OAuthProviderCatalogTests(unittest.TestCase):
    def test_provider_catalog_exposes_expected_login_options(self):
        catalog = {entry["id"]: entry for entry in web_server._OAUTH_PROVIDER_CATALOG}

        self.assertEqual(catalog["anthropic"]["flow"], "pkce")
        self.assertEqual(catalog["claude-code"]["flow"], "external")
        self.assertEqual(catalog["nous"]["flow"], "device_code")
        self.assertEqual(catalog["openai-codex"]["flow"], "browser")
        self.assertEqual(catalog["qwen-oauth"]["flow"], "external")

        self.assertEqual(catalog["anthropic"]["cli_command"], "hermes auth add anthropic")
        self.assertEqual(catalog["nous"]["cli_command"], "hermes auth add nous")
        self.assertEqual(catalog["openai-codex"]["cli_command"], "hermes auth add openai-codex")
        self.assertEqual(catalog["qwen-oauth"]["cli_command"], "hermes auth add qwen-oauth")

    def test_supported_login_options_start_and_external_options_remain_explicit(self):
        if getattr(web_server, "_ANTHROPIC_OAUTH_AVAILABLE", False):
            with patch.object(web_server, "_generate_pkce_pair", return_value=("verifier", "challenge")):
                anthropic = web_server._start_anthropic_pkce()
            self.assertEqual(anthropic["flow"], "pkce")
            self.assertIn("claude.ai/oauth/authorize", anthropic["auth_url"])

        created_threads = []

        class FakeThread:
            def __init__(self, target, args=(), kwargs=None, daemon=None, name=None):
                self.target = target
                self.args = args
                self.kwargs = kwargs or {}
                self.daemon = daemon
                self.name = name
                self.started = False
                created_threads.append(self)

            def start(self):
                self.started = True

        class FakeLoop:
            def run_in_executor(self, executor, fn):
                async def _done():
                    return fn()

                return _done()

        async def _run_device_flows():
            with patch.object(web_server.asyncio, "get_event_loop", return_value=FakeLoop()):
                with patch.object(web_server.threading, "Thread", FakeThread):
                    with patch.object(
                        auth,
                        "_request_device_code",
                        return_value={
                            "device_code": "device-code-123",
                            "user_code": "ABCD-EFGH",
                            "verification_uri_complete": "https://example.test/verify",
                            "interval": 5,
                            "expires_in": 900,
                        },
                    ):
                        nous = await web_server._start_device_code_flow("nous", switch_account=False)
                        codex = await web_server._start_device_code_flow("openai-codex", switch_account=True)
            return nous, codex

        import asyncio

        nous, codex = asyncio.run(_run_device_flows())
        self.assertEqual(nous["flow"], "device_code")
        self.assertEqual(nous["user_code"], "ABCD-EFGH")
        self.assertEqual(nous["verification_url"], "https://example.test/verify")
        self.assertTrue(created_threads)
        self.assertIs(created_threads[0].target, web_server._nous_poller)
        self.assertTrue(created_threads[0].started)

        self.assertEqual(codex["flow"], "browser")
        self.assertTrue(codex["switch_account"])

        self.assertEqual(
            next(entry for entry in web_server._OAUTH_PROVIDER_CATALOG if entry["id"] == "qwen-oauth")["flow"],
            "external",
        )
        self.assertEqual(
            next(entry for entry in web_server._OAUTH_PROVIDER_CATALOG if entry["id"] == "claude-code")["flow"],
            "external",
        )


if __name__ == "__main__":
    unittest.main()
