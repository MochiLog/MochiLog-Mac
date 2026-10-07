"""Bounded CrashReporter-only relay probe; stream and discard, never unpack paths.

Protocol references: libimobiledevice file_relay.c/header (Sources/Acknowledged)
and POSIX cpio odc/newc formats. No reference implementation is imported.
"""
import hashlib
import time
import zlib

COMPRESSED_LIMIT = 128 * 1024 * 1024
DECODED_LIMIT = 512 * 1024 * 1024
BLOCK = 256 * 1024


class ArchiveError(ValueError):
    pass


class Cpio:
    def __init__(self, filename):
        self.filename = filename
        self.buffer = bytearray()
        self.state = "header"
        self.remaining = 0
        self.end = False
        self.matches = []
        self.current = None
        self.entries = 0

    def feed(self, block):
        self.buffer.extend(block)
        while True:
            if self.end:
                if any(self.buffer):
                    raise ArchiveError("Unexpected bytes after CPIO trailer")
                self.buffer.clear()
                return
            if self.state == "header":
                if len(self.buffer) < 6:
                    return
                magic = self.buffer[:6]
                size = 76 if magic == b"070707" else 110 if magic in (b"070701", b"070702") else 0
                if not size:
                    raise ArchiveError("Unsupported CPIO header")
                if len(self.buffer) < size:
                    return
                header = bytes(self.buffer[:size])
                del self.buffer[:size]
                try:
                    self.namesize = int(header[59:65], 8) if size == 76 else int(header[94:102], 16)
                    self.filesize = int(header[65:76], 8) if size == 76 else int(header[54:62], 16)
                    self.mode = int(header[18:24], 8) if size == 76 else int(header[14:22], 16)
                    self.checksum = int(header[102:110], 16) if magic == b"070702" else None
                except ValueError:
                    raise ArchiveError("Invalid CPIO numeric fields") from None
                if not 1 <= self.namesize <= 4096 or not 0 <= self.filesize <= DECODED_LIMIT:
                    raise ArchiveError("CPIO member exceeds research bounds")
                self.namepad = (-size - self.namesize) % 4 if size == 110 else 0
                self.datapad = -self.filesize % 4 if size == 110 else 0
                self.current_sum = 0
                self.state = "name"
            elif self.state == "name":
                count = self.namesize + self.namepad
                if len(self.buffer) < count:
                    return
                raw = bytes(self.buffer[:self.namesize])
                padding = self.buffer[self.namesize:count]
                if not raw.endswith(b"\0") or b"\0" in raw[:-1] or any(padding):
                    raise ArchiveError("Invalid CPIO member name")
                name = raw[:-1].decode("utf-8")
                del self.buffer[:count]
                self.entries += 1
                if self.entries > 100000:
                    raise ArchiveError("CPIO entry budget exceeded")
                if name == "TRAILER!!!":
                    if self.filesize:
                        raise ArchiveError("CPIO trailer has a body")
                    self.end = True
                    continue
                components = name.split("/")
                if any(part.startswith("ProxiedDevice-") for part in components):
                    matched = False
                else:
                    matched = (name == self.filename or name.endswith("/" + self.filename))
                if matched:
                    if self.mode & 0o170000 != 0o100000 or not 0 < self.filesize <= 128 * 1024 * 1024:
                        raise ArchiveError("Requested Analytics member is not a bounded regular file")
                    self.current = {"digest": hashlib.sha256(), "bytes": 0, "lines": 0}
                self.remaining = self.filesize
                self.state = "body"
            elif self.state == "body":
                count = min(len(self.buffer), self.remaining)
                if count:
                    block = bytes(self.buffer[:count])
                    del self.buffer[:count]
                    self.remaining -= count
                    if self.checksum is not None:
                        self.current_sum = (self.current_sum + sum(block)) & 0xffffffff
                    if self.current is not None:
                        self.current["digest"].update(block)
                        self.current["bytes"] += len(block)
                        self.current["lines"] += block.count(b"\n")
                if self.remaining:
                    return
                if self.checksum is not None and self.current_sum != self.checksum:
                    raise ArchiveError("CPIO checksum mismatch")
                if self.current is not None:
                    item = self.current
                    self.matches.append({"bytes": item["bytes"], "lines": item["lines"],
                                         "sha256": item["digest"].hexdigest()})
                    self.current = None
                self.state = "padding"
            else:
                if len(self.buffer) < self.datapad:
                    return
                if any(self.buffer[:self.datapad]):
                    raise ArchiveError("Invalid CPIO data padding")
                del self.buffer[:self.datapad]
                self.state = "header"

    def finish(self):
        if not self.end:
            raise ArchiveError("Incomplete CPIO archive")
        if len(self.matches) != 1:
            raise ArchiveError("Archive lacks one unambiguous requested Analytics body")
        return self.matches[0]


def read_archive(stream, filename, emit):
    """Drain the acknowledged stream before interpreting parsing failures."""
    parser = Cpio(filename)
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    compressed = decoded = 0
    failure = None
    last_progress = time.monotonic()
    while True:
        block = stream.read(BLOCK)
        if not block:
            break
        compressed += len(block)
        if compressed > COMPRESSED_LIMIT:
            raise ArchiveError("Relay compressed byte budget exceeded")
        # If parsing fails, drain/discard the remaining network stream rather
        # than deliberately abandoning the device's temporary staging archive.
        if failure is None:
            try:
                pending = block
                while pending:
                    data = inflater.decompress(pending, BLOCK)
                    pending = inflater.unconsumed_tail
                    decoded += len(data)
                    if decoded > DECODED_LIMIT:
                        raise ArchiveError("Relay decoded byte budget exceeded")
                    parser.feed(data)
                    if inflater.unused_data and any(inflater.unused_data):
                        raise ArchiveError("Unexpected trailing gzip member")
            except (ArchiveError, zlib.error, UnicodeDecodeError) as error:
                failure = error if isinstance(error, ArchiveError) else ArchiveError("Invalid relay archive encoding")
        if time.monotonic() - last_progress >= 10:
            emit("relay_archive_draining", compressed_bytes=compressed)
            last_progress = time.monotonic()
    emit("relay_archive_drained", compressed_bytes=compressed)
    if failure is not None:
        raise failure
    if not inflater.eof:
        raise ArchiveError("Incomplete gzip archive")
    result = parser.finish()
    emit("file_complete", acquisition="file_relay_archive", **result)
