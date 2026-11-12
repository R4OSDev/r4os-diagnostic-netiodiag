const std = @import("std");
const r4os = @import("r4os");

const tcp_test_port: u16 = 65021;
const udp_test_port: u16 = 65022;

const App = struct {
    app: *r4os.App2,
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App2) ?App {
        return .{
            .app = r4_app,
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    const app = App.init(r4_app) orelse return r4os.abi.err_no_group;

    app.sys.println("NETIOD");
    if (!app.sys.hasFn("io_file_read")) return fail(&app, "R4SYS async I/O unsupported");
    if (!app.net.hasFn("tcp_summary")) return fail(&app, "R4NET socket completion unsupported");
    if (!testConnectivityContracts(&app)) return 1;
    if (!testTcpStatus(&app)) return 1;
    if (!testTcpServiceWorkerStatus(&app)) return 1;
    if (!testUdpStatus(&app)) return 1;
    if (!testTcpLifecycle(&app)) return 1;
    if (!testUdpLifecycle(&app)) return 1;

    if (!testTypedUdp(&app)) return 1;

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
    const services = app.app.services() orelse return failBool(app, "service facade");
    var connection = switch (services.open("TCPSVC")) {
        .connection => |value| value,
        .failure => return failBool(app, "tcp service open"),
    };
    defer _ = connection.close();

    var detail: r4os.abi.ServiceDetail = .{};
    const detail_rc = app.sys.serviceDetailByName("TCPSVC", &detail);
    const detail_ok = detail_rc == r4os.abi.service_api_result_ok and
        (detail.info.flags & r4os.abi.service_api_flag_endpoint) != 0 and
        (detail.info.flags & r4os.abi.service_api_flag_queue_backed) != 0 and
        detail.info.queue_depth == r4os.abi.service_api_endpoint_queue_depth and
        detail.info.max_active_workers >= detail.info.active_workers;
    if (!detail_ok) return failBool(app, "tcp service detail contract");

    var response: [r4os.abi.service_api_max_payload]u8 = undefined;
    var budget = connection.budget(.{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 1_200_000_000 }) catch return failBool(app, "status clock");
    const reply = switch (connection.callBudget(r4os.abi.net_service_op_status, "STATUS", &response, &budget)) {
        .response => |value| value,
        else => return failBool(app, "tcp service status"),
    };
    const response_len = reply.bytes;
    if (response_len == 0 or response_len > response.len) return failBool(app, "tcp service status length");
    const text = response[0..response_len];
    if (!contains(text, "session_handles=") or !contains(text, "req_ticks=") or !contains(text, "long_req=") or
        !contains(text, "wire_seg/") or !contains(text, "pure_ack/") or !contains(text, "poll_skip/"))
    {
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
    defer drainRequest(app, &request);
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
    defer drainRequest(app, &request);
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
    defer drainRequest(app, &request);
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
    defer drainRequest(app, &request);
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

fn typedCall(app: *const App, client: *r4os.network_family.Client, budget: *r4os.rpc_budget.Budget, op: u16, request: *r4os.abi.NetworkSocketRequest, input: []const u8, output: []u8, result: *r4os.abi.NetworkSocketResult) i32 {
    if (op != r4os.abi.network_op_close and app.app.shouldClose()) return r4os.abi.network_error_timeout;
    client.timeout_ticks = budget.remainingTicks() catch |err| return r4os.rpc_budget.code(err);
    request.deadline = r4os.network_family.fromBudget(budget.deadline) catch return r4os.abi.network_error_clock_changed;
    return client.socket(op, request.*, input, output, result);
}

fn testTypedUdp(app: *const App) bool {
    const a = r4os.abi;
    var client: r4os.network_family.Client = undefined;
    if (app.app.networkFamily(.udp, &client) != 0) return failBool(app, "typed UDP endpoint");
    defer _ = client.close();
    const clock = app.app.clock() catch return failBool(app, "typed UDP clock");
    var budget = r4os.rpc_budget.Budget.fromTimeout(clock.read, .{ .kind = a.timeout_kind_finite, .nanoseconds = 5_000_000_000 }) catch return false;
    client.timeout_ticks = budget.remainingTicks() catch return false;
    var provider: a.NetworkProviderInfo = .{};
    if (client.info(&provider) != 0 or provider.capabilities & a.network_cap_datagram_truncate == 0) return failBool(app, "typed UDP provider");
    var request: a.NetworkSocketRequest = .{ .provider = provider.provider, .endpoint = r4os.network_family.common.v4Endpoint(.{0} ** 4, udp_test_port) };
    var current: a.NetworkSocketResult = .{};
    var owned = false;
    defer if (owned) {
        var cleanup = r4os.rpc_budget.Budget.fromTimeout(clock.read, .{ .kind = a.timeout_kind_finite, .nanoseconds = 2_000_000_000 }) catch budget;
        var close_request: a.NetworkSocketRequest = .{ .provider = provider.provider, .socket = current.socket, .generation = current.generation };
        var closed: a.NetworkSocketResult = .{};
        _ = typedCall(app, &client, &cleanup, a.network_op_close, &close_request, "", &.{}, &closed);
    };
    if (typedCall(app, &client, &budget, a.network_op_bind, &request, "", &.{}, &current) != 0 or current.state != a.network_state_ready) return failBool(app, "typed UDP bind");
    owned = true;
    const first = current;
    var probe: a.NetworkSocketResult = .{};
    const unchanged = probe;
    if (typedCall(app, &client, &budget, a.network_op_bind, &request, "", &.{}, &probe) != a.network_error_capacity or !std.meta.eql(probe, unchanged)) return failBool(app, "typed UDP busy bind");
    request = .{ .provider = provider.provider, .socket = first.socket, .generation = first.generation, .bytes = 7 };
    var small: [7]u8 = undefined;
    if (typedCall(app, &client, &budget, a.network_op_recv, &request, "", &small, &probe) != 0 or probe.state != a.network_state_would_block or probe.bytes != 0) return failBool(app, "typed UDP empty receive");
    request.bytes = 0;
    if (typedCall(app, &client, &budget, a.network_op_close, &request, "", &.{}, &probe) != 0 or probe.state != a.network_state_local_closed) return failBool(app, "typed UDP close");
    owned = false;
    request = .{ .provider = provider.provider, .endpoint = r4os.network_family.common.v4Endpoint(.{0} ** 4, udp_test_port) };
    if (typedCall(app, &client, &budget, a.network_op_bind, &request, "", &.{}, &current) != 0 or current.state != a.network_state_ready) return failBool(app, "typed UDP rebind");
    owned = true;
    if (current.generation == first.generation) return failBool(app, "typed UDP reused generation");
    request = .{ .provider = provider.provider, .socket = first.socket, .generation = first.generation };
    const before_stale = probe;
    if (typedCall(app, &client, &budget, a.network_op_close, &request, "", &.{}, &probe) != a.network_error_bad_socket or !std.meta.eql(probe, before_stale)) return failBool(app, "typed UDP stale close");
    request = .{ .provider = provider.provider, .socket = current.socket, .generation = current.generation, .bytes = small.len };
    if (typedCall(app, &client, &budget, a.network_op_recv, &request, "", &small, &probe) != 0 or probe.state != a.network_state_would_block) return failBool(app, "typed UDP replacement remains live");
    app.sys.println("NETIOD typed UDP: busy-bind/empty/close/rebind/exact-generation/stale-close OK");

    var arg_failure: r4os.arguments.Failure = .{};
    var args = app.app.argCursor(.{ .quotes = 0 }, &arg_failure) catch return failBool(app, "echo arguments");
    if (args.next() catch return false) |command| {
        if (!std.ascii.eqlIgnoreCase(command.bytes(app.app.args()) catch return false, "/ECHO")) return failBool(app, "use /ECHO IPv4 PORT");
        const ip_token = (args.next() catch return false) orelse return false;
        const port_token = (args.next() catch return false) orelse return false;
        const ip = r4os.network_family.parseIpv4(ip_token.bytes(app.app.args()) catch return false) orelse return false;
        const port = std.fmt.parseInt(u16, port_token.bytes(app.app.args()) catch return false, 10) catch return false;
        if (port == 0 or (args.next() catch return false) != null) return false;
        const data = "NETIOD independent datagram bytes";
        request.endpoint = r4os.network_family.common.v4Endpoint(ip, port);
        request.bytes = data.len;
        if (typedCall(app, &client, &budget, a.network_op_send, &request, data, &.{}, &probe) != 0 or probe.state != a.network_state_ready or probe.bytes != data.len) return failBool(app, "typed UDP exact send");
        request.endpoint = .{};
        request.bytes = small.len;
        while (true) {
            if (typedCall(app, &client, &budget, a.network_op_recv, &request, "", &small, &probe) != 0) return failBool(app, "typed UDP truncation receive");
            if (probe.state == a.network_state_would_block) {
                app.sys.sleepTicks(1);
                continue;
            }
            if (probe.state != a.network_state_ready or probe.bytes != small.len or probe.original_bytes != data.len or probe.flags != a.network_flag_truncated or !std.mem.eql(u8, &small, data[0..small.len])) return failBool(app, "typed UDP exact prefix/truncation");
            break;
        }
        if (typedCall(app, &client, &budget, a.network_op_recv, &request, "", &small, &probe) != 0 or probe.state != a.network_state_would_block or probe.bytes != 0) return failBool(app, "typed UDP truncated suffix consumed");
        app.sys.println("NETIOD typed UDP echo: exact bytes/prefix/original-size/truncated/consumed OK");
    }
    request = .{ .provider = provider.provider, .socket = current.socket, .generation = current.generation };
    if (typedCall(app, &client, &budget, a.network_op_close, &request, "", &.{}, &probe) != 0 or probe.state != a.network_state_local_closed) return failBool(app, "typed UDP final close");
    owned = false;
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

// Stack storage remains live until this exact request releases its loan.
// Caller timeouts do not authorize releasing a still-running I/O worker.
fn drainRequest(app: *const App, request: *r4os.r4net.NetSocketRequest) void {
    while (request.active and request.request_id != 0) {
        const rc = app.net.netSocketClose(request);
        if (rc == r4os.abi.io_ok or rc == r4os.abi.io_error_not_found) return;
        if (rc == r4os.abi.io_error_busy) {
            _ = app.net.netSocketWait(request, r4os.abi.io_wait_forever);
        }
        app.sys.sleepTicks(1);
    }
}

fn waitOk(app: *const App, request: *r4os.r4net.NetSocketRequest, label: []const u8) bool {
    const rc = app.net.netSocketWait(request, app.sys.ticksFromMilliseconds(5000));
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
