const r4os = @import("r4os");

const tcp_test_port: u16 = 65021;
const udp_test_port: u16 = 65022;

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const app = App.init(r4_app) orelse return r4os.abi.err_no_group;

    app.sys.println("NETIOD");
    if (!app.sys.hasFn("io_file_read")) return fail(&app, "R4SYS async I/O unsupported");
    if (!app.net.hasFn("tcp_summary")) return fail(&app, "R4NET socket completion unsupported");
    if (!app.net.hasFn("tcp_summary")) return fail(&app, "R4NET socket lifecycle unsupported");
    if (!testConnectivityContracts(&app)) return 1;
    if (!testTcpStatus(&app)) return 1;
    if (!testTcpServiceWorkerStatus(&app)) return 1;
    if (!testUdpStatus(&app)) return 1;
    if (!testTcpLifecycle(&app)) return 1;
    if (!testUdpLifecycle(&app)) return 1;

    app.sys.println("NETIOD result: OK");
    return 0;
}

fn testConnectivityContracts(app: *const App) bool {
    const would_block_flags: u32 = r4os.abi.net_service_status_would_block << r4os.abi.net_service_status_shift;
    const ok = bytesEq(app.net.netServiceStatusName(would_block_flags), "would-block") and
        bytesEq(app.net.netServiceStatusCodeName(r4os.abi.net_service_status_timeout), "timeout") and
        bytesEq(app.net.netSocketLifecycleName(r4os.abi.net_service_socket_lifecycle_bad_handle), "bad-handle") and
        bytesEq(app.net.netServiceResultName(r4os.abi.net_service_result_bad_op), "bad-op") and
        bytesEq(app.net.netTcpResultName(r4os.abi.tcp_result_no_connection), "no-connection") and
        r4os.abi.net_service_tcp_write_max > 0 and
        r4os.abi.net_service_tcp_read_max > 0;
    app.sys.write("NETIOD connectivity-contract: ");
    app.sys.write(if (ok) "OK" else "FAILED");
    app.sys.write(" status=");
    app.sys.write(app.net.netServiceStatusName(would_block_flags));
    app.sys.write(" lifecycle=");
    app.sys.write(app.net.netSocketLifecycleName(r4os.abi.net_service_socket_lifecycle_bad_handle));
    app.sys.write(" tcp_read_max=");
    app.sys.printU64(r4os.abi.net_service_tcp_read_max);
    app.sys.write(" tcp_write_max=");
    app.sys.printU64(r4os.abi.net_service_tcp_write_max);
    app.sys.write("\r\n");
    return ok;
}

fn testTcpServiceWorkerStatus(app: *const App) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const open_rc = app.sys.serviceOpen("TCPSVC", &info);
    if (open_rc != r4os.abi.service_api_result_ok or info.handle == 0) return failBool(app, "tcp service open");
    defer _ = app.sys.serviceClose(info.handle);

    var detail: r4os.abi.ServiceDetail = .{};
    const detail_rc = app.sys.serviceDetailByName("TCPSVC", &detail);
    const detail_ok = detail_rc == r4os.abi.service_api_result_ok and
        (detail.info.flags & r4os.abi.service_api_flag_endpoint) != 0 and
        (detail.info.flags & r4os.abi.service_api_flag_queue_backed) != 0 and
        detail.info.queue_depth == r4os.abi.service_api_endpoint_queue_depth and
        detail.info.max_active_workers >= detail.info.active_workers;
    if (!detail_ok) return failBool(app, "tcp service detail contract");

    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [r4os.abi.service_api_max_payload]u8 = .{0} ** r4os.abi.service_api_max_payload;
    const got = app.sys.serviceCall(info.handle, r4os.abi.net_service_op_status, "STATUS", &header, response[0..], 120);
    if (got <= 0 or header.status != r4os.abi.service_api_result_ok) return failBool(app, "tcp service status");
    const response_len: usize = @intCast(got);
    if (response_len > response.len) return failBool(app, "tcp service status length");
    const text = response[0..response_len];
    if (!contains(text, "session_handles=") or !contains(text, "req_ticks=") or !contains(text, "long_req=")) {
        app.sys.write("NETIOD failed: tcp service worker status text=");
        app.sys.write(text);
        app.sys.write("\r\n");
        return false;
    }
    app.sys.write("NETIOD tcp-service-workers: OK ");
    app.sys.write(text);
    app.sys.write(" detail_q=");
    app.sys.printU64(detail.info.queue_used);
    app.sys.write("/");
    app.sys.printU64(detail.info.queue_depth);
    app.sys.write(" detail_workers=");
    app.sys.printU64(detail.info.active_workers);
    app.sys.write("/");
    app.sys.printU64(detail.info.max_active_workers);
    app.sys.write(" detail_open=");
    app.sys.printU64(detail.info.open_handles);
    app.sys.write(" detail_timeouts=");
    app.sys.printU64(detail.info.timeouts);
    app.sys.write("\r\n");
    return true;
}

fn testTcpStatus(app: *const App) bool {
    var request: r4os.r4net.NetSocketRequest = .{};
    if (!beginOk(app, app.net.tcpBeginStatusService(&request), "tcp status begin")) return false;
    var info: r4os.abi.ProgramIoInfo = .{};
    if (app.net.netSocketStatus(&request) == r4os.abi.io_ok) info = request.info;
    if (!waitOk(app, &request, "tcp status wait")) return false;
    var status: r4os.abi.NetServiceTcpStatus = .{};
    if (!request.tcpStatus(&status)) return failBool(app, "tcp status decode");
    if (!closeOk(app, &request, "tcp status close")) return false;

    app.sys.write("NETIOD tcp-status: request=");
    app.sys.printU64(info.request_id);
    app.sys.write(" handles=");
    app.sys.printU64(status.handle_count);
    app.sys.write("/");
    app.sys.printU64(status.max_handles);
    app.sys.write(" listeners=");
    app.sys.printU64(status.active_listeners);
    app.sys.write(" last_lifecycle=");
    app.sys.write(app.net.netSocketLifecycleName(status.last_lifecycle_cause));
    app.sys.write(" stale=");
    app.sys.printU64(status.stale_handles_reaped);
    app.sys.write("/");
    app.sys.printU64(status.stale_tombstones);
    app.sys.write("\r\n");
    return true;
}

fn testUdpStatus(app: *const App) bool {
    var request: r4os.r4net.NetSocketRequest = .{};
    if (!beginOk(app, app.net.udpBeginStatusService(&request), "udp status begin")) return false;
    if (!waitOk(app, &request, "udp status wait")) return false;
    var status: r4os.abi.NetServiceUdpStatus = .{};
    if (!request.udpStatus(&status)) return failBool(app, "udp status decode");
    if (!closeOk(app, &request, "udp status close")) return false;

    app.sys.write("NETIOD udp-status: sockets=");
    app.sys.printU64(status.active_sockets);
    app.sys.write("/");
    app.sys.printU64(status.max_sockets);
    app.sys.write(" queued=");
    app.sys.printU64(status.queued_packets);
    app.sys.write(" last_lifecycle=");
    app.sys.write(app.net.netSocketLifecycleName(status.last_lifecycle_cause));
    app.sys.write("\r\n");
    return true;
}

fn testTcpLifecycle(app: *const App) bool {
    var request: r4os.r4net.NetSocketRequest = .{};
    if (!beginOk(app, app.net.tcpBeginListenService(tcp_test_port, &request), "tcp listen begin")) return false;
    if (!waitOk(app, &request, "tcp listen wait")) return false;
    var listen: r4os.abi.NetServiceTcpResult = .{};
    if (!request.tcpResult(&listen)) return failBool(app, "tcp listen decode");
    if (listen.result != 0 or (listen.flags & r4os.abi.net_service_tcp_flag_listener) == 0) return failBool(app, "tcp listen result");
    if (!expectLifecycle(app, listen.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_listener, "tcp listen lifecycle")) return false;
    if (!closeOk(app, &request, "tcp listen close")) return false;

    request = .{};
    if (!beginOk(app, app.net.tcpBeginAcceptPollService(tcp_test_port, &request), "tcp accept-poll begin")) return false;
    if (!waitOk(app, &request, "tcp accept-poll wait")) return false;
    var empty: r4os.abi.NetServiceTcpResult = .{};
    if (!request.tcpResult(&empty)) return failBool(app, "tcp accept-poll decode");
    if (empty.result != 0 or serviceStatusCode(empty.flags) != r4os.abi.net_service_status_would_block) {
        app.sys.write("NETIOD failed: tcp accept-poll would-block result=");
        app.sys.printI32(empty.result);
        app.sys.write(" status=");
        app.sys.printU64(serviceStatusCode(empty.flags));
        app.sys.write(" flags=");
        app.sys.printU64(empty.flags);
        app.sys.write(" lifecycle=");
        app.sys.write(app.net.netSocketLifecycleName(empty.lifecycle_cause));
        app.sys.write(" last=");
        app.sys.write(fixedSlice(empty.last_error[0..]));
        app.sys.write("\r\n");
        return false;
    }
    if (!expectLifecycle(app, empty.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_would_block, "tcp accept-poll lifecycle")) return false;
    if (!closeOk(app, &request, "tcp accept-poll close")) return false;

    request = .{};
    if (!beginOk(app, app.net.tcpBeginCloseListenService(tcp_test_port, &request), "tcp close-listen begin")) return false;
    if (!waitOk(app, &request, "tcp close-listen wait")) return false;
    var closed: r4os.abi.NetServiceTcpResult = .{};
    if (!request.tcpResult(&closed)) return failBool(app, "tcp close-listen decode");
    if (closed.result != 0) return failBool(app, "tcp close-listen result");
    if (!expectLifecycle(app, closed.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_local_close, "tcp close-listen lifecycle")) return false;
    if (!closeOk(app, &request, "tcp close-listen close")) return false;

    var bad_payload: [4]u8 = .{ 0xEF, 0xBE, 0xAD, 0xDE };
    var bad: r4os.abi.NetServiceTcpResult = .{};
    if (app.net.tcpServiceResult(r4os.abi.net_service_op_tcp_poll_result, bad_payload[0..], &bad, "") != 0) return failBool(app, "tcp bad-handle request");
    if (bad.result == 0) return failBool(app, "tcp bad-handle result");
    if (!expectLifecycle(app, bad.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_bad_handle, "tcp bad-handle lifecycle")) return false;

    app.sys.write("NETIOD tcp-lifecycle: OK last=");
    app.sys.write(app.net.netSocketLifecycleName(bad.lifecycle_cause));
    app.sys.write("\r\n");
    return true;
}

fn testUdpLifecycle(app: *const App) bool {
    var request: r4os.r4net.NetSocketRequest = .{};
    if (!beginOk(app, app.net.udpBeginBindService(udp_test_port, &request), "udp bind begin")) return false;
    if (!waitOk(app, &request, "udp bind wait")) return false;
    var bound: r4os.abi.NetServiceUdpResult = .{};
    if (!request.udpResult(&bound)) return failBool(app, "udp bind decode");
    if (bound.result != 0 or (bound.flags & r4os.abi.net_service_udp_flag_handle_valid) == 0) return failBool(app, "udp bind result");
    const handle = bound.handle;
    if (!closeOk(app, &request, "udp bind close")) return false;

    request = .{};
    if (!beginOk(app, app.net.udpBeginRecvFromService(handle, 64, &request), "udp recv begin")) return false;
    if (!waitOk(app, &request, "udp recv wait")) return false;
    var recv: r4os.abi.NetServiceUdpResult = .{};
    if (!request.udpResult(&recv)) return failBool(app, "udp recv decode");
    if (recv.result != 0 or serviceStatusCode(recv.flags) != r4os.abi.net_service_status_would_block) return failBool(app, "udp recv would-block");
    if (!expectLifecycle(app, recv.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_would_block, "udp recv lifecycle")) return false;
    if (!closeOk(app, &request, "udp recv close")) return false;

    request = .{};
    if (!beginOk(app, app.net.udpBeginCloseService(handle, &request), "udp close begin")) return false;
    if (!waitOk(app, &request, "udp close wait")) return false;
    var closed: r4os.abi.NetServiceUdpResult = .{};
    if (!request.udpResult(&closed)) return failBool(app, "udp close decode");
    if (closed.result != 0) return failBool(app, "udp close result");
    if (!expectLifecycle(app, closed.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_local_close, "udp close lifecycle")) return false;
    if (!closeOk(app, &request, "udp close close")) return false;

    var bad_payload: [4]u8 = .{ 0, 0, 0, 0 };
    writeU32(bad_payload[0..], 0, handle);
    var bad: r4os.abi.NetServiceUdpResult = .{};
    if (app.net.udpServiceResult(r4os.abi.net_service_op_udp_close_result, bad_payload[0..], &bad, "") != 0) return failBool(app, "udp bad-handle request");
    if (bad.result == 0) return failBool(app, "udp bad-handle result");
    if (!expectLifecycle(app, bad.lifecycle_cause, r4os.abi.net_service_socket_lifecycle_bad_handle, "udp bad-handle lifecycle")) return false;

    app.sys.write("NETIOD udp-lifecycle: OK last=");
    app.sys.write(app.net.netSocketLifecycleName(bad.lifecycle_cause));
    app.sys.write("\r\n");
    return true;
}

fn expectLifecycle(app: *const App, actual: u32, expected: u32, label: []const u8) bool {
    if (actual == expected) return true;
    app.sys.write("NETIOD failed: ");
    app.sys.write(label);
    app.sys.write(" expected=");
    app.sys.write(app.net.netSocketLifecycleName(expected));
    app.sys.write(" actual=");
    app.sys.write(app.net.netSocketLifecycleName(actual));
    app.sys.write("\r\n");
    return false;
}

fn beginOk(app: *const App, rc: i32, label: []const u8) bool {
    if (rc == r4os.abi.io_ok) return true;
    app.sys.write("NETIOD failed: ");
    app.sys.write(label);
    app.sys.write(" rc=");
    app.sys.printI32(rc);
    app.sys.write("\r\n");
    return false;
}

fn waitOk(app: *const App, request: *r4os.r4net.NetSocketRequest, label: []const u8) bool {
    const rc = app.net.netSocketWait(request, r4os.abi.io_wait_forever);
    if (rc == r4os.abi.io_ok and request.info.state == r4os.abi.io_state_completed) return true;
    app.sys.write("NETIOD failed: ");
    app.sys.write(label);
    app.sys.write(" rc=");
    app.sys.printI32(rc);
    app.sys.write(" state=");
    app.sys.printU64(request.info.state);
    app.sys.write("\r\n");
    _ = app.net.netSocketClose(request);
    return false;
}

fn closeOk(app: *const App, request: *r4os.r4net.NetSocketRequest, label: []const u8) bool {
    const rc = app.net.netSocketClose(request);
    if (rc == r4os.abi.io_ok) return true;
    app.sys.write("NETIOD failed: ");
    app.sys.write(label);
    app.sys.write(" rc=");
    app.sys.printI32(rc);
    app.sys.write("\r\n");
    return false;
}

fn serviceStatusCode(flags: u32) u32 {
    const raw = (flags & r4os.abi.net_service_status_mask) >> r4os.abi.net_service_status_shift;
    return if (raw <= r4os.abi.net_service_status_would_block) raw else r4os.abi.net_service_status_failed;
}

fn fixedSlice(buf: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn bytesEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn writeU32(out: []u8, offset: usize, value: u32) void {
    out[offset] = @intCast(value & 0xFF);
    out[offset + 1] = @intCast((value >> 8) & 0xFF);
    out[offset + 2] = @intCast((value >> 16) & 0xFF);
    out[offset + 3] = @intCast(value >> 24);
}

fn fail(app: *const App, msg: []const u8) i32 {
    _ = failBool(app, msg);
    return 1;
}

fn failBool(app: *const App, msg: []const u8) bool {
    app.sys.write("NETIOD failed: ");
    app.sys.write(msg);
    app.sys.write("\r\n");
    return false;
}
