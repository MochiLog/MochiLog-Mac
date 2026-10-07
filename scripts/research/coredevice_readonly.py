"""Fixed read-only CoreDevice probes; no generic invoke or write operations.

Wire references: upstream core_device/device_info.py and file_service.py.
The native OS tunnel and independent RemoteXPC codec are supplied by the caller.
"""
import uuid


def exchange(channel, wire, request, sequence):
    channel.frame(0, 1, wire.wrapper(request, message_id=sequence, flags=0x10101))
    return channel.receive()


def probe(channel, wire, kind, file, emit, error):
    emit("coredevice_socket_connected", probe=kind)
    channel.bootstrap()
    emit("coredevice_transport_negotiated", probe=kind)
    if kind == "coredevice-lock-state":
        invocation = str(uuid.uuid4())
        request = {
            "CoreDevice.CoreDeviceDDIProtocolVersion": wire.Signed(2),
            "CoreDevice.coreDeviceVersion": {"components": [629, 3],
                "originalComponentsCount": wire.Signed(2), "stringValue": "629.3"},
            "CoreDevice.deviceIdentifier": str(uuid.uuid4()),
            "CoreDevice.invocationIdentifier": invocation,
            "CoreDevice.featureIdentifier": "com.apple.coredevice.feature.getlockstate",
            "CoreDevice.action": {}, "CoreDevice.input": {},
        }
        emit("coredevice_read_request", operation="getlockstate")
        response = exchange(channel, wire, request, 1)
        output = response.get("CoreDevice.output")
        if not isinstance(output, dict):
            emit("coredevice_response_shape", output_present=output is not None,
                 error_present=response.get("CoreDevice.error") is not None)
            raise error("CoreDevice did not return a lock-state output")
        fields = {key: output[key] for key in ("passcodeRequired", "unlockedSinceBoot")
                  if isinstance(output.get(key), bool)}
        emit("coredevice_lock_state", **fields, state_fields_complete=len(fields) == 2)
        if len(fields) != 2:
            raise error("CoreDevice lock-state response lacks the expected boolean fields")
        return
    # SYSTEM_CRASH_LOGS is the same domain exposed by devicectl, not an app
    # container or unrestricted path traversal. Only the validated report path.
    emit("coredevice_read_request", operation="CreateSession", domain="systemCrashLogs")
    response = exchange(channel, wire, {"Cmd": "CreateSession", "Domain": 5,
        "Identifier": "", "Session": "", "User": "mobile"}, 1)
    if response.get("EncodedError") is not None:
        raise error("CoreDevice rejected the systemCrashLogs session")
    session = response.get("NewSessionID")
    if not isinstance(session, str) or not session or len(session) > 1024:
        raise error("CoreDevice returned no bounded file session identifier")
    emit("coredevice_file_session", domain="systemCrashLogs")
    emit("coredevice_read_request", operation="RetrieveFile")
    response = exchange(channel, wire, {"Cmd": "RetrieveFile", "Path": file.lstrip("/"),
        "SessionID": session}, 2)
    if response.get("EncodedError") is not None:
        emit("coredevice_file_denied", encoded_error_present=True)
        raise error("CoreDevice rejected the requested Analytics file")
    identifier, result = response.get("NewFileID"), response.get("Response")
    if not isinstance(identifier, int) or isinstance(identifier, bool) or not isinstance(result, int) or isinstance(result, bool):
        raise error("CoreDevice returned no valid file-transfer authorization")
    emit("coredevice_file_authorized", body_access_tested=False,
         daily_analytics_acquired=False)
    # Authorization is not body acquisition. The separately framed data service
    # needs its own validated receiver before this can be called file_complete.

