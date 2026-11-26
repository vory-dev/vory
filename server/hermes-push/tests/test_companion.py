"""Unit tests for the companion (hermes_push.py and the plugin's single-instance lock).

No Hermes is imported or run: a fake gateway answers the companion's calls over a local
WebSocket, and Windows' msvcrt is a stand-in. Run from the repo root:

    PYTHONPATH=<a folder with websockets> python3 -m unittest discover -s server/hermes-push/tests

PyJWT (used only to sign APNs requests) is replaced by an empty module when it is not installed.
"""
from __future__ import annotations

import asyncio
import importlib.util
import io
import json
import logging
import os
import secrets
import sys
import tempfile
import time
import types
import unittest
import urllib.error
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
os.environ.setdefault("HERMES_PUSH_GATEWAY_URL", "http://127.0.0.1:9")


def _use_home(home: Path) -> None:
    """Hermes's home, the push folder and the companion's conf, all in `home`."""
    os.environ["HERMES_HOME"] = str(home)
    os.environ["HERMES_PUSH_DEVICES_DIR"] = str(home / "push" / "devices")
    os.environ["HERMES_PUSH_CONFIG"] = str(home / "push" / "hermes-push.conf")


# Every test runs in a home of its own, never this account's: run with `env -i`, HOME is unset and Path.home() would
# name this account's folder. The module's home is this one; the tests of a migrated gateway make one each (OwnHome).
_MODULE_HOME = tempfile.TemporaryDirectory(prefix="companion-test-home-")
_use_home(Path(_MODULE_HOME.name))
if "jwt" not in sys.modules:
    try:
        import jwt  # noqa: F401
    except ImportError:
        sys.modules["jwt"] = types.ModuleType("jwt")
sys.path.insert(0, str(ROOT))
import hermes_push  # noqa: E402
import websockets  # noqa: E402


def load_plugin():
    """The plugin's __init__.py as a module of its own (its folder name has a hyphen)."""
    spec = importlib.util.spec_from_file_location("vory_push_plugin", ROOT / "plugin" / "vory-push" / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeGateway:
    """Answers every call with an empty result, client.capabilities as told: "ok", "unknown"
    (JSON-RPC -32601), "unknown-text" (an error whose message says so, with no code) or "fail"."""

    def __init__(self, capabilities: str) -> None:
        self.capabilities = capabilities
        self.calls: list[str] = []

    async def handler(self, ws) -> None:
        async for raw in ws:
            msg = json.loads(raw)
            self.calls.append(msg["method"])
            if msg["method"] == "client.capabilities" and self.capabilities != "ok":
                err = {"unknown": {"code": -32601, "message": "Method not found"},
                       "unknown-text": {"message": "unknown method: client.capabilities"},
                       "fail": {"code": -32000, "message": "boom"}}[self.capabilities]
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": err}))
            else:
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {}}))


class CapabilitiesTests(unittest.IsolatedAsyncioTestCase):
    """#400: an older Hermes answers client.capabilities with "unknown method". The relay goes on
    without it, says once what is missing, and tells the app; any other failure still fails."""

    async def connect(self, capabilities: str):
        fake = FakeGateway(capabilities)
        server = await websockets.serve(fake.handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        gw = hermes_push.Gateway()
        gw._ws_for = lambda url: (f"ws://127.0.0.1:{port}/api/ws", "test")
        self.addAsyncCleanup(self.close, server, gw)
        return gw, fake

    async def close(self, server, gw) -> None:
        if gw.ws is not None:
            await gw.ws.close()
        server.close()
        await server.wait_closed()

    async def test_a_gateway_that_takes_it(self) -> None:
        gw, fake = await self.connect("ok")
        await gw.connect()
        self.assertTrue(gw.server_requests)
        self.assertEqual(fake.calls, ["client.capabilities"])
        # The connection goes on working.
        self.assertEqual(await gw.call("session.list"), {})

    async def test_an_older_gateway_is_not_fatal_and_says_so_once(self) -> None:
        for answer in ("unknown", "unknown-text"):
            with self.subTest(answer=answer):
                gw, _ = await self.connect(answer)
                with self.assertLogs("hermes-push", level="WARNING") as logs:
                    await gw.connect()
                self.assertIs(gw.server_requests, False)
                self.assertEqual(len(logs.records), 1)
                self.assertIn("Update Hermes", logs.output[0])
                self.assertEqual(await gw.call("session.list"), {})

    async def test_the_hint_is_not_repeated_on_a_reconnect(self) -> None:
        gw, _ = await self.connect("unknown")
        with self.assertLogs("hermes-push", level="WARNING"):
            await gw.connect()
        await gw.ws.close()
        logger = logging.getLogger("hermes-push")
        seen: list[logging.LogRecord] = []
        handler = logging.Handler()
        handler.emit = seen.append
        logger.addHandler(handler)
        try:
            await gw.connect()
        finally:
            logger.removeHandler(handler)
        self.assertEqual([r for r in seen if r.levelno >= logging.WARNING], [])

    async def test_any_other_failure_still_fails(self) -> None:
        gw, _ = await self.connect("fail")
        with self.assertRaises(hermes_push.RPCError) as caught:
            await gw.connect()
        self.assertEqual(caught.exception.code, -32000)

    def test_the_status_tells_the_app(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            status = Path(d) / "status.json"
            old = hermes_push.status_path
            hermes_push.status_path = lambda: status
            try:
                relay = hermes_push.Relay.__new__(hermes_push.Relay)
                relay.gw = types.SimpleNamespace(server_requests=False)
                relay.last_test, relay.last_la = {}, {}
                relay._status(connected=True)
            finally:
                hermes_push.status_path = old
            written = json.loads(status.read_text())
        self.assertIs(written["server_requests"], False)
        self.assertEqual(written["version"], hermes_push.VERSION)


class ReconnectTests(unittest.IsolatedAsyncioTestCase):
    """A reconnect closes the socket it replaces, and a socket released on purpose does not
    report "closed" after its replacement is up: that stale "closed" made the relay reconnect
    without closing the new socket, leaking one attached socket per idle release."""

    async def asyncSetUp(self) -> None:
        self.open: set = set()
        fake = FakeGateway("ok")

        async def handler(ws) -> None:
            self.open.add(ws)
            try:
                await fake.handler(ws)
            finally:
                self.open.discard(ws)

        self.server = await websockets.serve(handler, "127.0.0.1", 0)
        port = self.server.sockets[0].getsockname()[1]
        self.gw = hermes_push.Gateway()
        self.gw._ws_for = lambda url: (f"ws://127.0.0.1:{port}/api/ws", "test")

    async def asyncTearDown(self) -> None:
        await self.gw.close()
        self.server.close()
        await self.server.wait_closed()

    async def settle(self) -> None:
        for _ in range(50):
            await asyncio.sleep(0.01)

    async def test_a_released_socket_is_not_reported_closed(self) -> None:
        await self.gw.connect()
        await self.gw.close()  # ReleaseIdle / a config reload
        await self.gw.connect()
        await self.settle()
        self.assertTrue(self.gw.events.empty())
        self.assertEqual(len(self.open), 1)

    async def test_a_reconnect_closes_the_socket_it_replaces(self) -> None:
        await self.gw.connect()
        await self.gw.connect()
        await self.settle()
        self.assertEqual(len(self.open), 1)
        self.assertTrue(self.gw.events.empty())

    async def test_the_current_socket_closing_is_still_news(self) -> None:
        await self.gw.connect()
        for ws in list(self.open):
            await ws.close()
        ev = await asyncio.wait_for(self.gw.events.get(), timeout=2)
        self.assertEqual(ev["type"], "__closed__")


class FakeMsvcrt(types.ModuleType):
    """Windows' msvcrt, as far as the lock goes: one holder per file, LK_NBLCK raising OSError
    while another handle holds it."""
    LK_NBLCK, LK_UNLCK = 2, 0

    def __init__(self) -> None:
        super().__init__("msvcrt")
        self.held: dict[str, int] = {}

    def locking(self, fd: int, mode: int, nbytes: int) -> None:
        path = str(os.fstat(fd).st_ino)  # one file, whichever handle
        if mode == self.LK_NBLCK:
            if self.held.get(path, fd) != fd:
                raise OSError(36, "Resource deadlock avoided")
            self.held[path] = fd
        elif mode == self.LK_UNLCK and self.held.get(path) == fd:
            del self.held[path]


class SingleInstanceTests(unittest.TestCase):
    """#403: on Windows, which has no fcntl, the relay's lock is msvcrt's, so the dashboard and the
    gateway do not both run a relay (every push arrived twice)."""

    def setUp(self) -> None:
        self.saved = {k: sys.modules.get(k) for k in ("fcntl", "msvcrt")}
        sys.modules["fcntl"] = None  # import fcntl raises ImportError
        self.msvcrt = FakeMsvcrt()
        sys.modules["msvcrt"] = self.msvcrt
        self.plugin = load_plugin()
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "relay.lock"

    def tearDown(self) -> None:
        for k, v in self.saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
        self.dir.cleanup()

    def test_one_holder_at_a_time_without_fcntl(self) -> None:
        first, second = open(self.path, "w"), open(self.path, "w")
        try:
            self.assertTrue(self.plugin._try_lock(first), "the first relay did not get the lock")
            self.assertFalse(self.plugin._try_lock(second), "a second relay got the lock too")
            self.msvcrt.locking(first.fileno(), FakeMsvcrt.LK_UNLCK, 1)
            self.assertTrue(self.plugin._try_lock(second), "the lock was not free once its holder let go")
        finally:
            first.close(); second.close()

    def test_the_claim_takes_the_lock_through_msvcrt(self) -> None:
        hp = types.SimpleNamespace(status_path=lambda: self.path.with_name("status.json"))
        self.assertTrue(self.plugin._claim_single_instance(hp))
        self.assertEqual(len(self.msvcrt.held), 1)

    def test_with_neither_lock_the_relay_runs(self) -> None:
        sys.modules["msvcrt"] = None
        with open(self.path, "w") as h:
            self.assertTrue(self.plugin._try_lock(h))


if __name__ == "__main__":
    unittest.main()


class ComplicationPushTests(unittest.TestCase):
    """#499: the Watch's complication refresh push, through the relay, carries no chat data. What the Companion posts
    to the relay is captured (no network): the install id, its secret and the push type, and nothing else, so neither
    the gateway's address nor any title, text or bot name leaves the gateway with it."""

    def test_a_relay_complication_push_carries_no_chat_data(self) -> None:
        posted: list[dict] = []

        class Answer:
            status = 200
            def read(self) -> bytes: return b'{"ok":true}'
            def __enter__(self): return self
            def __exit__(self, *a) -> None: return None

        def capture(req, timeout=None):
            posted.append(json.loads(req.data.decode()))
            return Answer()

        import urllib.request
        real = urllib.request.urlopen
        urllib.request.urlopen = capture
        try:
            apns = hermes_push.APNs()
            apns.dry_run = False
            device = {"device_id": "watch-1-watch", "platform": "watchos", "bundle_id": "com.vorantx.vory.watchkitapp",
                      "relay": {"url": "https://relay.test", "install_id": "w1", "secret": "s" * 48}}
            payload = {"aps": {"content-available": 1}, "hermes": {"kind": "complication", "gateway": "https://gateway.example",
                                                                   "title": "Rewrite the nightly export job", "bot": "Hermes"}}
            self.assertTrue(apns.send(device, payload, push_type="complication"))
        finally:
            urllib.request.urlopen = real
        self.assertEqual(len(posted), 1)
        self.assertEqual(posted[0], {"install_id": "w1", "secret": "s" * 48, "push_type": "complication"})
        text = json.dumps(posted[0])
        for word in ("gateway.example", "nightly", "Hermes", "title", "alert", "content_state", "attributes", "enc"):
            self.assertNotIn(word, text)


def _have_aesgcm() -> bool:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: F401
        return True
    except ImportError:
        return False


class SealedLiveActivityTests(unittest.TestCase):
    """#497: in relay mode, for an app that opens sealed fields, a Live Activity push carries the goal line and the chat's
    names sealed with the install's key. What the Companion posts to the relay is captured (no network). Where the
    `cryptography` package is missing, a stand-in seals: it records what it was given and returns random bytes of the
    real length, so the fields' moves and the payload's size are still checked; the blobs are opened only with the real
    cipher."""

    KEY = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="   # bytes 0 to 31
    GOAL = "Finding why the nightly export times out"
    NAMES = {"sessionTitle": "Rewrite the nightly export job", "botName": "Archivist", "profile": "archivist",
             "tintHex": "#FF8800", "avatar": "animated:pebble"}
    PLAIN_STATE = {"phase", "detail", "outputTokens", "contextPercent", "contextUsed", "contextMax", "needsAttention",
                   "startedAtUnix", "endedAtUnix", "sealed"}
    FIXED_WORDS = {"Waiting for you", "Turn finished", "The turn failed", "Thinking…", "Writing…", "Running a tool…", "Working…"}

    def setUp(self) -> None:
        import base64, urllib.request
        self.posted: list[dict] = []
        self.sealed: list[dict] = []

        class Answer:
            status = 200
            def read(self) -> bytes: return b'{"ok":true}'
            def __enter__(self): return self
            def __exit__(self, *a) -> None: return None

        def capture(req, timeout=None):
            self.posted.append(json.loads(req.data.decode()))
            return Answer()

        self.real_urlopen, urllib.request.urlopen = urllib.request.urlopen, capture
        self.real_encrypt = hermes_push.encrypt_for_device
        if not _have_aesgcm():
            def stand_in(device: dict, obj: dict) -> str | None:
                if not device.get("payload_key"):
                    return None
                self.sealed.append(obj)
                plain = json.dumps(obj, separators=(",", ":")).encode()
                return base64.b64encode(os.urandom(12 + len(plain) + 16)).decode()
            hermes_push.encrypt_for_device = stand_in

    def tearDown(self) -> None:
        import urllib.request
        urllib.request.urlopen = self.real_urlopen
        hermes_push.encrypt_for_device = self.real_encrypt

    def device(self, sealed: bool = True) -> dict:
        d = {"device_id": "phone-1", "platform": "ios", "bundle_id": "com.vorantx.vory", "payload_key": self.KEY,
             "relay": {"url": "https://relay.test", "install_id": "i1", "secret": "s" * 48}}
        if sealed:
            d["la_sealed"] = 1
        return d

    def send(self, device: dict, aps: dict) -> dict:
        apns = hermes_push.APNs()
        apns.dry_run = False
        self.assertTrue(apns.send(device, {"aps": aps}, push_type="liveactivity", token_override="la-token"))
        return self.posted[-1]

    def opened(self, blob: str) -> dict:
        """A sealed field, opened: with the real cipher and the device's key, else what the stand-in was given."""
        if not _have_aesgcm():
            return self.sealed.pop(0)
        import base64
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        raw = base64.b64decode(blob)
        return json.loads(AESGCM(base64.b64decode(self.KEY)).decrypt(raw[:12], raw[12:], None))

    def update(self, **extra) -> dict:
        state = {"phase": "tool", "detail": "terminal: tail -n 200 /var/log/export.log", "outputTokens": 812, "contextPercent": 41,
                 "needsAttention": False, "startedAtUnix": 1792700000.0, "endedAtUnix": None, "goal": self.GOAL}
        return {"timestamp": 1792700100, "event": "update", "content-state": state, **extra}

    def start(self) -> dict:
        state = {"phase": "thinking", "detail": "Thinking…", "outputTokens": 0, "contextPercent": None, "needsAttention": False,
                 "startedAtUnix": 1792700000.0, "endedAtUnix": None, "goal": self.GOAL}
        attrs = {"storedSessionID": "3f6c2a1e9b", "connectionID": "C0FFEE00-0000-4000-8000-000000000001", "model": "", **self.NAMES}
        return {"timestamp": 1792700000, "event": "start", "content-state": state, "attributes-type": "HermesTurnAttributes", "attributes": attrs}

    def assert_no_names(self, body: dict) -> None:
        text = json.dumps(body, ensure_ascii=False)
        for word in ("nightly", "export", "Archivist", "archivist", "FF8800", "pebble", "tail -n", "/var/log"):
            self.assertNotIn(word, text)

    def test_an_update_seals_the_goal_and_keeps_only_fixed_words_plain(self) -> None:
        body = self.send(self.device(), self.update())
        state = body["content_state"]
        self.assertNotIn("goal", state)
        self.assertLessEqual(set(state), self.PLAIN_STATE)
        self.assertIn(state["detail"], self.FIXED_WORDS)
        self.assertEqual(self.opened(state["sealed"]), {"goal": self.GOAL})
        self.assert_no_names(body)

    def test_a_push_to_start_seals_the_names_and_keeps_the_ids_plain(self) -> None:
        body = self.send(self.device(), self.start())
        attrs = body["attributes"]
        for key in self.NAMES:
            self.assertEqual(attrs[key], "")
        self.assertEqual((attrs["storedSessionID"], attrs["connectionID"], attrs["model"]), ("3f6c2a1e9b", "C0FFEE00-0000-4000-8000-000000000001", ""))
        self.assertEqual(set(attrs), {*self.NAMES, "storedSessionID", "connectionID", "model", "sealed"})
        self.assertEqual(self.opened(body["content_state"]["sealed"]), {"goal": self.GOAL})
        self.assertEqual(self.opened(attrs["sealed"]), {"title": self.NAMES["sessionTitle"], "bot": "Archivist", "profile": "archivist",
                                                         "hex": "#FF8800", "avatar": "animated:pebble"})
        self.assert_no_names(body)

    def test_an_approvals_alert_is_titled_vory(self) -> None:
        alert = {"title": "Archivist", "body": "Approval needed. Tap to answer. It waits for you.", "sound": "default"}
        body = self.send(self.device(), self.update(alert=alert))
        self.assertEqual(body["alert"], {**alert, "title": "Vory"})
        self.assert_no_names(body)

    def test_an_app_that_does_not_open_sealed_fields_gets_todays_payload(self) -> None:
        alert = {"title": "Archivist", "body": "Approval needed. Tap to answer. It waits for you."}
        body = self.send(self.device(sealed=False), {**self.start(), "alert": alert})
        self.assertEqual(body["content_state"]["goal"], self.GOAL)
        self.assertNotIn("sealed", body["content_state"])
        self.assertEqual({k: body["attributes"][k] for k in self.NAMES}, self.NAMES)
        self.assertNotIn("sealed", body["attributes"])
        self.assertEqual(body["alert"]["title"], "Archivist")
        self.assertEqual(self.sealed, [])

    def test_direct_mode_is_unchanged(self) -> None:
        apns = hermes_push.APNs()
        apns.direct, apns.dry_run = True, True
        device = {k: v for k, v in self.device().items() if k != "relay"}
        with self.assertLogs(hermes_push.log, level="INFO") as logs:
            self.assertTrue(apns.send(device, {"aps": self.start()}, push_type="liveactivity", token_override="la-token"))
        # The dry run logs the payload's first 300 characters: the goal line is among them, plain, and nothing is sealed.
        self.assertTrue(any(self.GOAL in line for line in logs.output))
        self.assertFalse(any("sealed" in line for line in logs.output))
        self.assertEqual((self.posted, self.sealed), ([], []))

    def test_the_longest_push_to_start_fits_apples_limit(self) -> None:
        # The goal line at its longest (160 characters, each four bytes in UTF-8) and a 300-character chat title.
        aps = self.start()
        aps["content-state"]["goal"] = "😀" * 160
        aps["attributes"]["sessionTitle"] = "T" * 300
        aps["alert"] = {"title": "Archivist", "body": "Approval needed. Tap to answer. It waits for you.", "sound": "default"}
        body = self.send(self.device(), aps)
        # What the relay hands Apple: the aps dictionary rebuilt from the posted fields.
        forwarded = {"aps": {"timestamp": aps["timestamp"], "event": body["event"], "content-state": body["content_state"],
                             "attributes-type": "HermesTurnAttributes", "attributes": body["attributes"], "alert": body["alert"],
                             "dismissal-date": 1792790000}}
        size = len(json.dumps(forwarded, separators=(",", ":"), ensure_ascii=False).encode())
        self.assertLess(size, 4096, f"the push is {size} bytes")

    @unittest.skipUnless(_have_aesgcm(), "needs the cryptography package")
    def test_the_sealing_matches_the_apps_vector(self) -> None:
        # The sealer itself, with the nonce pinned, against the vector the app's PushRelayCryptoTests opens: a zero key,
        # a zero nonce and {"title":"hi","body":"there"}. Both sides agree byte for byte.
        import base64
        saved, os.urandom = os.urandom, (lambda n: bytes(n))   # the sealer draws its nonce from os.urandom
        try:
            blob = self.real_encrypt({"payload_key": base64.b64encode(bytes(32)).decode()}, {"title": "hi", "body": "there"})
        finally:
            os.urandom = saved
        self.assertEqual(blob, APP_VECTOR)


#: The vector in the app's PushRelayCryptoTests.decryptsCompanionVector (VoryTests/HermesRemoteTests.swift).
APP_VECTOR = "AAAAAAAAAAAAAAAAtYU0VDkMDkw9bK26mN+/eh0EeugNhF4ctNCQrAgnBvQ6vurB94SMNXCYlKJV"


# -- a gateway after Hermes's update --------------------------------------------------------


def webapp_token() -> str:
    """A token of the Webapp's form, made by the test: 43 characters of A-Za-z0-9_-."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    return "".join(secrets.choice(alphabet) for _ in range(43))


class Answer:
    def __init__(self, body: bytes) -> None:
        self.body = body
        self.status = 200
    def read(self) -> bytes: return self.body
    def __enter__(self): return self
    def __exit__(self, *a) -> None: return None


class Rest:
    """urllib.request.urlopen stood in for, so nothing leaves the machine: each request answered as `answer(req)` says,
    (status, body), and its session token kept."""

    def __init__(self, test: unittest.TestCase, answer) -> None:
        import urllib.request
        self.tokens: list[str | None] = []
        real = urllib.request.urlopen

        def urlopen(req, timeout=None):
            self.tokens.append(req.get_header("X-hermes-session-token"))
            status, body = answer(req)
            if status >= 400:
                raise urllib.error.HTTPError(req.full_url, status, "Unauthorized" if status == 401 else "Error", {}, io.BytesIO(body))
            return Answer(body)

        urllib.request.urlopen = urlopen
        test.addCleanup(setattr, urllib.request, "urlopen", real)


def takes(token: str):
    """A REST answer that takes one session token: 200, else 401 as Hermes after its update answers."""
    return lambda req: (200, b'{"ok": true}') if req.get_header("X-hermes-session-token") == token else (401, b'{"detail": "Unauthorized"}')


class TokenGateway:
    """A local socket gateway that takes one session token, if it's given one: any other is accepted, then closed 4401,
    as Hermes after its update does. Every upgrade's token is kept, as the gateway decodes it."""

    def __init__(self, accepts: str | None) -> None:
        self.accepts = accepts
        self.tokens: list[str] = []

    async def handler(self, ws) -> None:
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(ws.request.path).query)
        token = (query.get("token") or [""])[0]
        self.tokens.append(token)
        if self.accepts is not None and token != self.accepts:
            await ws.close(4401, "unauthorized")
            return
        await FakeGateway("ok").handler(ws)


class OwnHome:
    """A home of the test's own: Hermes's home, the push folder and the conf, the conf as the test writes it."""

    def own_home(self, conf: dict[str, str]) -> Path:
        d = tempfile.TemporaryDirectory(prefix="companion-test-home-")
        self.addCleanup(d.cleanup)
        keys = ("HERMES_HOME", "HERMES_PUSH_DEVICES_DIR", "HERMES_PUSH_CONFIG", "HERMES_PUSH_GATEWAY_URL")
        saved = {k: os.environ.get(k) for k in keys}

        def restore() -> None:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            hermes_push._CONF.clear()
            hermes_push._CONF_PATH = None
            hermes_push._load_conf()

        self.addCleanup(restore)
        home = Path(d.name)
        _use_home(home)
        os.environ.pop("HERMES_PUSH_GATEWAY_URL", None)   # the conf names it
        (home / "push").mkdir(parents=True)
        (home / "push" / "hermes-push.conf").write_text("".join(f"{k}={v}\n" for k, v in conf.items()), encoding="utf-8")
        hermes_push._CONF.clear()
        hermes_push._CONF_PATH = None
        hermes_push._load_conf()
        return home

    @staticmethod
    def write_webapp_token(home: Path, token: str, mode: int = 0o600) -> Path:
        folder = home / "webapp"
        folder.mkdir(mode=0o700, exist_ok=True)
        path = folder / "session-token"
        path.write_text(token + "\n", encoding="utf-8")
        path.chmod(mode)
        return path

    def count_reads(self, path: Path) -> list[int]:
        """How often `path` is read, by any version of the companion."""
        reads = [0]
        real = Path.read_text

        def read_text(p, *a, **k):
            if Path(p) == path:
                reads[0] += 1
            return real(p, *a, **k)

        Path.read_text = read_text
        self.addCleanup(setattr, Path, "read_text", real)
        return reads


class MigratedGatewayTests(OwnHome, unittest.IsolatedAsyncioTestCase):
    """A gateway after Hermes's update: its Webapp's session token in place of the companion's, error text with no
    credential in it, a token that arrives whole, approvals and questions as events, a failed turn's words, the title
    from session.info, and new code taken while cut off."""

    async def serve(self, accepts: str | None):
        fake = TokenGateway(accepts)
        server = await websockets.serve(fake.handler, "127.0.0.1", 0)

        async def stop() -> None:
            server.close()
            await server.wait_closed()

        self.addAsyncCleanup(stop)
        return server.sockets[0].getsockname()[1], fake

    def gateway(self):
        gw = hermes_push.Gateway()
        self.addAsyncCleanup(gw.close)
        return gw

    @staticmethod
    async def connected(gw):
        """A connect, with a bound: an older companion can wait a call's whole minute on a socket closed under it."""
        await asyncio.wait_for(gw.connect(), timeout=10)
        return gw

    # 1
    async def test_a_refused_session_token_uses_the_webapp_one(self) -> None:
        webapp = webapp_token()
        port, fake = await self.serve(accepts=webapp)
        home = self.own_home({"HERMES_PUSH_GATEWAY_URL": f"http://127.0.0.1:{port}", "HERMES_PUSH_GATEWAY_TOKEN": "configured-token"})
        self.write_webapp_token(home, webapp)
        rest = Rest(self, takes(webapp))
        # REST: the configured token, refused; the Webapp's, once refused; then the Webapp's straight away.
        gw = self.gateway()
        self.assertEqual(gw._http("GET", "/api/status"), {"ok": True})
        self.assertEqual(gw._http("GET", "/api/status"), {"ok": True})
        self.assertEqual(rest.tokens, ["configured-token", webapp, webapp])
        # The socket: the configured token closed 4401, then the Webapp's taken, in the one connect.
        sock = self.gateway()
        await self.connected(sock)
        self.assertEqual(fake.tokens, ["configured-token", webapp])
        self.assertEqual(await sock.call("session.list"), {})
        self.assertTrue(sock.transport.endswith("(Webapp session token)"), sock.transport)

    # 2
    async def test_the_webapp_token_is_never_written_or_logged(self) -> None:
        webapp = webapp_token()
        port, _ = await self.serve(accepts=webapp)
        home = self.own_home({"HERMES_PUSH_GATEWAY_URL": f"http://127.0.0.1:{port}", "HERMES_PUSH_GATEWAY_TOKEN": "configured-token"})
        path = self.write_webapp_token(home, webapp)
        conf = (home / "push" / "hermes-push.conf").read_bytes()
        gw = self.gateway()
        with self.assertLogs("hermes-push", level="DEBUG") as logs:
            await self.connected(gw)
        hermes_push.write_status(transport=gw.transport)
        status = hermes_push.status_path().read_text(encoding="utf-8")
        self.assertEqual((home / "push" / "hermes-push.conf").read_bytes(), conf, "the conf was written")
        self.assertNotIn(webapp, "\n".join(logs.output))
        self.assertIn(str(path), "\n".join(logs.output), "the log doesn't name the file")
        self.assertNotIn(webapp, status)
        self.assertIn("Webapp session token", status)
        self.assertNotIn(webapp, json.dumps(gw.headers))

    # 3
    async def test_an_unusable_token_file_says_what_to_do(self) -> None:
        for case in ("missing", "unreadable", "malformed", "not UTF-8"):
            with self.subTest(case=case):
                port, _ = await self.serve(accepts=webapp_token())
                home = self.own_home({"HERMES_PUSH_GATEWAY_URL": f"http://127.0.0.1:{port}", "HERMES_PUSH_GATEWAY_TOKEN": "configured-token"})
                if case == "unreadable":
                    self.write_webapp_token(home, webapp_token(), mode=0o000)
                elif case == "malformed":
                    self.write_webapp_token(home, "too-short")
                elif case == "not UTF-8":
                    # A token's length, but bytes no UTF-8 reader takes: the words, never the codec's message.
                    self.write_webapp_token(home, "").write_bytes(b"\xff\xfe" + b"A" * 41)
                Rest(self, takes("nothing"))
                with self.assertRaises(RuntimeError) as rest:
                    self.gateway()._http("GET", "/api/status")
                self.assertIn("set the companion up again", str(rest.exception))
                with self.assertRaises(ConnectionError) as sock:
                    await self.connected(self.gateway())
                self.assertIn("set the companion up again", str(sock.exception))

    # 4
    async def test_error_text_carries_no_credential(self) -> None:
        # The broken address: a fragment in the URL makes the socket's address invalid, and the error names it whole.
        self.own_home({"HERMES_PUSH_GATEWAY_URL": "http://127.0.0.1:9/#frag", "HERMES_PUSH_GATEWAY_TOKEN": "secret-token-value"})
        with self.assertRaises(ConnectionError) as caught:
            await self.connected(self.gateway())
        self.assertNotIn("secret-token-value", str(caught.exception))
        # A header whose value echoes the query (a redirect's Location).
        header = websockets.exceptions.InvalidHeader("Location", "wss://gateway.example/api/ws?ticket=secret-ticket&x=1")
        self.assertNotIn("secret-ticket", hermes_push.describe_error(header))
        self.assertEqual(hermes_push._scrub("ws://h/api/ws?a=1&token=abc def"), "ws://h/api/ws?a=1&token=*** def")

    # 5
    async def test_a_token_with_url_characters_arrives_whole(self) -> None:
        token = "a#b&c=d+e%f g"
        port, fake = await self.serve(accepts=None)
        self.own_home({"HERMES_PUSH_GATEWAY_URL": f"http://127.0.0.1:{port}", "HERMES_PUSH_GATEWAY_TOKEN": token})
        await self.connected(self.gateway())
        self.assertEqual(fake.tokens, [token])

    # 6
    async def test_a_refused_sign_in_says_why(self) -> None:
        self.own_home({"HERMES_PUSH_GATEWAY_URL": "http://127.0.0.1:9", "HERMES_PUSH_GATEWAY_BEARER": "old-bearer",
                       "HERMES_PUSH_GATEWAY_REFRESH_TOKEN": "old-refresh"})
        Rest(self, lambda req: (401, b'{"error": "session_expired"}'))
        with self.assertRaises(ConnectionError) as caught:
            await self.connected(self.gateway())
        # The words the app's rule matches, exactly, and why it can happen.
        self.assertIn("sign-in rejected", str(caught.exception))
        self.assertIn("A Hermes update can end every sign-in once.", str(caught.exception))

    # 17
    async def test_cloudflare_blocking_the_ticket_names_the_access_token(self) -> None:
        self.own_home({"HERMES_PUSH_GATEWAY_URL": "https://gateway.example.test", "HERMES_PUSH_GATEWAY_BEARER": "a-bearer"})
        Rest(self, lambda req: (403, b"<html><title>Access denied | Cloudflare</title></html>"))
        with self.assertRaises(ConnectionError) as caught:
            await self.connected(self.gateway())
        # The Access hint reaches the status whole, not read as nothing listening.
        self.assertIn("Cloudflare blocked it: the companion needs the Access service token", str(caught.exception))
        self.assertNotIn("connection refused", str(caught.exception))

    def relay(self, home_conf: dict[str, str] | None = None):
        self.own_home(home_conf or {"HERMES_PUSH_GATEWAY_URL": "http://127.0.0.1:9", "HERMES_PUSH_GATEWAY_TOKEN": "t"})
        relay = hermes_push.Relay()
        relay.pushes = []
        relay.settled = []
        relay.open_approvals, relay.la_usage, relay.la_phase = {}, {}, {}
        relay._turn_pushed_at, relay._finish_pushed = {}, {}
        relay.push_all = lambda kind, title, body, meta, **k: relay.pushes.append((kind, title, body))
        relay.update_live_activities = lambda *a, **k: set()
        relay.end_live_activities = lambda *a, **k: None
        return relay

    # 7
    async def test_an_approval_event_pushes_once(self) -> None:
        relay = self.relay()
        ev = {"type": "approval.request", "session_id": "s1", "payload": {"prompt_id": "p1", "command": "rm -rf build", "description": "Delete the build folder"}}
        relay.on_event(ev)
        relay.on_event(ev)
        self.assertEqual([p[0] for p in relay.pushes], ["approval"], "the event didn't push, or pushed twice")
        self.assertIn("Delete the build folder", relay.pushes[0][2])
        self.assertEqual(relay.open_approvals["p1"]["req"], "p1")
        # The server request for the same prompt: not pushed again.
        relay.handle_request("s1", "p1", "approval", {"command": "rm -rf build", "request_id": "p1"})
        self.assertEqual(len(relay.pushes), 1)

    # 8
    async def test_a_question_event_pushes_once(self) -> None:
        relay = self.relay()
        ev = {"type": "clarify.request", "session_id": "s1", "payload": {"prompt_id": "q1", "question": "Which branch?"}}
        relay.on_event(ev)
        relay.on_event(ev)
        self.assertEqual([p[0] for p in relay.pushes], ["clarify"], "the event didn't push, or pushed twice")
        self.assertIn("Which branch?", relay.pushes[0][2])
        relay.handle_request("s1", "q1", "clarify", {"question": "Which branch?"})
        self.assertEqual(len(relay.pushes), 1)

    # 9
    async def test_a_settled_event_settles_the_banner(self) -> None:
        relay = self.relay()
        relay.settle_approval = lambda rid, why="answered": (relay.open_approvals.pop(rid, None), relay.settled.append((rid, why)))
        for rid in ("p1", "p2"):
            relay.on_event({"type": "approval.request", "session_id": "s1", "payload": {"prompt_id": rid, "command": "ls"}})
        answers = hermes_push.answers_dir()
        answers.mkdir(parents=True, exist_ok=True)
        (answers / "p2.json").write_text(json.dumps({"device_id": "phone-1", "at": time.time()}), encoding="utf-8")
        relay.on_event({"type": "approval.settled", "session_id": "s1", "payload": {"prompt_id": "p1", "execution_generation": 2}})
        relay.on_event({"type": "approval.settled", "session_id": "s1", "payload": {"prompt_id": "p2", "execution_generation": 2}})
        self.assertEqual(relay.settled, [("p1", "withdrawn"), ("p2", "answered")])
        self.assertNotIn("p1", relay.notified)

    # 10
    async def test_a_sudo_request_still_pushes(self) -> None:
        relay = self.relay()
        relay.handle_request("s1", "sudo-1", "sudo", {"prompt": "Password for sudo"})
        self.assertEqual([p[0] for p in relay.pushes], ["clarify"])
        self.assertIn("input needed", relay.pushes[0][1])

    # 11
    async def test_a_failed_turn_pushes_as_failed(self) -> None:
        relay = self.relay()

        async def no_thread(sid, a):
            return []

        relay._recent_thread = no_thread
        relay.attached = {"s1": {"title": "Nightly", "stored": "st-1", "bot": "Hermes"},
                          "s2": {"title": "Export", "stored": "st-2", "bot": "Hermes"}}
        await relay._finish_turn("s1", relay.attached["s1"], {"status": "error", "text": "", "failure_reason": "gateway_connection"})
        kind, title, body = relay.pushes[-1]
        self.assertEqual(kind, "error")
        self.assertIn("turn failed", title)
        self.assertIn("The turn failed.", body)
        self.assertNotIn("gateway_connection", body, "a code was shown")
        # A failed turn that left its own words is pushed as those words, as before.
        await relay._finish_turn("s2", relay.attached["s2"], {"status": "error", "text": "Error: the compute host stopped"})
        kind, _, body = relay.pushes[-1]
        self.assertEqual(kind, "turn")
        self.assertIn("Error: the compute host stopped", body)

    # 12
    async def test_the_title_follows_session_info(self) -> None:
        relay = self.relay()
        relay.attached = {"s1": {"title": "Old", "stored": "st-1"}}
        relay.on_event({"type": "session.info", "session_id": "s1", "payload": {"title": "New"}})
        self.assertEqual(relay.attached["s1"]["title"], "New")
        relay.on_event({"type": "session.info", "session_id": "s1", "payload": {"running": False}})
        self.assertEqual(relay.attached["s1"]["title"], "New")

    # 13
    async def test_new_code_is_picked_up_while_cut_off(self) -> None:
        relay = self.relay()

        async def refused() -> None:
            raise ConnectionError("http://127.0.0.1:9: connection refused (nothing listens there on this machine)")

        async def nothing() -> None:
            return None

        relay.gw = types.SimpleNamespace(connect=refused, close=nothing, public_url="http://127.0.0.1:9", transport="", server_requests=None)
        relay._status = lambda **fields: None
        asked = [0]
        real = hermes_push.code_changed

        def code_changed() -> bool:
            asked[0] += 1
            return asked[0] > 1   # the code is replaced once the relay is cut off

        hermes_push.code_changed = code_changed
        self.addCleanup(setattr, hermes_push, "code_changed", real)
        with self.assertRaises(hermes_push.CodeChanged):
            await asyncio.wait_for(relay.run(), timeout=5)

    # 14
    async def test_a_refused_token_on_another_host_never_opens_the_file(self) -> None:
        for url in ("http://192.0.2.10:9129", "http://127.0.0.1.example.test:9129", "http://localhost.example.test:9129"):
            with self.subTest(url=url):
                webapp = webapp_token()
                home = self.own_home({"HERMES_PUSH_GATEWAY_URL": url, "HERMES_PUSH_GATEWAY_TOKEN": "configured-token"})
                path = self.write_webapp_token(home, webapp)
                reads = self.count_reads(path)
                rest = Rest(self, takes(webapp))
                gw = hermes_push.Gateway()
                with self.assertRaises(Exception):
                    gw._http("GET", "/api/status")
                try:
                    address, _ = gw._ws_for(gw.url)   # the socket's address only: nothing is opened
                except Exception:  # noqa: BLE001
                    address = ""
                self.assertEqual(reads[0], 0, "the Webapp token's file was opened")
                self.assertNotIn(webapp, rest.tokens)
                self.assertNotIn(webapp, address)

    # 15
    async def test_a_refused_token_on_loopback_uses_the_file(self) -> None:
        for url in ("http://127.0.0.1:9129", "http://localhost:9129", "http://[::1]:9129"):
            with self.subTest(url=url):
                webapp = webapp_token()
                home = self.own_home({"HERMES_PUSH_GATEWAY_URL": url, "HERMES_PUSH_GATEWAY_TOKEN": "configured-token"})
                path = self.write_webapp_token(home, webapp)
                reads = self.count_reads(path)
                Rest(self, takes(webapp))
                gw = hermes_push.Gateway()
                self.assertEqual(gw._http("GET", "/api/status"), {"ok": True})
                address, how = gw._ws_for(gw.url)
                self.assertIn("token=" + urllib.parse.quote(webapp, safe=""), address)
                self.assertEqual(how, "Webapp session token")
                self.assertEqual(reads[0], 2, "the file wasn't read at each use")

    # 16
    async def test_a_conf_change_clears_the_refusal(self) -> None:
        home = self.own_home({"HERMES_PUSH_GATEWAY_URL": "http://127.0.0.1:9", "HERMES_PUSH_GATEWAY_TOKEN": "old-token"})
        reads = self.count_reads(home / "webapp" / "session-token")
        Rest(self, takes("new-working-token"))
        gw = hermes_push.Gateway()
        with self.assertRaises(RuntimeError):
            gw._http("GET", "/api/status")
        self.assertTrue(gw.token_refused)
        # The app writes the conf again with a working token; the relay builds a new Gateway from it (_reload_config).
        (home / "push" / "hermes-push.conf").write_text("HERMES_PUSH_GATEWAY_URL=http://127.0.0.1:9\nHERMES_PUSH_GATEWAY_TOKEN=new-working-token\n",
                                                       encoding="utf-8")
        hermes_push._CONF.clear()
        hermes_push._load_conf()
        reads[0] = 0
        gw = hermes_push.Gateway()
        self.assertFalse(gw.token_refused)
        self.assertEqual(gw._http("GET", "/api/status"), {"ok": True})
        self.assertEqual(reads[0], 0, "the Webapp token's file was read after the conf change")
