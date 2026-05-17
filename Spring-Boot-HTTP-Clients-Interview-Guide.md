# Spring Boot HTTP Clients — Interview Q&A

---

## Fundamentals

**Q1. What HTTP clients are available in Spring Boot and how do they differ?**

Spring Boot offers five main HTTP clients:

- **RestTemplate** — legacy, synchronous, blocking. In maintenance mode since Spring 5. No new features.
- **WebClient** — modern, reactive, non-blocking. Built on Netty. Recommended for reactive stacks.
- **RestClient** — introduced in Spring Boot 3.2. Synchronous with a fluent API. Modern replacement for RestTemplate.
- **Feign Client** — declarative, interface-based. Part of Spring Cloud OpenFeign. Generates implementation via dynamic proxies at runtime.
- **Java 11+ HttpClient** — standard JDK library. Supports both sync and async. Integrable via `JdkClientHttpRequestFactory` in Spring 6+.

Key differences are the threading model (blocking vs non-blocking), API style, and HTTP/2 support.

---

**Q2. Why is RestTemplate considered legacy and what should you use instead?**

RestTemplate has been in maintenance mode since Spring 5 — no new features will be added. It is still production-safe if already in use, but for new development:

- Use **RestClient** for synchronous, servlet-based stacks (especially with Java 21 virtual threads).
- Use **WebClient** for reactive, non-blocking stacks.

There is no urgent need to migrate existing RestTemplate usage unless you need the new capabilities.

---

**Q3. All HTTP clients ultimately use TCP. Why is there a performance difference between them?**

The difference is not at the TCP transport layer but in everything above it:

- **Thread model** — blocking clients park a thread per in-flight request; non-blocking clients do not.
- **OS I/O mechanism** — blocking uses `read()` with thread parking; non-blocking uses `epoll`/`kqueue` with callbacks.
- **Connection pool utilization** — blocking pools tie connections to threads; non-blocking pools achieve near 100% utilization.
- **HTTP protocol version** — HTTP/2 multiplexes streams over a single connection; HTTP/1.1 does not.
- **Memory allocation** — blocking clients use ~1MB per thread stack; Netty uses pooled, off-heap `ByteBuf` buffers.

TCP is the road. The clients differ in how efficiently they use it.

---

## Thread Model & I/O

**Q4. Explain blocking vs non-blocking I/O in the context of HTTP clients.**

**Blocking I/O:**
- Thread calls `read()` on a socket.
- The OS parks the thread until data arrives.
- Thread resumes — incurring two context switches (park + wake).
- One thread is consumed per in-flight request.

**Non-blocking I/O (NIO):**
- Thread registers interest on the socket with `epoll` (Linux) or `kqueue` (macOS).
- Thread is free to do other work immediately.
- OS signals a selector/event loop when data is ready.
- A callback/handler is invoked — no thread was parked.

This eliminates thread parking and context-switch overhead entirely, which is the core reason non-blocking clients scale better under high concurrency.

---

**Q5. How does Netty's EventLoop work and why does WebClient use it?**

Netty's EventLoop is a single-threaded loop that continuously polls registered channels for I/O readiness using `epoll`/`kqueue`. Key properties:

- A single EventLoop manages thousands of connections without blocking.
- When data is ready on a channel, the EventLoop dispatches the registered handler (callback).
- Multiple EventLoops run in a pool (`EventLoopGroup`) to utilise all CPU cores.

WebClient uses Netty by default because this model maximises throughput for I/O-bound outbound calls — the same model used by nginx. Netty also uses pooled, off-heap `ByteBuf` memory, which reduces GC pressure significantly.

---

**Q6. How do Java 21 virtual threads change the story for blocking clients?**

Virtual threads are JVM-managed threads with stacks of only a few KB (vs ~1MB for platform/OS threads).

Key behaviour: when a virtual thread blocks on I/O, the JVM **unmounts** it from the carrier (OS) thread, freeing the carrier to run other virtual threads. This means:

- Thousands of concurrent blocking calls without thread pool exhaustion.
- No OS-level context switch cost for parked virtual threads.
- RestClient + virtual threads can approach WebClient-level throughput for I/O-bound workloads.

Enable in Spring Boot 3.2+ with:
```properties
spring.threads.virtual.enabled=true
```

Note: The OS I/O model is still blocking (`read()`); virtual threads absorb the cost at the JVM level, not the kernel level.

---

## Connection Pool & Configuration

**Q7. What is a connection pool in an HTTP client and what happens if it is misconfigured?**

A connection pool reuses existing TCP connections to avoid the overhead of a new TCP handshake + TLS handshake for every request.

Key configuration parameters (Apache HttpClient example):
```java
PoolingHttpClientConnectionManager cm = new PoolingHttpClientConnectionManager();
cm.setMaxTotal(200);           // max total connections across all hosts
cm.setDefaultMaxPerRoute(50);  // max connections to a single host
```

Misconfiguration consequences:
- **Too low** — connection wait timeouts under load; requests queue up; throughput collapses.
- **Too high** — exhausts server-side resources; may cause connection refused errors on the target service.

In blocking clients, pool size must match expected concurrency. In non-blocking clients (Netty), a smaller pool is sufficient because connections are not tied to threads.

---

**Q8. What are the three timeout types to configure and what does each control?**

```java
RequestConfig config = RequestConfig.custom()
    .setConnectTimeout(Timeout.ofSeconds(3))           // TCP connection establishment
    .setResponseTimeout(Timeout.ofSeconds(10))         // waiting for server response
    .setConnectionRequestTimeout(Timeout.ofSeconds(5)) // acquiring conn from pool
    .build();
```

- **Connect timeout** — how long to wait to establish the TCP connection to the server.
- **Response timeout** — how long to wait after the request is sent for the first byte of the response.
- **Connection request timeout** — how long to wait to acquire a connection from the pool (relevant under high load).

All three should be set explicitly. Leaving them at defaults (often infinite) can cause thread or resource exhaustion in production.

---

**Q9. How does HTTP/2 multiplexing improve performance over HTTP/1.1?**

**HTTP/1.1:**
- One request-response cycle per connection at a time.
- Head-of-line blocking: request 2 on a connection waits for response 1.
- High concurrency requires many parallel connections — each with its own TCP + TLS handshake cost.

**HTTP/2:**
- Multiple streams are multiplexed over a **single** TCP connection simultaneously.
- No head-of-line blocking at the HTTP layer.
- Headers are compressed with HPACK — reduces bandwidth.
- TCP and TLS handshake cost is amortised across all streams.

WebClient + Netty supports HTTP/2 natively. RestTemplate/RestClient require explicit configuration and still lack the event-loop advantage to fully exploit it.

---

## Advanced Topics

**Q10. How does Feign work internally and when would you choose it?**

Feign generates a runtime implementation of a Java interface using **dynamic proxies**:

1. You annotate an interface with `@FeignClient` and method-level HTTP annotations.
2. At startup, Feign creates a proxy that intercepts method calls.
3. The proxy serializes parameters, builds the HTTP request, delegates to the underlying HTTP client (OkHttp or Apache HttpClient), and deserializes the response.

Choose Feign when:
- Services call each other in a microservice architecture.
- Combined with Eureka for service discovery (Feign resolves service names automatically).
- You want declarative, DRY client code without boilerplate.

Avoid Feign for reactive stacks — it is inherently synchronous/blocking.

---

**Q11. How would you configure mTLS for service-to-service calls in Spring Boot?**

Mutual TLS means both client and server authenticate each other with certificates.

For Apache HttpClient / RestClient:
```java
SSLContext sslContext = SSLContextBuilder.create()
    .loadKeyMaterial(keyStore, keyPassword)      // client certificate + private key
    .loadTrustMaterial(trustStore, null)          // trusted server certificates
    .build();
```

For WebClient (Netty):
```java
SslContext sslContext = SslContextBuilder.forClient()
    .keyManager(certChain, privateKey)
    .trustManager(trustStore)
    .build();

HttpClient httpClient = HttpClient.create()
    .secure(spec -> spec.sslContext(sslContext));
```

mTLS is standard in zero-trust service meshes where both sides must authenticate each other, not just the server.

---

**Q12. How do you add retry and resilience to an HTTP client in Spring Boot?**

Use **Resilience4j** via `spring-cloud-starter-circuitbreaker-resilience4j`.

For WebClient (reactive):
```java
webClient.get()
    .retrieve()
    .bodyToMono(Response.class)
    .retryWhen(Retry.backoff(3, Duration.ofMillis(500))
        .filter(ex -> ex instanceof WebClientRequestException));
```

For RestClient / RestTemplate (imperative):
```java
@CircuitBreaker(name = "myService", fallbackMethod = "fallback")
@Retry(name = "myService")
public Response callService() { ... }
```

Best practices:
- Retry only on idempotent operations (GET, PUT) — never blindly retry POST.
- Do not retry on 4xx client errors — they will not self-resolve.
- Use exponential backoff with jitter to avoid thundering herd on recovery.

---

**Q13. When would you choose WebClient vs RestClient in a new Spring Boot 3.2+ project?**

| Factor | Choose WebClient | Choose RestClient |
|---|---|---|
| Stack | Spring WebFlux (reactive) | Spring MVC (servlet) |
| Java version | Any | Java 21+ for best results |
| Concurrency model | Non-blocking, event-loop | Blocking + virtual threads |
| API complexity | Higher (Mono/Flux) | Lower (synchronous, familiar) |
| Backpressure needed | Yes | No |

**Rule of thumb:** For most new enterprise microservices on Java 21 with Spring Boot 3.2+, **RestClient is the pragmatic default**. The synchronous API is easier to reason about, debug, and test, and virtual threads close the throughput gap significantly. Choose WebClient only when reactive is a deliberate architectural choice or you need true backpressure.

---

*Topics covered: RestTemplate · WebClient · RestClient · Feign · Java HttpClient · Blocking vs Non-blocking I/O · Netty EventLoop · Virtual Threads · Connection Pooling · Timeouts · HTTP/2 Multiplexing · mTLS · Resilience4j*
