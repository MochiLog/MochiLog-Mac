/* Read-only research helper using the macOS system XPC daemon.
 * Message names researched from the MIT-licensed pymobiledevice3 native_tunnel
 * protocol reference. This independent C implementation neither links it nor
 * requests pairing, passcodes, remote unlock or protection-setting changes.
 */
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>

static xpc_connection_t browser, device;
static xpc_object_t assertion;
static dispatch_queue_t queue;
static int requested;

static xpc_object_t message(const char *name) {
    xpc_object_t result = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t body = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(result, "mangledTypeName", name);
    xpc_dictionary_set_value(result, "value", body);
    xpc_release(body);
    return result;
}

static xpc_object_t at(xpc_object_t parent, const char *key) {
    if (!parent || xpc_get_type(parent) != XPC_TYPE_DICTIONARY) return NULL;
    return xpc_dictionary_get_value(parent, key);
}

static void finish(int status) {
    if (device && assertion) {
        xpc_object_t request = message("RemotePairing.ReleaseAssertionRequest");
        xpc_dictionary_set_value(at(request, "value"), "assertionIdentifier", assertion);
        xpc_connection_send_message(device, request);
        xpc_release(request);
    }
    if (device) xpc_connection_cancel(device);
    if (browser) xpc_connection_cancel(browser);
    /* Exit rather than dispose callback state while libdispatch can still use it. */
    fflush(stdout);
    _exit(status);
}

int main(int argc, char **argv) {
    int key_only = argc == 3 && !strcmp(argv[1], "--existing-key-only");
    if ((!key_only && argc != 2) || strlen(argv[key_only ? 2 : 1]) > 80) return 64;
    const char *target = argv[key_only ? 2 : 1];
    setbuf(stdout, NULL);
    queue = dispatch_queue_create("net.ryuya-dev.mochilog.research", DISPATCH_QUEUE_SERIAL);
    browser = xpc_connection_create_mach_service("com.apple.CoreDevice.remotepairingd", queue, 0);
    xpc_connection_set_event_handler(browser, ^(xpc_object_t event) {
        xpc_object_t info = at(at(at(at(event, "value"), "deviceFound"), "_0"), "deviceInfo");
        if (!info || requested) return;
        const char *udid = xpc_dictionary_get_string(info, "udid");
        xpc_object_t endpoint = at(info, "endpoint");
        if (!udid || strcmp(udid, target) || !endpoint || xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT) return;
        requested = 1;
        if (key_only) {
            /* Read only a credential already present in the OS's paired-device
             * snapshot. Never issue CopyRemoteUnlockHostKeyRequest: that API
             * may initialize a missing key. Binary data goes to a private pipe.
             */
            size_t size = 0;
            const void *key = xpc_dictionary_get_data(info, "remoteUnlockHostKey", &size);
            if (!key || !size || size > 4096) {
                puts("{\"stage\":\"existing_os_key_unavailable\"}");
                finish(1);
            }
            printf("{\"stage\":\"existing_os_key_ready\",\"length\":%zu}\n", size);
            if (fwrite(key, 1, size, stdout) != size) finish(1);
            finish(0);
        }
        device = xpc_connection_create_from_endpoint(endpoint);
        xpc_connection_set_target_queue(device, queue);
        xpc_connection_set_event_handler(device, ^(xpc_object_t error) {
            if (xpc_get_type(error) == XPC_TYPE_ERROR) {
                puts("{\"stage\":\"native_connection_closed\"}");
            }
        });
        xpc_connection_activate(device);
        xpc_object_t request = message("RemotePairing.CreateAssertionCommand");
        xpc_dictionary_set_int64(at(request, "value"), "flags", 0);
        xpc_connection_send_message_with_reply(device, request, queue, ^(xpc_object_t reply) {
            xpc_object_t response = at(reply, "response");
            xpc_object_t identifier = at(response, "assertionIdentifier");
            xpc_object_t connection_info = at(response, "info");
            const char *ip = connection_info ? xpc_dictionary_get_string(connection_info, "tunnelIPAddress") : NULL;
            if (!response || !identifier || !ip || !*ip) {
                xpc_object_t error = at(reply, "error");
                const char *domain = error ? xpc_dictionary_get_string(error, "domain") : NULL;
                if (domain && strspn(domain, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") == strlen(domain)) {
                    printf("{\"stage\":\"native_assertion_failed\",\"domain\":\"%s\",\"code\":%lld}\n",
                           domain, (long long)xpc_dictionary_get_int64(error, "code"));
                } else {
                    puts("{\"stage\":\"native_assertion_failed\"}");
                }
                finish(1);
            }
            assertion = xpc_retain(identifier);
            struct in6_addr address;
            if (inet_pton(AF_INET6, ip, &address) != 1) {
                puts("{\"stage\":\"native_address_invalid\"}");
                finish(1);
            }
            /* Private pipe to the parent, never a persisted diagnostic log. */
            printf("{\"stage\":\"native_assertion_ready\",\"address\":\"%s\"}\n", ip);
        });
        xpc_release(request);
    });
    xpc_connection_activate(browser);
    xpc_object_t request = message("RemotePairing.BrowseRequest");
    xpc_dictionary_set_bool(at(request, "value"), "currentDevicesOnly", false);
    xpc_connection_send_message_with_reply(browser, request, queue, ^(xpc_object_t unused) { (void)unused; });
    xpc_release(request);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    dispatch_source_t termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, queue);
    dispatch_source_set_event_handler(termination, ^{ finish(0); });
    dispatch_resume(termination);
    dispatch_source_t interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, queue);
    dispatch_source_set_event_handler(interrupt, ^{ finish(0); });
    dispatch_resume(interrupt);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), queue, ^{
        if (!assertion) {
            puts("{\"stage\":\"native_assertion_timeout\"}");
            finish(1);
        }
    });
    dispatch_main();
}
