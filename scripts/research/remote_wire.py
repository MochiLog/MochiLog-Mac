"""Independent bounded RemoteXPC/RSD wire codec, using only the standard library.

Protocol reference: pymobiledevice3 v11.19.1 remote/xpc_message.py and
remote/remotexpc.py (MIT). No reference library code is imported or executed.
This implements discovery messages only, not arbitrary RPC or file-write APIs.
"""
import re
import socket
import struct
import subprocess
import uuid

LIMIT = 2 * 1024 * 1024


def padded(data):
    return data + b"\0" * (-len(data) % 4)


def encode(value):
    if value is None:
        return struct.pack("<I", 0x1000)
    if isinstance(value, bool):
        return struct.pack("<II", 0x2000, int(value))
    if isinstance(value, int):
        return struct.pack("<IQ", 0x4000, value)
    if isinstance(value, uuid.UUID):
        return struct.pack("<I", 0xa000) + value.bytes
    if isinstance(value, str):
        text = value.encode() + b"\0"
        return struct.pack("<II", 0x9000, len(text)) + padded(text)
    if isinstance(value, dict):
        body = struct.pack("<I", len(value))
        for key, item in value.items():
            body += padded(key.encode() + b"\0") + encode(item)
        return struct.pack("<II", 0xf000, len(body)) + body
    raise ValueError("Unsupported outgoing discovery value")


class Decoder:
    def __init__(self, data):
        self.data, self.position = data, 0

    def take(self, length):
        if length < 0 or self.position + length > len(self.data):
            raise ValueError("Truncated XPC value")
        result = self.data[self.position:self.position + length]
        self.position += length
        return result

    def number(self, code="I"):
        return struct.unpack("<" + code, self.take(struct.calcsize("<" + code)))[0]

    def value(self, depth=0):
        if depth > 32:
            raise ValueError("XPC nesting too deep")
        kind = self.number()
        if kind == 0x1000:
            return None
        if kind == 0x2000:
            return bool(self.number())
        if kind in (0x3000, 0x4000, 0x7000):
            return self.number("q" if kind == 0x3000 else "Q")
        if kind == 0x5000:
            return self.number("d")
        if kind == 0xa000:
            return uuid.UUID(bytes=self.take(16))
        if kind in (0x8000, 0x9000):
            length = self.number()
            if length > LIMIT:
                raise ValueError("XPC scalar too large")
            data = self.take(length)
            self.take(-length % 4)
            if kind == 0x9000:
                if not data.endswith(b"\0"):
                    raise ValueError("Unterminated XPC string")
                return data[:-1].decode()
            return data
        if kind in (0xe000, 0xf000):
            length = self.number()
            if not 4 <= length <= LIMIT:
                raise ValueError("Invalid XPC collection length")
            collection = Decoder(self.take(length))
            count = collection.number()
            if count > 4096:
                raise ValueError("Too many XPC entries")
            result = {} if kind == 0xf000 else []
            for _ in range(count):
                if kind == 0xf000:
                    end = collection.data.find(b"\0", collection.position)
                    if end < 0:
                        raise ValueError("Unterminated XPC key")
                    length = end - collection.position + 1
                    key = collection.take(length)[:-1].decode()
                    collection.take(-length % 4)
                    if key in result:
                        raise ValueError("Duplicate XPC key")
                    result[key] = collection.value(depth + 1)
                else:
                    result.append(collection.value(depth + 1))
            if collection.position != len(collection.data):
                raise ValueError("Unexpected bytes after XPC collection")
            return result
        raise ValueError(f"Unsupported incoming XPC type {kind:#x}")


def wrapper(value=None, flags=1, message_id=0):
    body = b"" if value is None else struct.pack("<II", 0x42133742, 5) + encode(value)
    if value:
        flags |= 0x100
    return struct.pack("<IIQQ", 0x29b00b92, flags, len(body), message_id) + body


def decode_wrapper(packet):
    if len(packet) < 24:
        raise ValueError("Truncated XPC envelope")
    magic, flags, length, message_id = struct.unpack("<IIQQ", packet[:24])
    if magic != 0x29b00b92 or length > LIMIT or len(packet) != length + 24:
        raise ValueError("Invalid XPC envelope")
    if not length:
        return None
    decoder = Decoder(packet[24:])
    if decoder.number() != 0x42133742 or decoder.number() != 5:
        raise ValueError("Invalid XPC payload version")
    value = decoder.value()
    if decoder.position != len(decoder.data):
        raise ValueError("Unexpected bytes after XPC payload")
    return value


def find_port(address):
    output = subprocess.run(["/usr/bin/nettop", "-n", "-x", "-L", "1", "-m", "tcp", "-J", "interface,state"],
                            capture_output=True, text=True, timeout=10, check=True).stdout
    owner, ports = "", set()
    for line in output.splitlines():
        fields = line.split(",")
        if not fields[0].startswith("tcp"):
            owner = fields[0].rsplit(".", 1)[0]
        elif owner == "remoted" and len(fields) >= 3 and fields[2] == "Established":
            endpoint = fields[0].split("<->")[-1]
            host, _, port = endpoint.rpartition(".")
            if host.split("%", 1)[0] == address and port.isdigit():
                ports.add(int(port))
    if len(ports) != 1:
        raise ValueError("OS has no unique active RSD endpoint for the requested tunnel")
    return ports.pop()


def host_identity():
    state = subprocess.run(["/usr/libexec/remotectl", "dumpstate"],
                           capture_output=True, text=True, timeout=10, check=True).stdout
    match = re.search(r"^Local device\n\s+UUID: ([0-9A-Fa-f-]{36})$", state, re.M)
    if not match:
        raise ValueError("Could not obtain the existing OS peer identity")
    return uuid.UUID(match[1])


class Rsd:
    def __init__(self, address, port, timeout):
        self.socket = socket.create_connection((address, port), timeout=timeout)
        self.buffers = {}

    def close(self):
        self.socket.close()

    def read(self, length):
        data = bytearray()
        while len(data) < length:
            block = self.socket.recv(length - len(data))
            if not block:
                raise ValueError("RSD connection closed")
            data.extend(block)
        return bytes(data)

    def frame(self, kind, stream=0, data=b"", flags=0):
        if len(data) > 16384:
            raise ValueError("Discovery frame exceeds peer frame size")
        self.socket.sendall(len(data).to_bytes(3, "big") + bytes((kind, flags)) + struct.pack(">I", stream) + data)

    def receive(self):
        received = 0
        for _ in range(4096):
            header = self.read(9)
            length, kind, flags, stream = int.from_bytes(header[:3], "big"), header[3], header[4], int.from_bytes(header[5:], "big") & 0x7fffffff
            if length > LIMIT:
                raise ValueError("Incoming RSD frame too large")
            received += length + 9
            if received > LIMIT * 2:
                raise ValueError("RSD discovery byte budget exceeded")
            data = self.read(length)
            if kind == 4 and not flags & 1:
                self.frame(4, flags=1)
            elif kind == 6 and not flags & 1:
                self.frame(6, data=data, flags=1)
            elif kind in (3, 7):
                raise ValueError("Device rejected RSD discovery stream")
            elif kind == 0:
                if stream not in (1, 3):
                    raise ValueError("Unexpected RSD discovery stream")
                if flags & 8:
                    if not data or data[0] >= len(data):
                        raise ValueError("Invalid padded RSD frame")
                    data = data[1:len(data) - data[0]]
                if data:
                    self.frame(8, data=struct.pack(">I", length))
                    self.frame(8, stream, struct.pack(">I", length))
                buffer = self.buffers.setdefault(stream, bytearray())
                buffer.extend(data)
                if len(buffer) > LIMIT:
                    raise ValueError("RSD message exceeds limit")
                while len(buffer) >= 24:
                    length = struct.unpack("<Q", buffer[8:16])[0]
                    if length > LIMIT:
                        raise ValueError("RSD envelope exceeds limit")
                    if len(buffer) < length + 24:
                        break
                    packet = bytes(buffer[:length + 24])
                    del buffer[:length + 24]
                    value = decode_wrapper(packet)
                    if isinstance(value, dict) and value:
                        return value
        raise ValueError("RSD discovery frame budget exceeded")

    def bootstrap(self):
        """Negotiate RemoteXPC transport without sending a service operation."""
        self.socket.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        self.frame(4, data=struct.pack(">HIHI", 3, 100, 4, 2 * 1024 * 1024))
        self.frame(8, data=struct.pack(">I", 2 * 1024 * 1024 - 65535))
        self.frame(1, 1, flags=4)
        self.frame(0, 1, wrapper({}))
        self.frame(1, 3, flags=4)
        self.frame(0, 1, wrapper(flags=0x201))
        self.frame(0, 3, wrapper(flags=0x400001))
        for _ in range(64):
            header = self.read(9)
            length, kind, flags = int.from_bytes(header[:3], "big"), header[3], header[4]
            if length > LIMIT:
                raise ValueError("Initial RSD frame too large")
            data = self.read(length)
            if kind == 4:
                if not flags & 1:
                    self.frame(4, flags=1)
                break
            if kind != 8:
                raise ValueError(f"Unexpected initial RSD frame type {kind}")
        else:
            raise ValueError("Device did not send RSD SETTINGS")

    def discover(self):
        self.bootstrap()
        self.frame(0, 1, wrapper({"MessageType": "Handshake", "MessagingProtocolVersion": 7,
                                 "UUID": host_identity(), "Services": {},
                                 "Properties": {"RemoteXPCVersionFlags": 0x0100000000000006,
                                                "SensitivePropertiesVisible": True}}, message_id=1))
        for _ in range(4):
            response = self.receive()
            if "Services" in response and "Properties" in response:
                return response
        raise ValueError("Device did not provide RSD discovery metadata")
