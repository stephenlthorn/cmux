//! The link share bridge against a fake room that speaks `cmux.share/1` (cmux-platform's
//! `ChatShareRoom`): provisioning, its retry and give-up, the host socket's `hello` → `guests`
//! order, redeem, kicks resent until acknowledged, revoke's `end` and `DELETE`, and reconnects.
use super::super::{digest, hex};
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, Fixture, SESSION, WAIT, agent_tab, assert_code, mux_with,
};
use std::cell::RefCell;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Instant;
use tungstenite::handshake::server::{ErrorResponse, Request, Response};

const OWNER_TOKEN: &str = "owner-access-token";

/// What the fake room saw, in order.
#[derive(Debug)]
enum Seen {
    Request { method: String, path: String, bearer: String, body: Value },
    Host { conn: u64, bearer: String },
    Frame { conn: u64, frame: Value },
}

#[derive(Default)]
struct Shared {
    /// Statuses the next `PUT`s answer; then 200 with a new host token.
    puts: Mutex<VecDeque<u16>>,
    /// Statuses the next `DELETE`s answer; then 200.
    deletes: Mutex<VecDeque<u16>>,
    /// Runs once as the next `PUT` is answered.
    on_put: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    host_tokens: AtomicU64,
    conns: AtomicU64,
    /// The newest host socket's outbox: a frame, or `None` to close it.
    to_host: Mutex<Option<Sender<Option<Value>>>>,
    /// The guests the next `hello` names as connected.
    hello: Mutex<Vec<Value>>,
}

struct FakeRoom {
    url: String,
    shared: Arc<Shared>,
    seen: Receiver<Seen>,
    buffer: RefCell<VecDeque<Seen>>,
}

impl FakeRoom {
    fn start(puts: &[u16]) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let shared = Arc::new(Shared::default());
        shared.puts.lock().unwrap().extend(puts);
        let (sender, seen) = channel();
        let (server, base) = (shared.clone(), url.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let (shared, sender, base) = (server.clone(), sender.clone(), base.clone());
                std::thread::spawn(move || serve(stream, &shared, &sender, &base));
            }
        });
        Self { url, shared, seen, buffer: RefCell::default() }
    }

    /// The next thing seen that `wanted` accepts; others stay buffered in order.
    fn take(&self, what: &str, wanted: impl Fn(&Seen) -> bool) -> Seen {
        let mut buffer = self.buffer.borrow_mut();
        if let Some(index) = buffer.iter().position(&wanted) {
            return buffer.remove(index).unwrap();
        }
        let deadline = Instant::now() + WAIT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let seen =
                self.seen.recv_timeout(left).unwrap_or_else(|_| panic!("the room sees {what}"));
            if wanted(&seen) {
                return seen;
            }
            buffer.push_back(seen);
        }
    }

    /// Nothing `wanted` accepts arrives for a moment.
    fn none(&self, what: &str, wanted: impl Fn(&Seen) -> bool) {
        assert!(!self.buffer.borrow().iter().any(&wanted), "the room must not see {what}");
        let deadline = Instant::now() + Duration::from_millis(300);
        while let Ok(seen) =
            self.seen.recv_timeout(deadline.saturating_duration_since(Instant::now()))
        {
            assert!(!wanted(&seen), "the room must not see {what}: {seen:?}");
            self.buffer.borrow_mut().push_back(seen);
        }
    }

    fn host(&self) -> (u64, String) {
        match self.take("a host socket", |s| matches!(s, Seen::Host { .. })) {
            Seen::Host { conn, bearer } => (conn, bearer),
            _ => unreachable!(),
        }
    }

    /// The next frame the daemon sent on host socket `conn`.
    fn frame(&self, conn: u64) -> Value {
        match self.take("a host frame", |s| matches!(s, Seen::Frame { conn: c, .. } if *c == conn))
        {
            Seen::Frame { frame, .. } => frame,
            _ => unreachable!(),
        }
    }

    /// The next `method` request: its path, bearer and body.
    fn request(&self, method: &str) -> (String, String, Value) {
        let wanted = |s: &Seen| matches!(s, Seen::Request { method: m, .. } if m == method);
        match self.take(method, wanted) {
            Seen::Request { path, bearer, body, .. } => (path, bearer, body),
            _ => unreachable!(),
        }
    }

    fn send(&self, frame: Value) {
        self.shared.to_host.lock().unwrap().as_ref().unwrap().send(Some(frame)).unwrap();
    }

    /// Closes the host socket the way a dropped connection does (no close code).
    fn drop_host(&self) {
        self.shared.to_host.lock().unwrap().take().unwrap().send(None).unwrap();
    }
}

fn serve(stream: TcpStream, shared: &Shared, seen: &Sender<Seen>, base: &str) {
    let mut start = [0u8; 3];
    if stream.peek(&mut start).is_ok_and(|n| n == 3) && &start == b"GET" {
        return serve_host(stream, shared, seen);
    }
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_owned();
    let path = parts.next().unwrap_or_default().to_owned();
    let (mut bearer, mut length) = (String::new(), 0usize);
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
            break;
        }
        let (name, value) = header.split_once(':').unwrap_or_default();
        let value = value.trim();
        match name.to_ascii_lowercase().as_str() {
            "authorization" => bearer = value.trim_start_matches("Bearer ").to_owned(),
            "content-length" => length = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    let body = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let (status, reply) = match method.as_str() {
        "PUT" => match shared.puts.lock().unwrap().pop_front() {
            None if shared.on_put.lock().unwrap().is_some() => {
                shared.on_put.lock().unwrap().take().unwrap()();
                let n = shared.host_tokens.fetch_add(1, Ordering::SeqCst) + 1;
                let id = path.rsplit('/').next().unwrap_or_default();
                (
                    200,
                    json!({"host_token": format!("host-token-{n}"), "url_base": format!("{base}/g/{id}")}),
                )
            }
            Some(status) => (status, json!({})),
            None => {
                let n = shared.host_tokens.fetch_add(1, Ordering::SeqCst) + 1;
                let id = path.rsplit('/').next().unwrap_or_default();
                (
                    200,
                    json!({"host_token": format!("host-token-{n}"), "url_base": format!("{base}/g/{id}")}),
                )
            }
        },
        _ => (shared.deletes.lock().unwrap().pop_front().unwrap_or(200), json!({})),
    };
    let _ = seen.send(Seen::Request { method, path, bearer, body });
    let reply = reply.to_string();
    let mut stream = stream;
    let _ = write!(
        stream,
        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    );
}

// tungstenite's handshake callback type fixes its large error variant.
#[allow(clippy::result_large_err)]
fn serve_host(stream: TcpStream, shared: &Shared, seen: &Sender<Seen>) {
    let mut bearer = String::new();
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let header = request.headers().get("authorization").and_then(|v| v.to_str().ok());
        bearer = header.unwrap_or_default().trim_start_matches("Bearer ").to_owned();
        Ok(response)
    };
    let Ok(mut socket) = tungstenite::accept_hdr(stream, callback) else { return };
    let conn = shared.conns.fetch_add(1, Ordering::SeqCst) + 1;
    let (outbox, frames) = channel();
    *shared.to_host.lock().unwrap() = Some(outbox);
    let _ = seen.send(Seen::Host { conn, bearer });
    socket.get_mut().set_read_timeout(Some(Duration::from_millis(10))).unwrap();
    let guests = shared.hello.lock().unwrap().clone();
    let hello = json!({"v": 1, "t": "hello", "guests": guests}).to_string();
    let _ = socket.send(Message::text(hello));
    loop {
        while let Ok(next) = frames.try_recv() {
            let Some(frame) = next else {
                let _ = socket.close(None);
                let _ = socket.flush();
                return;
            };
            let _ = socket.send(Message::text(frame.to_string()));
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let frame = serde_json::from_str(text.as_str()).unwrap();
                let _ = seen.send(Seen::Frame { conn, frame });
            }
            Ok(Message::Close(_)) => return,
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return,
        }
    }
}

fn fast() -> Timing {
    Timing {
        request: Duration::from_secs(2),
        window: Duration::from_millis(400),
        backoff_min: Duration::from_millis(20),
        backoff_max: Duration::from_millis(100),
    }
}

/// A daemon with one agent chat, bridged to `room`.
fn bridged(label: &str, room: &FakeRoom) -> (FakeAcpmux, Arc<Mux>, u64, Client) {
    bridged_with(label, room, Fixture::default())
}

fn bridged_with(
    label: &str,
    room: &FakeRoom,
    fixture: Fixture,
) -> (FakeAcpmux, Arc<Mux>, u64, Client) {
    let fake = FakeAcpmux::start_with(label, fixture);
    let mux = mux_with(&fake, label);
    assert!(shares(&mux).bridge.configure(Some(&room.url), fast()));
    let surface = agent_tab(&mux, Some(SESSION));
    let owner = Client::connect(&mux, label);
    (fake, mux, surface, owner)
}

fn create(owner: &mut Client, surface: u64) -> Value {
    owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
        "owner_token":OWNER_TOKEN}))
}

fn state(owner: &mut Client) -> Value {
    let reply = owner.request(json!({"cmd":"agent-session-share-list"}));
    reply["data"]["shares"][0].clone()
}

fn redeem(id: &str, attempt: &str, secret: &Value) -> Value {
    json!({"v": 1, "t": "redeem", "request_id": id, "attempt_id": attempt, "secret": secret,
        "name": "Theo"})
}

#[test]
fn a_provisioned_share_answers_hello_with_its_guests_and_redeems_through_the_daemon() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-redeem", &room);
    let reply = create(&mut owner, surface);
    assert_eq!(reply["ok"], true, "{reply}");
    let share = &reply["data"];
    let (id, secret) = (share["share_id"].as_str().unwrap(), share["secret"].as_str().unwrap());
    assert_eq!(share["url"], format!("{}/g/{id}#{secret}", room.url));
    // The host socket: the daemon's first frame after `hello` is its guest list.
    let (conn, bearer) = room.host();
    assert_eq!(bearer, "host-token-1");
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "guests", "active": []}));
    room.send(redeem("r1", "attempt-1", &json!(secret)));
    let redeemed = room.frame(conn);
    assert_eq!(
        (redeemed["t"].clone(), redeemed["request_id"].clone()),
        (json!("redeemed"), json!("r1"))
    );
    let guest = redeemed["guest_id"].clone();
    assert_eq!(guest.as_str().unwrap().len(), 11);
    // A lost reply's retry gets the same guest; another attempt finds the one use spent.
    room.send(redeem("r2", "attempt-1", &json!(secret)));
    assert_eq!(room.frame(conn)["guest_id"], guest);
    room.send(redeem("r3", "attempt-2", &json!(secret)));
    assert_eq!(
        room.frame(conn),
        json!({"v": 1, "t": "redeemed", "request_id": "r3", "error": "share.used"})
    );
    room.send(redeem("r4", "attempt-3", &json!("AAAAAAAAAAAAAAAAAAAAAA")));
    assert_eq!(room.frame(conn)["error"], "share.secret");
    // A dropped socket reconnects, and the fresh `hello` gets the guest list first again.
    room.drop_host();
    let (again, bearer) = room.host();
    assert_eq!(bearer, "host-token-1");
    assert_eq!(room.frame(again), json!({"v": 1, "t": "guests", "active": [guest]}));
}

#[test]
fn a_kick_is_resent_until_the_room_acknowledges_it_and_a_revoke_ends_and_deletes() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-kick", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["active"], json!([]));
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "name":"Theo",
        "attempt_id":"attempt-1"}))["data"]["guest_id"]
        .clone();
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":guest});
    assert_eq!(owner.request(kick)["ok"], true);
    let kicked = json!({"v": 1, "t": "kick", "guest_id": guest});
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "guests", "active": []}));
    assert_eq!(room.frame(conn), kicked);
    // Not acknowledged: the next connect sends it again, after the guest list.
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    assert_eq!(room.frame(conn), kicked);
    room.send(json!({"v": 1, "t": "kicked", "guest_id": guest}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    // Acknowledged: not resent. A revoke sends `end`, closes, and deletes with the host token.
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "revoked"}));
    let (path, bearer, _) = room.request("DELETE");
    let id = share["share_id"].as_str().unwrap();
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), "host-token-1".to_owned()));
    room.none("another host socket", |s| matches!(s, Seen::Host { .. }));
    assert_eq!(state(&mut owner)["state"], "revoked");
}

#[test]
fn a_provisioned_share_answers_its_link_and_a_revoke_deletes_it_with_the_host_token() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-put", &room);
    let reply = create(&mut owner, surface);
    assert_eq!(reply["ok"], true, "{reply}");
    let share = &reply["data"];
    let (id, secret) = (share["share_id"].as_str().unwrap(), share["secret"].as_str().unwrap());
    assert_eq!(share["url"], format!("{}/g/{id}#{secret}", room.url));
    let (path, bearer, body) = room.request("PUT");
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), OWNER_TOKEN.to_owned()));
    assert_eq!(body["secret_sha256"], hex(&digest(&[secret])));
    assert_eq!(body["uses"], 1);
    assert_eq!(body["expires_at"], share["expires_at"]);
    assert_eq!(body["provision_key"].as_str().unwrap().len(), 22);
    let listed = state(&mut owner);
    assert_eq!(
        (listed["state"].clone(), listed["room"].clone()),
        (json!("active"), json!(room.url))
    );
    assert!(!listed.to_string().contains("host-token"), "the host token stays in the daemon");
    // A redeem is the daemon's, as before; a revoke deletes the room with the host token.
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":id,
        "secret":secret, "name":"Theo", "attempt_id":"attempt-1"}));
    assert_eq!(guest["ok"], true, "{guest}");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":id});
    assert_eq!(owner.request(revoke)["ok"], true);
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), "host-token-1".to_owned()));
    room.none(
        "a second DELETE",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
    assert_eq!(state(&mut owner)["state"], "revoked");
}

#[test]
fn an_unreachable_room_is_retried_then_the_share_is_revoked_and_deleted() {
    let room = FakeRoom::start(&[503; 64]);
    let (_fake, _mux, surface, mut owner) = bridged("room-down", &room);
    let reply = create(&mut owner, surface);
    assert_code(&reply, "share.room_unreachable");
    let listed = state(&mut owner);
    assert_eq!(listed["state"], "provisioning");
    let redeem = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":listed["share_id"], "secret":"x", "name":"Theo", "attempt_id":"a"}));
    assert_code(&redeem, "share.secret");
    // Retried with the same provision key, then given up: revoked, and the room told with the
    // owner's token (no host token was ever answered).
    let (_, _, first) = room.request("PUT");
    let (_, _, second) = room.request("PUT");
    assert_eq!(first["provision_key"], second["provision_key"]);
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!(path, format!("/v1/chat-shares/{}", listed["share_id"].as_str().unwrap()));
    assert_eq!(bearer, OWNER_TOKEN);
    assert_eq!(state(&mut owner)["state"], "revoked");
    room.none("a host socket", |s| matches!(s, Seen::Host { .. }));
}

#[test]
fn a_room_that_answers_after_create_failed_is_deleted_with_its_host_token() {
    let room = FakeRoom::start(&[503, 503]);
    let (_fake, _mux, surface, mut owner) = bridged("room-late", &room);
    assert_code(&create(&mut owner, surface), "share.room_unreachable");
    for _ in 0..3 {
        room.request("PUT");
    }
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
    assert_eq!(state(&mut owner)["state"], "revoked");
    room.none("a host socket", |s| matches!(s, Seen::Host { .. }));
}

#[test]
fn a_create_without_sign_in_or_that_the_room_refuses_opens_nothing() {
    let room = FakeRoom::start(&[409, 401]);
    let (_fake, _mux, surface, mut owner) = bridged("room-refused", &room);
    let unsigned = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface}));
    assert_code(&unsigned, "share.needs_sign_in");
    assert_code(&create(&mut owner, surface), "share.room_refused");
    assert_eq!(state(&mut owner)["state"], "revoked");
    assert_code(&create(&mut owner, surface), "share.needs_sign_in");
    room.request("PUT");
    room.request("PUT");
    room.none("a DELETE or a host socket", |s| {
        matches!(s, Seen::Host { .. })
            || matches!(s, Seen::Request { method, .. } if method == "DELETE")
    });
}

fn shares_of(mux: &Mux) -> &LinkShares {
    &mux.control_clients.agent_sessions.link_shares
}

#[test]
fn a_room_that_answers_after_the_share_expired_never_opens_it() {
    let room = FakeRoom::start(&[503, 503, 503]);
    let (_fake, mux, surface, mut owner) = bridged("room-expired", &room);
    assert_code(&create(&mut owner, surface), "share.room_unreachable");
    // The share's day passes while the PUT is retried; then the room answers.
    shares_of(&mux).advance(Duration::from_secs(2 * 86_400));
    for _ in 0..4 {
        room.request("PUT");
    }
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1", "the late room is deleted with its own token");
    let listed = state(&mut owner);
    assert_eq!(listed["state"], "expired", "never active: {listed}");
    room.none(
        "a second DELETE",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
}

#[test]
fn a_delete_the_room_refuses_stays_queued_and_is_retried_until_acknowledged() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().extend([403, 401, 503]);
    let (_fake, _mux, surface, mut owner) = bridged("room-delete", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    for _ in 0..4 {
        let (_, bearer, _) = room.request("DELETE");
        assert_eq!(bearer, "host-token-1");
    }
    room.none(
        "a DELETE after the room's 200",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
}

#[test]
fn a_room_whose_answer_could_not_be_written_is_still_deleted_with_its_host_token() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().push_back(503);
    let (_fake, mux, surface, mut owner) = bridged("room-unsaved", &room);
    // The room answers the PUT, and the write of its answer fails.
    let refusing = mux.clone();
    *room.shared.on_put.lock().unwrap() = Some(Box::new(move || {
        shares_of(&refusing).refuse_writes.store(true, Ordering::Relaxed);
    }));
    assert_code(&create(&mut owner, surface), "share.unsaved");
    room.request("PUT");
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1", "the host token the write lost is held");
    assert_eq!(state(&mut owner)["state"], "provisioning", "the record never opened");
    // Once a write succeeds the room and its DELETE are the record's.
    shares_of(&mux).refuse_writes.store(false, Ordering::Relaxed);
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
    let listed = state(&mut owner);
    assert_eq!(
        (listed["state"].clone(), listed["room"].clone()),
        (json!("revoked"), json!(room.url))
    );
}

#[test]
fn closing_the_chat_closes_its_share_its_guests_and_its_room() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-closed", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "name":"Theo",
        "attempt_id":"attempt-1"}));
    let mut link = Client::connect(&mux, "room-closed-guest");
    let bound = link.request(json!({"cmd":"agent-session-proxy-bind", "link_guest":
        {"share_id": share["share_id"], "guest_id": guest["data"]["guest_id"]}}));
    assert_eq!(bound["ok"], true, "{bound}");
    // acpmux says the chat was closed.
    crate::server::close_chat_shares(&mux, SESSION);
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "closed"}));
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
    let deadline = Instant::now() + WAIT;
    while !mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().is_empty() {
        assert!(Instant::now() < deadline, "the guest's connection is closed");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(state(&mut owner)["state"], "closed");
    room.none("another host socket", |s| matches!(s, Seen::Host { .. }));
}

// MARK: The guest relay

impl FakeRoom {
    /// The next frame of type `t` the daemon sent on host socket `conn`.
    fn next(&self, conn: u64, t: &str) -> Value {
        let wanted =
            |s: &Seen| matches!(s, Seen::Frame { conn: c, frame } if *c == conn && frame["t"] == t);
        match self.take(t, wanted) {
            Seen::Frame { frame, .. } => frame,
            _ => unreachable!(),
        }
    }
}

/// A transcript record of `bytes` bytes of text.
fn sized(seq: u64, bytes: usize) -> Value {
    json!({"sessionId": SESSION, "seq": seq, "dir": "in", "kind": "agent_message",
        "msg": {"text": "x".repeat(bytes)}})
}

/// A share with two redeemed guests and its host socket past `guests`: (share, [guest ids], conn).
fn two_guests(room: &FakeRoom, owner: &mut Client, surface: u64) -> (Value, [String; 2], u64) {
    let reply = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
        "owner_token":OWNER_TOKEN, "uses":2}));
    let share = reply["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["active"], json!([]));
    let mut guests = [String::new(), String::new()];
    for (index, name) in ["Ann", "Bob"].into_iter().enumerate() {
        let reply = owner.request(json!({"cmd":"agent-session-share-redeem",
            "share_id":share["share_id"], "secret":share["secret"], "name":name,
            "attempt_id":format!("attempt-{index}")}));
        guests[index] = reply["data"]["guest_id"].as_str().unwrap().to_owned();
    }
    (share, guests, conn)
}

#[test]
fn a_guest_gets_a_bounded_snapshot_its_own_records_and_its_prompts_states() {
    let room = FakeRoom::start(&[]);
    // 200 KiB, 200 KiB, a 300 KiB record (sent cut) and 200 KiB: the newest that fit in 512 KiB.
    let page = vec![
        sized(10, 200 << 10),
        sized(11, 200 << 10),
        sized(12, 300 << 10),
        sized(13, 200 << 10),
    ];
    let history = vec![sized(3, 10), sized(4, 10)];
    let fixture = Fixture { page, history, ..Fixture::default() };
    let (mut fake, _mux, surface, mut owner) = bridged_with("relay-snap", &room, fixture);
    let (_, [ann, bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    let snapshot = room.next(conn, "snapshot");
    assert!(snapshot.to_string().len() <= 512 << 10, "the whole frame fits");
    assert_eq!((snapshot["to"].clone(), snapshot["has_more"].clone()), (json!(ann), json!(true)));
    let seqs: Vec<u64> = snapshot["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["seq"].as_u64().unwrap())
        .collect();
    assert_eq!(seqs, vec![11, 12, 13], "the newest records, oldest first");
    let cut = &snapshot["records"][1];
    assert_eq!(
        (cut["truncated"].clone(), cut["kind"].clone()),
        (json!(true), json!("agent_message"))
    );
    assert!(cut["full_bytes"].as_u64().unwrap() > 300 << 10 && cut.get("msg").is_none());
    assert_eq!(
        (snapshot["watermark"].clone(), snapshot["chat"]["status"].clone()),
        (json!(13), json!("running"))
    );
    // The record acpmux sent while the attach was answered follows the snapshot, to Ann only.
    let early = room.next(conn, "records");
    assert_eq!((early["to"].clone(), early["records"][0]["seq"].clone()), (json!([ann]), json!(2)));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    // Ann's prompt reaches acpmux as hers and held; its states follow acpmux's records.
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c1",
        "text": "hello"}));
    let sent = fake.frame();
    assert_eq!(sent["method"], "session/prompt");
    let prompt = sent["params"]["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    assert_eq!(sent["params"]["_meta"]["acpmux"]["author"]["approval"], "owner");
    let state = |state: &str| {
        json!({"v": 1, "t": "prompt_state", "guest_id": ann,
        "client_id": "c1", "prompt_id": prompt, "state": state})
    };
    assert_eq!(room.next(conn, "prompt_state"), state("held"));
    for (seq, kind, extra) in [
        (20, "queued", json!({"awaitingOwner": true, "revision": 0})),
        (21, "queue_approved", json!({"revision": 0})),
    ] {
        let mut msg = json!({"promptId": prompt});
        msg.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        fake.notify(
            "_acpmux/event",
            json!({"sessionId": SESSION, "seq": seq, "dir": "mux",
            "kind": kind, "msg": msg}),
        );
        let records = room.next(conn, "records");
        assert_eq!(
            (records["to"].clone(), records["records"][0]["seq"].clone()),
            (json!([ann]), json!(seq))
        );
    }
    assert_eq!(room.next(conn, "prompt_state"), state("approved"), "held was already said");
    room.send(json!({"v": 1, "t": "prompt_status", "guest_id": ann, "client_ids": ["c1", "c9"]}));
    assert_eq!(room.next(conn, "prompt_state"), state("approved"));
    room.send(json!({"v": 1, "t": "older", "guest_id": ann, "before_seq": 11}));
    let page = room.next(conn, "page");
    assert_eq!((page["to"].clone(), page["has_more"].clone()), (json!(ann), json!(false)));
    assert_eq!(page["records"].as_array().unwrap().len(), 2);
    // Nothing went to Bob, whose browser never joined, nor about a prompt it never sent.
    room.none("a frame for Bob", |s| {
        matches!(s, Seen::Frame { frame, .. }
        if frame.to_string().contains(&bob))
    });
    room.none("a second state", |s| {
        matches!(s, Seen::Frame { frame, .. }
        if frame["t"] == "prompt_state")
    });
}

#[test]
fn reconnects_get_fresh_snapshots_and_a_kick_ends_the_guests_relay() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-again", &room);
    let (share, [ann, bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    // A guest reconnect: a fresh snapshot.
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    // A host reconnect: `guests` first, then a snapshot for each guest still connected.
    room.shared
        .hello
        .lock()
        .unwrap()
        .extend([json!({"guest_id": ann, "name": "Ann"}), json!({"guest_id": bob, "name": "Bob"})]);
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "guests", "active": [ann, bob]}));
    let mut to: Vec<Value> = (0..2).map(|_| room.next(conn, "snapshot")["to"].clone()).collect();
    to.sort_by_key(Value::to_string);
    let mut both = vec![json!(ann), json!(bob)];
    both.sort_by_key(Value::to_string);
    assert_eq!(to, both);
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    // A kick ends Ann's relay at the daemon: her prompts reach nothing.
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":ann});
    assert_eq!(owner.request(kick)["ok"], true);
    assert_eq!(room.next(conn, "kick")["guest_id"], json!(ann));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c1",
        "text": "hello"}));
    fake.no_frame();
    // Bob's still does.
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": bob, "client_id": "c1",
        "text": "hello"}));
    assert_eq!(fake.frame()["method"], "session/prompt");
    assert_eq!(room.next(conn, "prompt_state")["guest_id"], json!(bob));
}
