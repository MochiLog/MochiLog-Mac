"""Offline protocol tests: fragmented replies, hostile framing and denied reads."""
import importlib.util
import contextlib
import gzip
import hashlib
import io
import json
import pathlib
import plistlib
import struct
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest import mock


def load(name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load("independent_diagnostics")
wire = load("remote_wire")
archive = load("relay_archive")
core = load("coredevice_readonly")


class Fragmented:
    def __init__(self, replies, fragment=3):
        self.replies, self.fragment, self.requests = bytearray(replies), fragment, []

    def read(self, length):
        count = min(length, self.fragment, len(self.replies))
        value = bytes(self.replies[:count])
        del self.replies[:count]
        return value

    def write(self, data):
        self.requests.append(data)


def reply(sequence, operation, data):
    return struct.pack("<8sQQQQ", b"CFA6LPAA", 40 + len(data), 40 + len(data), sequence, operation) + data


class ProtocolTests(unittest.TestCase):
    def test_coredevice_wire_types_and_fixed_readonly_requests(self):
        self.assertEqual(wire.encode(wire.Signed(2)), bytes.fromhex("003000000200000000000000"))
        self.assertEqual(wire.Decoder(wire.encode([629, wire.Signed(2)])).value(), [629, 2])
        class Channel:
            def __init__(self):
                self.requests = []
            def bootstrap(self):
                pass
            def frame(self, kind, stream, data):
                self.requests.append(wire.decode_wrapper(data))
            def receive(self):
                return {"CoreDevice.output": {"passcodeRequired": True,
                    "unlockedSinceBoot": True, "deviceIdentifier": "private-test-device"}}
        channel, events = Channel(), []
        core.probe(channel, wire, "coredevice-lock-state", None,
            lambda stage, **values: events.append((stage, values)), probe.ProbeError)
        self.assertEqual(channel.requests[0]["CoreDevice.featureIdentifier"], "com.apple.coredevice.feature.getlockstate")
        self.assertNotIn("private-test-device", str(events))
        self.assertTrue(events[-1][1]["state_fields_complete"])

    def test_coredevice_file_denial_never_becomes_body_success(self):
        class Channel:
            def __init__(self):
                self.requests = []
            def bootstrap(self):
                pass
            def frame(self, kind, stream, data):
                self.requests.append(wire.decode_wrapper(data))
            def receive(self):
                return {"NewSessionID": "private-test-session"} if len(self.requests) == 1 else {"EncodedError": b"private-test-error"}
        channel, events = Channel(), []
        with self.assertRaises(probe.ProbeError):
            core.probe(channel, wire, "coredevice-file-open", "/Retired/Analytics-report",
                lambda stage, **values: events.append((stage, values)), probe.ProbeError)
        self.assertEqual([item["Cmd"] for item in channel.requests], ["CreateSession", "RetrieveFile"])
        self.assertEqual(channel.requests[0]["Domain"], 5)
        self.assertEqual(channel.requests[1]["Path"], "Retired/Analytics-report")
        self.assertNotIn("private-test", str(events))
        self.assertNotIn("file_complete", str(events))

    @staticmethod
    def cpio_member(name, body=b"", newc=False):
        name = name.encode() + b"\0"
        if newc:
            fields = [0, 0o100600, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name), 0]
            header = b"070701" + b"".join(f"{value:08x}".encode() for value in fields)
            return header + name + b"\0" * (-(len(header) + len(name)) % 4) + body + b"\0" * (-len(body) % 4)
        fields = [0, 0, 0o100600, 0, 0, 1, 0]
        header = b"070707" + b"".join(f"{value:06o}".encode() for value in fields)
        header += f"{0:011o}{len(name):06o}{len(body):011o}".encode()
        return header + name + body

    def test_relay_complete_stream_requires_gzip_and_cpio_completion(self):
        filename = "Analytics-2026-10-07-090004.ips.ca.synced"
        body = b"test-report\n"
        for newc in (False, True):
            raw = self.cpio_member("var/mobile/Library/Logs/CrashReporter/Retired/" + filename, body, newc)
            raw += self.cpio_member("TRAILER!!!", newc=newc)
            events = []
            archive.read_archive(Fragmented(gzip.compress(raw)), filename,
                                 lambda stage, **values: events.append((stage, values)))
            self.assertEqual(events[-1], ("file_complete", {"acquisition": "file_relay_archive",
                "bytes": len(body), "lines": 1, "sha256": hashlib.sha256(body).hexdigest()}))

    def test_relay_malformed_archive_is_drained_without_success(self):
        for data in (gzip.compress(b"not-cpio"), gzip.compress(b"invalid-header")[:-4]):
            stream, events = Fragmented(data), []
            with self.assertRaises(archive.ArchiveError):
                archive.read_archive(stream, "report", lambda stage, **values: events.append(stage))
            self.assertFalse(stream.replies)
            self.assertIn("relay_archive_drained", events)
            self.assertNotIn("file_complete", events)

    def test_relay_ignores_watch_and_rejects_ambiguous_or_missing_body(self):
        filename = "Analytics-report"
        watch = self.cpio_member("ProxiedDevice-123/Retired/" + filename, b"watch\n")
        phone = self.cpio_member("Retired/" + filename, b"phone\n")
        for raw in (watch, phone + phone, b""):
            raw += self.cpio_member("TRAILER!!!")
            with self.assertRaises(archive.ArchiveError):
                archive.read_archive(Fragmented(gzip.compress(raw)), filename, lambda *a, **k: None)

    def test_relay_member_and_decode_bounds_are_enforced(self):
        oversized = bytearray(self.cpio_member("report"))
        oversized[59:65] = b"777777"
        parser = archive.Cpio("report")
        with self.assertRaises(archive.ArchiveError):
            parser.feed(oversized)
        raw = self.cpio_member("report", b"test") + self.cpio_member("TRAILER!!!")
        stream = Fragmented(gzip.compress(raw))
        with mock.patch.object(archive, "DECODED_LIMIT", 10), self.assertRaises(archive.ArchiveError):
            archive.read_archive(stream, "report", lambda *a, **k: None)
        self.assertFalse(stream.replies)

    def test_checkin_shape_omits_private_values_and_unknown_field_names(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            probe.validate_checkin_response({"Request": "StartService", "Error": None,
                "private-test-identifier": "private-test-key", "EnableServiceSSL": False}, "StartService", "plain")
        shape = json.loads(output.getvalue().splitlines()[0])
        self.assertEqual(shape["other_field_count"], 1)
        self.assertFalse(shape["service_ssl_required"])
        self.assertNotIn("private-test", output.getvalue())

    def test_checkin_rejects_empty_error_and_tls_downgrade(self):
        for response in ({"Request": "StartService", "Error": ""},
                         {"Request": "StartService", "Error": {}},
                         {"Request": "StartService", "EnableServiceSSL": True},
                         {"Request": "DifferentResponse"}):
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(probe.ProbeError):
                probe.validate_checkin_response(response, "StartService", "os-escrow")

    def test_private_os_key_pipe_is_bounded_and_missing_key_fails(self):
        args = SimpleNamespace(tunnel_helper=pathlib.Path("/fixture/native_tunnel"), udid="test-device")
        fixture = b"private-test-credential"
        headers = ({"stage": "existing_os_key_ready", "length": len(fixture)},
                   {"stage": "existing_os_key_ready", "length": 4097},
                   {"stage": "existing_os_key_unavailable"})
        for header in headers:
            stream = io.BytesIO(json.dumps(header).encode() + b"\n" + fixture)
            process = SimpleNamespace(stdout=stream, poll=lambda: 0)
            with mock.patch.object(probe.subprocess, "Popen", return_value=process) as launch, \
                    mock.patch.object(probe.select, "select", return_value=([stream], [], [])):
                if header.get("length") == len(fixture):
                    self.assertEqual(probe.existing_os_remote_key(args), fixture)
                else:
                    with self.assertRaises(probe.ProbeError):
                        probe.existing_os_remote_key(args)
                self.assertEqual(launch.call_args.args[0], ["/fixture/native_tunnel", "--existing-key-only", "test-device"])
            self.assertTrue(stream.closed)

    def test_alternate_xpc_bootstrap_does_not_send_service_rpc(self):
        incoming = b"\0\0\0\x04\0" + struct.pack(">I", 0)
        class Socket:
            def __init__(self):
                self.channel = Fragmented(incoming)
            def recv(self, length):
                return self.channel.read(length)
            def sendall(self, data):
                self.channel.write(data)
        rsd = wire.Rsd.__new__(wire.Rsd)
        rsd.socket, rsd.buffers = Socket(), {}
        rsd.bootstrap()
        messages = [wire.decode_wrapper(frame[9:]) for frame in rsd.socket.channel.requests[1:]
                    if frame[3] == 0]
        self.assertEqual(messages, [{}, None, None])

    def test_existing_os_key_never_printed_or_regenerated(self):
        fixture = b"test-only-key-material"
        args = SimpleNamespace(file="/Retired/Analytics-2026-10-07-090004.ips.ca.synced", probe="os-key-status")
        output = io.StringIO()
        with mock.patch.object(probe, "existing_os_remote_key", return_value=fixture), \
                mock.patch.object(probe, "existing_record", return_value={"remote_unlock_host_key": "dGVzdC1vbmx5LWtleS1tYXRlcmlhbA=="}), \
                contextlib.redirect_stdout(output):
            probe.run(args)
        event = json.loads(output.getvalue())
        self.assertTrue(event["same_as_saved_tool_credential"])
        self.assertNotIn(fixture.decode(), output.getvalue())
        self.assertNotIn("dGVzdC1vbmx5", output.getvalue())

    def test_live_diagnostics_are_not_daily_analytics_and_do_not_expose_serial(self):
        data = plistlib.dumps({"Status": "Success", "Diagnostics": {
            "IORegistry": {"CycleCount": 20, "BatterySerialNumber": "private-test-serial", "DesignCapacity": 100}}})
        stream = Fragmented(struct.pack(">I", len(data)) + data)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            probe.read_only_diagnostic_query(stream, "power-registry")
        event = json.loads(output.getvalue())
        self.assertFalse(event["daily_analytics_acquired"])
        self.assertEqual(event["available_metrics"], ["CycleCount", "DesignCapacity"])
        self.assertNotIn("private-test-serial", output.getvalue())
        self.assertEqual(plistlib.loads(stream.requests[0][4:]), {"Request": "IORegistry", "EntryClass": "IOPMPowerSource"})

    def test_fragmented_http2_and_unexpected_stream(self):
        def frame(kind, stream, data):
            return len(data).to_bytes(3, "big") + bytes((kind, 0)) + struct.pack(">I", stream) + data
        packet = wire.wrapper({"Properties": {"UniqueDeviceID": "test"}, "Services": {}})
        class Socket:
            def __init__(self, data):
                self.channel = Fragmented(data)
            def recv(self, size):
                return self.channel.read(size)
            def sendall(self, data):
                self.channel.write(data)
        rsd = wire.Rsd.__new__(wire.Rsd)
        rsd.socket, rsd.buffers = Socket(frame(4, 0, b"") + frame(0, 1, packet)), {}
        self.assertEqual(rsd.receive()["Properties"]["UniqueDeviceID"], "test")
        rsd.socket, rsd.buffers = Socket(frame(0, 999, packet)), {}
        with self.assertRaises(ValueError):
            rsd.receive()

    def test_failed_save_leaves_no_partial_or_overwritten_file(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "report.ips"
            with mock.patch.object(probe.shutil, "copyfileobj", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    probe.publish_complete_copy(io.BytesIO(b"complete"), target)
            self.assertEqual(list(pathlib.Path(folder).iterdir()), [])
            target.write_bytes(b"existing")
            with self.assertRaises(FileExistsError):
                probe.publish_complete_copy(io.BytesIO(b"replacement"), target)
            self.assertEqual(target.read_bytes(), b"existing")
            self.assertEqual(list(pathlib.Path(folder).iterdir()), [target])

    def test_fragmented_plist_and_rejected_oversize(self):
        data = plistlib.dumps({"Request": "StartService", "Port": 1234})
        self.assertEqual(probe.Plists(Fragmented(struct.pack(">I", len(data)) + data)).receive()["Port"], 1234)
        with self.assertRaises(probe.ProbeError):
            probe.Plists(Fragmented(struct.pack(">I", probe.MAX_PACKET + 1))).receive()

    def test_denied_read_never_creates_output(self):
        # Concatenate explicitly: Python's octal escapes must not change the wire value.
        stat = b"st_ifmt\0S_IFREG\0st_size\0" + b"21327604\0"
        channel = Fragmented(reply(0, 2, stat) + reply(1, 1, struct.pack("<Q", 10)))
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "report.ips"
            with self.assertRaises(probe.AfcDenied) as error:
                probe.Afc(channel).read_file("/Retired/Analytics-report", target)
            self.assertEqual(error.exception.status, 10)
            self.assertFalse(target.exists())
        self.assertEqual(struct.unpack("<Q", channel.requests[1][40:48])[0], 1)  # read-only open

    def test_truncated_and_wrong_sequence_afc_rejected(self):
        for packet in (reply(99, 2, b"x"), reply(0, 2, b"abc")[:-1],
                       struct.pack("<8sQQQQ", b"CFA6LPAA", probe.MAX_PACKET + 1, 40, 0, 2)):
            with self.subTest(packet_length=len(packet)), self.assertRaises(probe.ProbeError):
                probe.Afc(Fragmented(packet)).operation(10, b"/\0")

    def test_complete_read_checks_body_and_closes_handle(self):
        stat = b"st_ifmt\0S_IFREG\0st_size\0" + b"5\0"
        channel = Fragmented(reply(0, 2, stat) + reply(1, 14, struct.pack("<Q", 7))
                             + reply(2, 2, b"data\n") + reply(3, 1, struct.pack("<Q", 0)))
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "report.ips"
            probe.Afc(channel).read_file("/Retired/Analytics-report", target)
            self.assertEqual(target.read_bytes(), b"data\n")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(struct.unpack("<Q", channel.requests[-1][32:40])[0], 20)

    def test_short_file_read_never_creates_success_output(self):
        stat = b"st_ifmt\0S_IFREG\0st_size\0" + b"5\0"
        channel = Fragmented(reply(0, 2, stat) + reply(1, 14, struct.pack("<Q", 7))
                             + reply(2, 2, b"") + reply(3, 1, struct.pack("<Q", 0)))
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / "report.ips"
            with self.assertRaises(probe.ProbeError):
                probe.Afc(channel).read_file("/Retired/Analytics-report", target)
            self.assertFalse(target.exists())

    def test_xpc_fixed_fixture_and_envelope_boundaries(self):
        # Known little-endian bool and empty dictionary wire fixtures, independent of encoder.
        self.assertFalse(wire.Decoder(bytes.fromhex("0020000000000000")).value())
        self.assertEqual(wire.Decoder(bytes.fromhex("00f000000400000000000000")).value(), {})
        invalid = struct.pack("<IIQQ", 0x29b00b92, 1, wire.LIMIT + 1, 0)
        with self.assertRaises(ValueError):
            wire.decode_wrapper(invalid)
        with self.assertRaises(ValueError):
            wire.Decoder(bytes.fromhex("009000000100000061000000")).value()  # missing NUL terminator

    def test_nested_discovery_and_host_identity_encoding(self):
        identity = uuid.UUID("12345678-1234-5678-1234-567812345678")
        value = {"UUID": identity, "Properties": {"RemoteXPCVersionFlags": 0x0100000000000006,
                                                "SensitivePropertiesVisible": True}, "Services": {}}
        packet = wire.wrapper(value, message_id=1)
        self.assertEqual(wire.decode_wrapper(packet), value)
        self.assertEqual(struct.unpack("<I", wire.wrapper({})[4:8])[0], 1)
        with self.assertRaises(ValueError):
            wire.decode_wrapper(packet[:-1])


if __name__ == "__main__":
    unittest.main()
