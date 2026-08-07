<*
 The socket side of the transport: a thread that accepts connections and a
 mailbox the application drains on its own thread.

 The split is the point. A server whose state belongs to a single-threaded
 application — a UI's document, a scene graph — cannot have a second thread
 calling into it, so the thread here does nothing but I/O: accept, read one
 message, put it in the queue, poke the application awake. `Listener.pump`
 runs on the application's thread and is where `Server.handle_message` is
 called, so every handler still sees the same one-owner world it did over
 stdio.

 One connection carries one message and is closed when the answer is written.
 Nothing here keeps a connection open, so a client that dies mid-request costs
 a socket and no state.
*>
module mcp;

import std::io;
import std::net::tcp;
import std::thread;
import std::core::mem;
import std::core::mem::allocator;
import std::core::mem::allocators;

// Requests held while the application is busy. A queue this deep is already
// generous for one client asking one question at a time; past it the answer is
// an error rather than an unbounded backlog, so a runaway client cannot grow
// the process without limit.
const usz MAX_PENDING = 16;

<*
 What the application is poked with when a request lands. Called on the
 listener's thread, so it must be safe to call from a foreign thread — on a
 windowing toolkit that means the "post an event to the loop" primitive, not
 anything that touches widgets.
*>
alias WakeFn = fn void(void* ctx);

// One accepted request: the connection it came in on, the message read off it,
// and the framing it arrived in — which decides how the answer is written, and
// so has to travel with it. The message is allocated by the listener thread and
// freed by whoever answers it, so it comes from `Listener.wire` rather than from
// `mem`, which is a different allocator on each of the two threads.
struct Pending @private
{
	TcpSocket socket;
	String message;
	Framing framing;
}

<*
 A listening socket, its thread, and the queue between them.

 **Must not move once started.** The thread holds this pointer.

 Fields are private in spirit — read `port` and `listening()`, and leave the
 rest to `start` / `pump` / `stop`.
*>
struct Listener
{
	TcpServerSocket server;
	Thread thread;
	Mutex mutex;
	Pending[MAX_PENDING] queue;
	usz head;
	usz count;
	WakeFn wake;
	void* wake_ctx;

	<*
	 Where a queued message is allocated and freed.

	 A message is read on the listener thread and released on the application's,
	 and `mem` names a different allocator on each — it is per-thread, and an
	 application that installs one of its own installs it only on the thread that
	 asked. Freeing there what was allocated here is then a release against an
	 allocator that never issued the pointer: undefined at best, and caught
	 outright by a checking allocator.

	 So both sides name this one instead, and it must stay thread-safe and
	 reachable from both. `start` sets it to the process-wide libc allocator.
	*>
	Allocator wire;

	int port;
	bool running; // guarded by `mutex`: the thread's "keep going" flag
	bool started;
}

<*
 Bind the port and start accepting.

 Nothing is served until `pump` is called: the thread only fills the queue.

 Raises when the port is taken — most often another copy of the application —
 or when the thread cannot be created; nothing is left listening either way.

 @param port : `The TCP port to listen on. Loopback only — this binds 127.0.0.1.`
 @param wake : `Poked from the listener thread once a request is queued; null for an application that polls.`
 @param wake_ctx : `Handed to the wake function untouched.`
 @param wire : `Where queued messages live; see Listener.wire. Must be thread-safe and reachable from both threads, which rules out anything per-thread.`
*>
fn void? Listener.start(&self, int port, WakeFn wake = null, void* wake_ctx = null,
	Allocator wire = &allocators::LIBC_ALLOCATOR)
{
	self.server = tcp::listen("127.0.0.1", port, 8, SocketOption.REUSEADDR)!;
	self.port = port;
	self.wake = wake;
	self.wake_ctx = wake_ctx;
	self.wire = wire;
	self.head = 0;
	self.count = 0;
	self.mutex.init()!;
	self.running = true;
	self.started = true;

	if (catch error = self.thread.create(&accept_loop, self))
	{
		self.running = false;
		self.started = false;
		(void)self.server.close();
		self.mutex.destroy();
		return error~;
	}
}

fn bool Listener.listening(&self) => self.started;

<*
 Answer everything that has arrived, on the calling thread.

 Call it once per iteration of the application's own loop. Each queued message
 goes through `server.handle_message` here, so handlers run where the
 application's state lives; the response is written and the connection closed
 before the next one is taken.

 A notification — a message with no id — is answered with nothing and the
 connection is closed, which is what tells the relay on the other end that no
 response is coming.

 @param server : `The server whose handlers answer. May differ between calls.`
 @return `How many messages were handled; 0 when nothing was waiting.`
*>
fn usz Listener.pump(&self, Server* server)
{
	if (!self.started) return 0;

	usz handled = 0;
	while (true)
	{
		Pending job;
		bool taken = false;

		self.mutex.@in_lock()
		{
			if (self.count > 0)
			{
				job = self.queue[self.head];
				self.head = (self.head + 1) % MAX_PENDING;
				self.count--;
				taken = true;
			}
		};
		if (!taken) break;

		String response = server.handle_message(job.message);
		alloc::free(self.wire, job.message);
		answer(job.socket, response, job.framing);
		if (response.len > 0) alloc::free(mem, response);
		handled++;
	}
	return handled;
}

<*
 Stop accepting and join the thread.

 Requests already queued are dropped with their connections closed, not
 answered: the application is on its way down, and a client waiting on a
 socket that closes learns more from that than from an answer built out of
 half-torn-down state.
*>
fn void Listener.stop(&self)
{
	if (!self.started) return;

	self.mutex.@in_lock()
	{
		self.running = false;
	};

	// A thread parked in accept() does not notice a flag. The knock is a
	// connection it will accept and then discard, which is the portable way to
	// get it back to the top of its loop — closing the socket underneath it is
	// not: the behaviour of an accept() whose descriptor is closed by another
	// thread is undefined, and hangs on some systems.
	if (try knock = tcp::connect("127.0.0.1", self.port)) (void)knock.close();

	(void)self.thread.join();
	(void)self.server.close();

	while (self.count > 0)
	{
		Pending job = self.queue[self.head];
		self.head = (self.head + 1) % MAX_PENDING;
		self.count--;
		alloc::free(self.wire, job.message);
		(void)job.socket.close();
	}

	self.mutex.destroy();
	self.started = false;
}

// ---------------------------------------------------------------------------

<*
 The listener thread: accept, read one message, queue it, poke the application.

 Nothing here parses JSON or touches the server. A message that cannot be
 queued is refused on the spot — from this thread, on a socket nobody else
 holds yet — because the alternative is dropping it silently and leaving the
 client waiting for an answer that is never coming.
*>
fn int accept_loop(void* arg) @private
{
	Listener* self = (Listener*)arg;

	while (self.alive())
	{
		TcpSocket? accepted = tcp::accept(&self.server);
		if (catch accepted) break;

		TcpSocket socket = accepted;
		if (!self.alive())
		{
			(void)socket.close();
			break;
		}

		Incoming request = read_request(&socket, self.wire);
		if (request.refused)
		{
			(void)socket.write(http_refusal());
			(void)socket.close();
			continue;
		}
		if (request.body.len == 0)
		{
			(void)socket.close();
			continue;
		}

		if (!self.offer({ .socket = socket, .message = request.body, .framing = request.framing }))
		{
			alloc::free(self.wire, request.body);
			String busy = error_message(null, INTERNAL_ERROR, "Server busy: too many requests in flight");
			answer(socket, busy, request.framing);
			alloc::free(mem, busy);
			continue;
		}

		if (self.wake) self.wake(self.wake_ctx);
	}
	return 0;
}

fn bool Listener.alive(&self)
{
	bool alive;
	self.mutex.@in_lock()
	{
		alive = self.running;
	};
	return alive;
}

// True when the request was queued; false when the queue is full.
fn bool Listener.offer(&self, Pending job)
{
	bool queued = false;
	self.mutex.@in_lock()
	{
		if (self.count < MAX_PENDING)
		{
			self.queue[(self.head + self.count) % MAX_PENDING] = job;
			self.count++;
			queued = true;
		}
	};
	return queued;
}

<*
 One answer, then the connection goes.

 Over LINE framing an empty response is a notification's: the close is the
 whole message, and writing nothing is what says so. HTTP has no such move —
 a client is holding a request open and needs a status line — so the empty
 answer becomes 202 there.
*>
fn void answer(TcpSocket socket, String response, Framing framing) @private
{
	TcpSocket writable = socket;
	defer (void)writable.close();

	if (framing == HTTP)
	{
		String http = http_response(response);
		defer alloc::free(mem, http);
		(void)writable.write(http);
		return;
	}

	if (response.len == 0) return;
	if (catch writable.write(response)) return;
	(void)writable.write("\n");
}
