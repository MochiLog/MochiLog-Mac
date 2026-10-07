#!/usr/bin/env python3
"""Read-only paired-device diagnostic experiment; Python standard library only.

Wire-format references (implementations are not imported or executed):
https://github.com/libimobiledevice/libimobiledevice/blob/master/src/afc.h
https://github.com/libimobiledevice/libimobiledevice/blob/master/src/lockdown.c
https://github.com/doronz88/pymobiledevice3/blob/v11.19.1/pymobiledevice3/remote/remote_service_discovery.py

macOS remote mode holds an existing OS tunnel with our C helper, then uses our
HTTP/2/RemoteXPC discovery, plist check-in and AFC implementation over sockets.
Classic mode implements lockdownd, mutual TLS and AFC over TCP.
No pairing, unlocking, mover, write, erase or security-setting requests exist.
"""
import argparse
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import select
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import time
from datetime import datetime
from pathlib import Path

MAX_PACKET = 2 * 1024 * 1024
MAX_FILE = 128 * 1024 * 1024
SERVICE = "com.apple.crashreportcopymobile"
REMOTE_SERVICE = SERVICE + ".shim.remote"
LABEL = "MochiLog-independent-research"


class ProbeError(Exception):
    pass


class AfcDenied(ProbeError):
    def __init__(self, status, operation):
        self.status = status
        super().__init__(f"AFC status={status}, operation={operation}")


def emit(stage, **values):
    print(json.dumps({"time": datetime.now().astimezone().isoformat(),
                      "stage": stage, **values}, ensure_ascii=False), flush=True)


def exact(stream, length):
    if not 0 <= length <= MAX_PACKET:
        raise ProbeError("Invalid incoming packet size")
    parts = bytearray()
    while len(parts) < length:
        part = stream.read(length - len(parts))
        if not part:
            raise ProbeError("Connection closed before complete response")
        parts.extend(part)
    return bytes(parts)


def publish_complete_copy(source, destination):
    """Stage privately on the destination filesystem; publish without overwrite."""
    target = Path(destination)
    descriptor, staging = tempfile.mkstemp(prefix=".mochilog-research-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as saved:
            source.seek(0)
            shutil.copyfileobj(source, saved, 512 * 1024)
            saved.flush()
            os.fsync(saved.fileno())
        # Atomic visibility of a complete inode, unlike opening the final path first.
        # link() fails if a file/symlink already occupies the destination.
        os.link(staging, target)
    finally:
        os.unlink(staging)


class Pipe:
    def __init__(self, device, timeout):
        self.timeout = timeout
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            ["/usr/libexec/remotectl", "netcat", device, REMOTE_SERVICE],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            bufsize=0, start_new_session=True)

    def read(self, length):
        if not select.select([self.process.stdout], [], [], self.timeout)[0]:
            raise ProbeError("Timed out waiting for OS service data")
        data = os.read(self.process.stdout.fileno(), length)
        if not data:
            # System stderr can contain addresses and hardware identifiers.
            raise ProbeError("OS service connection closed before a response")
        return data

    def write(self, data):
        deadline = time.monotonic() + self.timeout
        while data:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.process.stdin], [], remaining)[1]:
                raise ProbeError("Timed out writing OS service data")
            count = os.write(self.process.stdin.fileno(), data)
            if not count:
                raise ProbeError("OS service write failed")
            data = data[count:]

    def close(self):
        for stream in (self.process.stdin, self.process.stdout):
            if stream:
                stream.close()
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=2)
        self.stderr.close()


class Tcp:
    def __init__(self, host, port, timeout):
        self.socket = socket.create_connection((host, port), timeout=timeout)

    def read(self, length):
        return self.socket.recv(length)

    def write(self, data):
        self.socket.sendall(data)

    def close(self):
        self.socket.close()

    def tls(self, record):
        """Mutual TLS with an existing host identity and pinned device certificate."""
        certificate = record.get("HostCertificate")
        private_key = record.get("HostPrivateKey")
        device_certificate = record.get("DeviceCertificate")
        if not all(isinstance(value, bytes) and value for value in
                   (certificate, private_key, device_certificate)):
            raise ProbeError("Existing paired TLS identity is unavailable")
        with tempfile.TemporaryDirectory(prefix="mochilog-paired-tls-") as folder:
            def pem(value, kind):
                if value.startswith(b"-----BEGIN"):
                    return value
                if kind == "certificate":
                    return ssl.DER_cert_to_PEM_cert(value).encode()
                converted = subprocess.run(
                    ["/usr/bin/openssl", "pkey", "-inform", "DER"], input=value,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
                if converted.returncode:
                    raise ProbeError("Could not decode existing host key")
                return converted.stdout
            cert_path, key_path = Path(folder) / "host.pem", Path(folder) / "host-key.pem"
            for path, value in ((cert_path, pem(certificate, "certificate")),
                                (key_path, pem(private_key, "key"))):
                with path.open("xb") as output:
                    os.chmod(path, 0o600)
                    output.write(value)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            # Self-signed pairing identity: authenticate by exact certificate pin below.
            context.verify_mode = ssl.CERT_NONE
            context.load_cert_chain(cert_path, key_path)
            self.socket = context.wrap_socket(self.socket)
        expected = device_certificate
        if expected.startswith(b"-----BEGIN"):
            expected = ssl.PEM_cert_to_DER_cert(expected.decode())
        if self.socket.getpeercert(binary_form=True) != expected:
            self.close()
            raise ProbeError("Paired device TLS certificate did not match")


class TunnelAssertion:
    def __init__(self, executable, udid):
        self.process = subprocess.Popen([str(executable), udid], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            if not select.select([self.process.stdout], [], [], 16)[0]:
                raise ProbeError("Timed out opening existing OS tunnel")
            response = json.loads(self.process.stdout.readline())
            if response.get("stage") != "native_assertion_ready":
                domain, code = response.get("domain"), response.get("code")
                if isinstance(domain, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,120}", domain) and isinstance(code, int):
                    emit("native_tunnel_rejected", domain=domain, code=code)
                raise ProbeError("OS did not grant an existing-pairing tunnel assertion")
            self.address = response["address"]
        except Exception:
            self.close()
            raise

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        self.process.stdout.close()


def existing_os_remote_key(args):
    helper = args.tunnel_helper or Path(__file__).resolve().parents[2] / "Build/research/native_tunnel"
    process = subprocess.Popen([str(helper), "--existing-key-only", args.udid], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        if not select.select([process.stdout], [], [], 16)[0]:
            raise ProbeError("Timed out reading existing OS credential")
        line = process.stdout.readline(1024)
        response = json.loads(line)
        length = response.get("length")
        if response.get("stage") != "existing_os_key_ready" or not isinstance(length, int) or not 0 < length <= 4096:
            raise ProbeError("OS paired-device snapshot has no existing remote unlock credential")
        key = process.stdout.read(length)
        if len(key) != length:
            raise ProbeError("Truncated existing OS credential response")
        return key
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        process.stdout.close()


class Plists:
    def __init__(self, stream):
        self.stream = stream

    def send(self, value):
        data = plistlib.dumps(value, fmt=plistlib.FMT_XML)
        if len(data) > MAX_PACKET:
            raise ProbeError("Outgoing plist too large")
        self.stream.write(struct.pack(">I", len(data)) + data)

    def receive(self):
        length = struct.unpack(">I", exact(self.stream, 4))[0]
        value = plistlib.loads(exact(self.stream, length))
        if not isinstance(value, dict):
            raise ProbeError("Service response is not a dictionary")
        return value

    def request(self, name, **values):
        self.send({"Label": LABEL, "Request": name, **values})
        response = self.receive()
        if response.get("Error"):
            # Do not serialize the full response: it can contain private identifiers.
            error = response["Error"]
            if not isinstance(error, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", error):
                error = "DeviceError"
            raise ProbeError(f"{name} rejected: {error}")
        return response


class Afc:
    def __init__(self, stream):
        self.stream = stream
        self.sequence = 0

    def operation(self, opcode, payload=b""):
        sequence = self.sequence
        self.sequence += 1
        total = 40 + len(payload)
        self.stream.write(struct.pack("<8sQQQQ", b"CFA6LPAA", total, total, sequence, opcode) + payload)
        magic, full, header, echoed, operation = struct.unpack("<8sQQQQ", exact(self.stream, 40))
        if magic != b"CFA6LPAA" or not 40 <= header <= full <= MAX_PACKET or echoed != sequence:
            raise ProbeError("Invalid or mismatched AFC response header")
        data = exact(self.stream, full - 40)
        if operation == 1:
            if len(data) != 8:
                raise ProbeError("Invalid AFC status response")
            status = struct.unpack("<Q", data)[0]
            if status:
                raise AfcDenied(status, opcode)
        return operation, data

    def stat(self, path):
        operation, data = self.operation(10, path.encode() + b"\0")
        if operation != 2 or not data.endswith(b"\0"):
            raise ProbeError("Invalid AFC stat response")
        entries = data[:-1].decode().split("\0")
        if len(entries) % 2:
            raise ProbeError("Invalid AFC stat fields")
        return dict(zip(entries[::2], entries[1::2]))

    def read_file(self, path, destination):
        info = self.stat(path)
        if info.get("st_ifmt") != "S_IFREG":
            raise ProbeError("Requested report is not a regular file")
        size = int(info["st_size"])
        if not 0 < size <= MAX_FILE:
            raise ProbeError("Empty or oversized report; not accepted as a successful read")
        emit("file_metadata", bytes=size)
        operation, data = self.operation(13, struct.pack("<Q", 1) + path.encode() + b"\0")
        if operation != 14 or len(data) != 8:
            raise ProbeError("Invalid AFC open response")
        handle = struct.unpack("<Q", data)[0]
        emit("file_opened", mode="read_only")
        digest, received, lines = hashlib.sha256(), 0, 0
        # Do not create output before FILE_OPEN succeeds. Keep incomplete output private.
        with tempfile.TemporaryFile() as output:
            try:
                while received < size:
                    count = min(512 * 1024, size - received)
                    operation, block = self.operation(15, struct.pack("<QQ", handle, count))
                    if operation != 2 or not 0 < len(block) <= count:
                        raise ProbeError("Truncated or invalid AFC file body")
                    digest.update(block)
                    lines += block.count(b"\n")
                    output.write(block)
                    received += len(block)
                if destination:
                    publish_complete_copy(output, destination)
            finally:
                with contextlib.suppress(ProbeError, OSError):
                    self.operation(20, struct.pack("<Q", handle))
        emit("file_complete", bytes=received, lines=lines, sha256=digest.hexdigest())


def resolve_remote_device(udid):
    state = subprocess.run(["/usr/libexec/remotectl", "dumpstate"],
                           capture_output=True, text=True, timeout=10, check=True).stdout
    matches = []
    for block in re.split(r"(?=^Found )", state, flags=re.M):
        if re.search(r"UniqueDeviceID => " + re.escape(udid) + r"\s*$", block, re.M):
            identifier = re.search(r"^\s+UUID: ([A-Fa-f0-9-]{36})$", block, re.M)
            if identifier and "State: connected" in block:
                matches.append(identifier[1])
    if len(matches) != 1:
        raise ProbeError("Requested paired device has no unique active OS tunnel")
    return matches[0]


def load_record(path):
    record = plistlib.loads(Path(path).read_bytes())
    if not isinstance(record, dict):
        raise ProbeError("Invalid existing pairing record")
    return record


def existing_record(args, remote=False):
    if args.pair_record:
        return load_record(args.pair_record)
    name = ("remote_" if remote else "") + args.udid + ".plist"
    for folder in (Path.home() / ".pymobiledevice3",
                   Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "pymobiledevice3"):
        if (folder / name).is_file():
            return load_record(folder / name)
    if remote:
        raise ProbeError("Existing RemotePairing credential is not available locally")
    # Read the already trusted host's record from Apple's daemon; never issue Pair.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(args.timeout)
        connection.connect("/var/run/usbmuxd")
        body = plistlib.dumps({"MessageType": "ReadPairRecord", "PairRecordID": args.udid,
                              "ClientVersionString": LABEL, "ProgName": LABEL, "kLibUSBMuxVersion": 3})
        connection.sendall(struct.pack("<IIII", len(body) + 16, 1, 8, 1) + body)
        class Receiver:
            def read(self, length):
                return connection.recv(length)
        receiver = Receiver()
        length, version, message_type, tag = struct.unpack("<IIII", exact(receiver, 16))
        if version != 1 or message_type != 8 or tag != 1 or length < 16:
            raise ProbeError("Invalid usbmuxd pair-record response")
        response = plistlib.loads(exact(receiver, length - 16))
        data = response.get("PairRecordData")
        if not isinstance(data, bytes):
            raise ProbeError("Apple's daemon has no existing trust record for this device")
        record = plistlib.loads(data)
        if not isinstance(record, dict):
            raise ProbeError("Apple's existing trust record is invalid")
        return record


def read_only_diagnostic_query(stream, probe):
    request = {"Request": "GasGauge"} if probe == "gas-gauge" else {
        "Request": "IORegistry", "EntryClass": "IOPMPowerSource"}
    channel = Plists(stream)
    channel.send(request)
    response = channel.receive()
    status = response.get("Status")
    if status != "Success":
        safe = status if isinstance(status, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", status) else "DeviceError"
        raise ProbeError("Diagnostic query rejected: " + safe)
    # Expose only battery metric field names, never identities or entire registry.
    names = set()
    allowed = {"CycleCount", "DesignCapacity", "FullChargeCapacity", "NominalChargeCapacity",
               "RawMaxCapacity", "MaximumCapacityPercent", "Temperature", "AppleRawMaxCapacity",
               "CurrentCapacity", "MaxCapacity", "ChargeCounter"}
    def fields(value, depth=0):
        if depth > 32:
            raise ProbeError("Diagnostic response nesting exceeds limit")
        if isinstance(value, dict):
            for key, item in value.items():
                if key in allowed and isinstance(item, (int, float)) and not isinstance(item, bool):
                    names.add(key)
                fields(item, depth + 1)
        elif isinstance(value, list):
            for item in value:
                fields(item, depth + 1)
    fields(response.get("Diagnostics", {}))
    emit("live_battery_query", query=probe, status="Success", available_metrics=sorted(names),
         daily_analytics_acquired=False)


def run(args):
    if args.probe == "analytics-file" and not args.inventory:
        if not isinstance(args.file, str) or not re.fullmatch(r"/(?:ProxiedDevice-[a-fA-F0-9]+/)?(?:Retired/)?Analytics-\d{4}-\d{2}-\d{2}-\d{6}[A-Za-z0-9._-]*\.ips\.ca\.synced", args.file) or "session" in args.file.lower():
            raise ProbeError("Select an existing non-session Analytics report")
    resources = []
    if args.probe == "os-key-status":
        key = existing_os_remote_key(args)
        matching = None
        try:
            saved = existing_record(args, remote=True).get("remote_unlock_host_key")
            if isinstance(saved, str):
                matching = key == base64.b64decode(saved, validate=True)
        except (ProbeError, OSError, ValueError):
            pass
        emit("existing_os_credential", available=True, same_as_saved_tool_credential=matching)
        return
    service = {
        "analytics-file": REMOTE_SERVICE,
        "gas-gauge": "com.apple.mobile.diagnostics_relay.shim.remote",
        "power-registry": "com.apple.mobile.diagnostics_relay.shim.remote",
        "analytics-transport": "com.apple.osanalytics.logTransfer",
        "file-relay-availability": "com.apple.mobile.file_relay.shim.remote",
    }[args.probe]
    if args.probe == "analytics-transport" and args.mode != "remote":
        raise ProbeError("Alternate RemoteXPC transport requires independent remote mode")
    if args.probe != "analytics-file" and args.mode == "os-service":
        raise ProbeError("Stock bridge comparison only supports the Analytics file probe")
    try:
        if args.mode in ("remote", "os-service"):
            helper = args.tunnel_helper or Path(__file__).resolve().parents[2] / "Build/research/native_tunnel"
            assertion = None
            if Path(helper).is_file():
                assertion = TunnelAssertion(helper, args.udid)
                resources.append(assertion)
                emit("native_tunnel_assertion", implementation="independent_c_and_system_xpc")
            if args.mode == "os-service":
                device = resolve_remote_device(args.udid)
                stream = Pipe(device, args.timeout)
            else:
                if assertion is None:
                    raise ProbeError("Compile the independent native tunnel helper first")
                path = Path(__file__).with_name("remote_wire.py")
                spec = importlib.util.spec_from_file_location("mochilog_research_remote_wire", path)
                wire = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(wire)
                port = None
                for attempt in range(5):
                    try:
                        port = wire.find_port(assertion.address)
                        break
                    except ValueError:
                        if attempt == 4:
                            raise
                        time.sleep(0.5)
                discovery, metadata = None, None
                for attempt in range(3):
                    try:
                        port = wire.find_port(assertion.address)
                        discovery = wire.Rsd(assertion.address, port, args.timeout)
                        metadata = discovery.discover()
                        resources.append(discovery)
                        break
                    except (ConnectionResetError, BrokenPipeError) as error:
                        if discovery is not None:
                            discovery.close()
                        emit("rsd_retry", attempt=attempt + 1, error_type=type(error).__name__)
                        if attempt == 2:
                            raise
                        time.sleep(0.5)
                    except Exception:
                        if discovery is not None:
                            discovery.close()
                        raise
                if metadata.get("Properties", {}).get("UniqueDeviceID") != args.udid:
                    raise ProbeError("RSD peer identifier does not match requested device")
                emit("rsd_discovered", implementation="independent_http2_and_xpc")
                if args.inventory:
                    services = metadata.get("Services", {})
                    emit("diagnostic_service_inventory", names=sorted(name for name in services
                         if any(word in name.lower() for word in ("analytics", "log", "crash", "diagnost"))))
                    # Whitelist protocol hints; never dump the full service metadata.
                    for name in (REMOTE_SERVICE, "com.apple.osanalytics.logTransfer"):
                        entry = services.get(name, {})
                        properties = entry.get("Properties", {})
                        emit("service_protocol_hint", service=name,
                             uses_remote_xpc=properties.get("UsesRemoteXPC") is True)
                    return
                if service not in metadata["Services"]:
                    raise ProbeError("Requested alternate service is not advertised")
                service_port = int(metadata["Services"][service]["Port"])
                if not 0 < service_port < 65536:
                    raise ProbeError("RSD advertised an invalid service port")
                if args.probe == "analytics-transport":
                    alternate = wire.Rsd(assertion.address, service_port, args.timeout)
                    resources.append(alternate)
                    alternate.bootstrap()
                    emit("alternate_transport_negotiated", service=service, body_access_tested=False)
                    # Only wait for an unsolicited protocol message. No guessed service RPC.
                    alternate.socket.settimeout(2)
                    try:
                        message = alternate.receive()
                        safe_fields = {"MessageType", "ProtocolVersion", "MessagingProtocolVersion", "Properties",
                                       "Services", "UUID", "Event", "Request", "Response", "Error", "Status"}
                        emit("alternate_unsolicited_message", fields=sorted(set(message) & safe_fields),
                             other_field_count=len(set(message) - safe_fields), body_access_tested=False)
                    except socket.timeout:
                        emit("alternate_no_unsolicited_message", body_access_tested=False)
                    return
                stream = Tcp(assertion.address, service_port, args.timeout)
            resources.append(stream)
            emit("diagnostic_service_connected", implementation="stdlib_and_macos")
            if args.checkin != "skip":
                channel = Plists(stream)
                request = {"Label": LABEL, "ProtocolVersion": "2", "Request": "RSDCheckin"}
                if args.checkin == "escrow":
                    record = existing_record(args, remote=True)
                    key = record.get("remote_unlock_host_key")
                    if not isinstance(key, str) or not key:
                        raise ProbeError("Existing remote unlock credential is unavailable")
                    request["EscrowBag"] = base64.b64decode(key, validate=True)
                elif args.checkin == "os-escrow":
                    request["EscrowBag"] = existing_os_remote_key(args)
                channel.send(request)
                for expected in ("RSDCheckin", "StartService"):
                    response = channel.receive()
                    if response.get("Error"):
                        error = response["Error"]
                        raise ProbeError(f"RSD authentication rejected: {error if isinstance(error, str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', error) else 'DeviceError'}")
                    if response.get("Request") != expected:
                        raise ProbeError("Unexpected RSD authentication response")
                    emit("rsd_checkin", response=expected, credential=args.checkin)
        else:
            if not args.host:
                raise ProbeError("Classic TCP mode needs the currently discovered device address")
            record = existing_record(args)
            session = Tcp(args.host, 62078, args.timeout)
            resources.append(session)
            channel = Plists(session)
            response = channel.request("StartSession", HostID=record["HostID"], SystemBUID=record["SystemBUID"])
            if response.get("EnableSessionSSL"):
                session.tls(record)
            emit("paired_session", tls=bool(response.get("EnableSessionSSL")))
            actual = channel.request("GetValue", Key="UniqueDeviceID").get("Value")
            if actual != args.udid:
                raise ProbeError("Connected device identifier does not match requested device")
            classic_service = {
                "analytics-file": SERVICE,
                "gas-gauge": "com.apple.mobile.diagnostics_relay",
                "power-registry": "com.apple.mobile.diagnostics_relay",
                "file-relay-availability": "com.apple.mobile.file_relay",
            }[args.probe]
            fields = {"Service": classic_service}
            if args.checkin == "escrow":
                if not record.get("EscrowBag"):
                    raise ProbeError("Existing classic escrow credential is unavailable")
                fields["EscrowBag"] = record["EscrowBag"]
            response = channel.request("StartService", **fields)
            port = response.get("Port")
            if not isinstance(port, int) or not 0 < port < 65536:
                raise ProbeError("Device returned an invalid service port")
            emit("classic_service_requested", tls=bool(response.get("EnableServiceSSL")))
            stream = Tcp(args.host, port, args.timeout)
            resources.append(stream)
            if response.get("EnableServiceSSL"):
                stream.tls(record)
        if args.probe == "file-relay-availability":
            emit("file_relay_connection_available", body_access_tested=False,
                 daily_analytics_acquired=False)
        elif args.probe in ("gas-gauge", "power-registry"):
            read_only_diagnostic_query(stream, args.probe)
        else:
            Afc(stream).read_file(args.file, args.output)
    finally:
        for resource in reversed(resources):
            resource.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--file", help="Existing non-session Analytics path, required for the file probe")
    parser.add_argument("--mode", choices=("remote", "classic", "os-service"), default="remote")
    parser.add_argument("--probe", choices=("analytics-file", "gas-gauge", "power-registry", "analytics-transport", "os-key-status", "file-relay-availability"),
                        default="analytics-file", help="Read-only alternate service query; never starts a backup")
    parser.add_argument("--checkin", choices=("plain", "escrow", "os-escrow", "skip"), default="plain")
    parser.add_argument("--host")
    parser.add_argument("--pair-record")
    parser.add_argument("--tunnel-helper", help="Compiled independent C helper for the existing OS tunnel")
    parser.add_argument("--inventory", action="store_true", help="List diagnostic service names without opening reports (remote mode)")
    parser.add_argument("--output", help="Optional private copy; never overwrite an existing file")
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9A-Fa-f-]{8,80}", args.udid):
        parser.error("invalid device identifier")
    if not 0 < args.timeout <= 30:
        parser.error("timeout must be between 0 and 30 seconds")
    if args.checkin == "os-escrow" and args.mode != "remote":
        parser.error("OS RemotePairing credential requires remote mode")
    if args.output and (args.probe != "analytics-file" or args.inventory):
        parser.error("--output is only supported for an Analytics file read")
    started = time.monotonic()
    if hasattr(signal, "SIGALRM"):
        def deadline(_signal, _frame):
            raise ProbeError("Overall research deadline exceeded")
        signal.signal(signal.SIGALRM, deadline)
        signal.alarm(120)
    try:
        run(args)
        return 0
    except (ProbeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Exception text is only emitted for our sanitized protocol errors.
        emit("failed", error_type=type(error).__name__,
             reason=str(error) if isinstance(error, ProbeError) else "Transport or credential input failure",
             seconds=round(time.monotonic() - started, 2))
        return 1
    finally:
        if hasattr(signal, "SIGALRM"):
            signal.alarm(0)


if __name__ == "__main__":
    raise SystemExit(main())
