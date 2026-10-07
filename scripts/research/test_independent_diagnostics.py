"""Offline protocol tests: fragmented replies, hostile framing and denied reads."""
import importlib.util
import contextlib
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
