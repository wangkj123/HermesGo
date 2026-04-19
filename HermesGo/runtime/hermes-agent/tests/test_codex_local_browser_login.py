import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from hermes_cli import auth, web_server


class CodexLocalBrowserLoginTests(unittest.TestCase):
    def setUp(self):
        self._clear_oauth_sessions()
        self.addCleanup(self._clear_oauth_sessions)

    def _clear_oauth_sessions(self):
        with web_server._oauth_sessions_lock:
            web_server._oauth_sessions.clear()

    def test_codex_cli_browser_login_uses_local_isolated_home_and_persists_tokens(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"
            popen_call = {}

            class FakeProcess:
                def poll(self):
                    return None

            def fake_popen(command, stdin, stdout, stderr, env, cwd):
                popen_call["command"] = command
                popen_call["env"] = dict(env)
                popen_call["cwd"] = cwd

                auth_path = Path(env["CODEX_HOME"]) / "auth.json"
                auth_path.parent.mkdir(parents=True, exist_ok=True)
                auth_path.write_text(
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
                return FakeProcess()

            with patch.dict(os.environ, {"HERMES_HOME": str(hermes_home)}, clear=False):
                with patch.object(auth, "_resolve_codex_cli_executable", return_value="codex"):
                    with patch.object(auth.subprocess, "Popen", side_effect=fake_popen):
                        creds = auth._codex_cli_browser_login(open_browser=True)

                self.assertEqual(popen_call["command"], ["codex", "login"])
                self.assertEqual(popen_call["env"]["CODEX_HOME"], str(hermes_home / "codex"))
                self.assertEqual(popen_call["env"]["HOME"], str(hermes_home / "codex-home"))
                self.assertEqual(popen_call["env"]["USERPROFILE"], str(hermes_home / "codex-home"))
                self.assertEqual(popen_call["cwd"], str(hermes_home / "codex-home"))
                self.assertEqual(creds["tokens"]["access_token"], "local-access-token")
                self.assertEqual(creds["tokens"]["refresh_token"], "local-refresh-token")
                self.assertEqual(creds["auth_store_path"], str(hermes_home / "codex" / "auth.json"))

                auth_store = auth._load_auth_store()
                state = auth_store["providers"]["openai-codex"]
                self.assertEqual(state["tokens"]["access_token"], "local-access-token")
                self.assertEqual(state["tokens"]["refresh_token"], "local-refresh-token")
                self.assertEqual(state["auth_mode"], "chatgpt")

    def test_clear_provider_auth_removes_local_codex_files(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            hermes_home = Path(tmp_dir) / "hermes-home"

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
                auth._save_codex_tokens(
                    {
                        "access_token": "stored-access-token",
                        "refresh_token": "stored-refresh-token",
                    },
                    "2026-04-19T00:00:00Z",
                )

                self.assertTrue(auth.clear_provider_auth("openai-codex"))
                self.assertFalse(local_auth_path.exists())
                self.assertNotIn("openai-codex", auth._load_auth_store().get("providers", {}))

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
                            side_effect=lambda open_browser=True: login_calls.append(open_browser) or {"ok": True},
                        ):
                            web_server._codex_browser_login_worker(
                                session_id,
                                switch_account=switch_account,
                            )

                self.assertEqual(login_calls, [True])
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


if __name__ == "__main__":
    unittest.main()
