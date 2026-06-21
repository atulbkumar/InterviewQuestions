# Spring Boot & Java — Interview Q&A

> Detailed answers calibrated for Senior / Staff level interviews at Financial Services GCCs

---

## Q1. What is the difference between `@ComponentScan` and AutoConfiguration in Spring Boot?

### Overview

These are two completely separate mechanisms in Spring Boot that work together but solve different problems. A common mistake is conflating them.

- **ComponentScan** is about discovering beans in your own codebase.
- **AutoConfiguration** is about loading opinionated default configuration from third-party starter JARs.

Understanding the distinction — and especially the internal mechanics of each — is what separates a senior answer from a Staff-level answer.

---

### 1. `@ComponentScan` — Deep Dive

#### What it does

`@ComponentScan` is a directive that tells the Spring container which packages to scan for classes annotated with stereotype annotations. Spring uses a `ClassPathScanningCandidateComponentProvider` to walk the classpath, identify candidate classes, and register them as `BeanDefinition`s in the `ApplicationContext`.

#### Stereotype annotations it detects

| Annotation | Purpose |
|---|---|
| `@Component` | Generic Spring-managed bean |
| `@Service` | Semantic alias for `@Component` in the service layer |
| `@Repository` | Alias with additional exception translation for DAO layer |
| `@Controller` / `@RestController` | Web layer beans |
| `@Configuration` | Beans that define other beans via `@Bean` methods |

All of the above are meta-annotated with `@Component`, which is why `ComponentScan` picks them up.

#### Default scanning behavior in Spring Boot

`@SpringBootApplication` is a composed annotation that includes `@ComponentScan`. By default it scans the package of the class annotated with `@SpringBootApplication` and all its sub-packages. This is why placing your main class at the root of your package structure is a convention — not just a style choice.

#### Explicit control

```java
@ComponentScan(basePackages = {"com.fidelity.trades", "com.fidelity.accounts"})
@ComponentScan(basePackageClasses = {TradeService.class, AccountService.class})
```

> Using `basePackageClasses` is refactor-safe — if you rename a package, the compiler catches it. String-based `basePackages` can silently break on package rename.

#### What ComponentScan does NOT do

- Does not load AutoConfiguration classes from starter JARs
- Does not apply conditional logic — if it finds the annotation, it registers the bean
- Does not scan JARs outside the specified base packages

---

### 2. AutoConfiguration — Deep Dive

#### The core problem it solves

Before AutoConfiguration, integrating any library (DataSource, Jackson, Kafka) required manually writing `@Configuration` classes and `@Bean` methods every time. AutoConfiguration provides pre-written `@Configuration` classes bundled inside starter JARs. Spring Boot activates them automatically based on what is on your classpath and what you have already defined.

#### The loading mechanism — how Spring Boot finds AutoConfiguration classes

AutoConfiguration classes are **not** on the component scan path. They are loaded through a completely separate mechanism:

| Spring Boot Version | Metadata File |
|---|---|
| 2.6 and earlier | `META-INF/spring.factories` — key: `org.springframework.boot.autoconfigure.EnableAutoConfiguration` |
| 2.7+ | `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` — one class per line |

Spring Boot reads these files at startup using `ImportCandidates.load()` and `SpringFactoriesLoader`. The classes listed are loaded regardless of whether they are in any scanned package.

#### Why AutoConfiguration classes are deliberately off the scan path

If AutoConfiguration classes were on the component scan path, they would always be loaded unconditionally, making `@Conditional` logic useless. By keeping them in a separate metadata file, Spring Boot evaluates conditions first and only instantiates what is needed. This is the design insight that makes Spring Boot's zero-config approach work.

#### The `@Conditional` mechanism — the heart of AutoConfiguration

Each AutoConfiguration class is annotated with one or more `@Conditional` annotations that guard its activation:

| Annotation | Behavior |
|---|---|
| `@ConditionalOnClass` | Activates only if a specific class is present on the classpath |
| `@ConditionalOnMissingBean` | Activates only if you have NOT already defined a bean of that type |
| `@ConditionalOnProperty` | Activates based on `application.properties` / `application.yml` values |
| `@ConditionalOnWebApplication` | Activates only in a web context |
| `@ConditionalOnMissingClass` | Activates only if a class is absent |

#### Concrete example — `DataSourceAutoConfiguration`

```java
@Configuration
@ConditionalOnClass({ DataSource.class, EmbeddedDatabaseType.class })
@ConditionalOnMissingBean(type = "io.r2dbc.spi.ConnectionFactory")
@EnableConfigurationProperties(DataSourceProperties.class)
public class DataSourceAutoConfiguration { ... }
```

This fires only if: a JDBC driver is on the classpath **AND** no R2DBC connection factory is defined **AND** you have not defined your own `DataSource` bean. If you define your own `DataSource @Bean`, `@ConditionalOnMissingBean` causes Spring Boot to back off — **your bean wins**.

#### Auto-configuration ordering

AutoConfiguration classes can declare ordering using `@AutoConfigureBefore`, `@AutoConfigureAfter`, and `@AutoConfigureOrder` to ensure dependencies between configurations are respected.

---

### 3. Comparison Table

| Dimension | `@ComponentScan` | AutoConfiguration |
|---|---|---|
| What it scans | Your application code | Starter / library JARs |
| Discovery mechanism | Classpath package scanning | `spring.factories` / `.imports` metadata file |
| Annotation required | `@Component` and stereotypes | `@Configuration` + `@Conditional*` |
| Who writes the beans | You | Spring Boot ecosystem |
| Conditional logic | None — finds annotation, registers bean | `@ConditionalOnClass`, `@ConditionalOnMissingBean`, etc. |
| Override mechanism | N/A — you own the code | `@ConditionalOnMissingBean` — your bean wins |
| When it runs | `ApplicationContext` refresh | Before ComponentScan, during AutoConfiguration phase |
| Can be disabled | Exclude packages | `@SpringBootApplication(exclude=DataSourceAutoConfiguration.class)` |

---

### Key Takeaway

> `ComponentScan` is a package-level directive. Spring walks the specified packages looking for classes annotated with `@Component` and its stereotypes, and registers them as `BeanDefinition`s. It is entirely about discovering beans in your own codebase.
>
> `AutoConfiguration` is a fundamentally different mechanism. Spring Boot reads a metadata file bundled inside each starter JAR — `spring.factories` in older versions, `AutoConfiguration.imports` in 2.7+ — to find pre-written `@Configuration` classes. These classes are annotated with `@Conditional` guards that evaluate whether to activate them based on what is on the classpath and what you have already defined.
>
> AutoConfiguration classes are deliberately kept off the component scan path so they only activate when conditions are met. The two complement each other: `ComponentScan` wires up your beans, AutoConfiguration provides ecosystem defaults — **and your beans always win via `@ConditionalOnMissingBean`**.

---

## Q2. What is backpressure in reactive programming and how does it apply to databases?

### Overview

Most engineers explain backpressure as *"doing things in parallel"* or *"calling multiple APIs concurrently."* That is **latency optimization**, not backpressure. Backpressure is specifically a **flow control protocol** where a downstream consumer signals to an upstream producer that it should slow down or pause data emission. The database context is where this distinction matters most.

---

### 1. The Problem — Traditional Blocking Database Access

#### What JDBC does

With a standard blocking JDBC call, the entire result set is loaded into JVM heap memory:

```java
List<Trade> trades = tradeRepository.findAll();  // 2 million rows pulled into heap
```

JDBC opens a cursor, fetches all rows from the database, materializes them as Java objects in memory, and only then returns control to your code. You have no mechanism to tell the database *"pause — I am still processing what you already sent."*

#### Consequences at scale

- Heap spike proportional to result set size — unpredictable under concurrent load
- Thread blocking — the thread is held for the entire duration of the DB round trip
- No back-channel to slow the DB — the database pushes as fast as it can
- Under concurrent load — `OutOfMemoryError`
- Thread pool exhaustion — each blocked thread reduces capacity for other requests

---

### 2. What Backpressure Actually Means

#### The formal definition

Backpressure is a **demand-driven flow control mechanism** defined in the **Reactive Streams specification** (later incorporated into `java.util.concurrent.Flow` in Java 9). A subscriber explicitly requests a specific number of items from the publisher via `Subscription.request(n)`. The publisher is not allowed to emit more items than requested. **The consumer controls the data flow rate, not the producer.**

#### The Reactive Streams protocol

```
Publisher  --(onNext x N)--> Subscriber
           <--request(N)--
           --(onNext x N)-->
           <--request(N)--
           --(onComplete)-->
```

The subscriber drives the pace. If processing is slow, it requests fewer items. If it is fast, it requests more. The publisher never emits unsolicited items.

#### Project Reactor implementation — `Flux` and `Mono`

In Project Reactor (used by Spring WebFlux):

| Type | Description |
|---|---|
| `Mono<T>` | Publisher of 0 or 1 item |
| `Flux<T>` | Publisher of 0 to N items, with full backpressure support |

Both are **cold publishers** by default — no data is produced until subscribed. Each subscription gets its own independent execution.

---

### 3. Backpressure in the Database Context — R2DBC

#### What R2DBC is

R2DBC (Reactive Relational Database Connectivity) is the non-blocking database driver specification with implementations for PostgreSQL, MySQL, MSSQL, Oracle, and H2. Unlike JDBC which returns results synchronously, R2DBC exposes results as a `Flux`, integrating natively with the Reactive Streams backpressure protocol.

#### How it changes the data flow

```java
// JDBC — blocking, all rows in memory
List<Trade> trades = tradeRepository.findAll();

// R2DBC — non-blocking, subscriber-driven fetch
Flux<Trade> trades = tradeRepository.findAll();  // nothing fetched yet
```

The `Flux` is a description of a computation. No database connection is opened, no query is executed, no data is fetched until a subscriber attaches and calls `request(n)`.

#### Controlling fetch rate with operators

```java
tradeRepository.findAll()
    .buffer(500)                               // request 500 rows at a time
    .flatMap(batch -> processBatch(batch), 4)  // process 4 batches in parallel
    .onBackpressureBuffer(1000)                // buffer up to 1000 if processing lags
    .subscribe(
        result -> log.info("Processed: {}", result),
        error  -> log.error("Error: {}", error),
        ()     -> log.info("Completed")
    );
```

#### The end-to-end backpressure chain

```
Database
   |  R2DBC driver fetches rows in demand-driven chunks
   v
Flux<Row>  <-- demand signals flow upstream from here
   |
   v  map / filter / flatMap operators
   |
   v
Downstream (HTTP SSE / Kafka producer / WebSocket)
   |
   ^-- slow client → signal propagates all the way back to DB fetch rate
```

A slow browser client reading an SSE stream causes the WebFlux layer to slow down, which causes R2DBC to fetch fewer rows from the database. **No component in the chain is overwhelmed. Memory consumption stays bounded and predictable.**

---

### 4. Backpressure Strategies in Reactor

When a producer emits faster than a consumer can process:

| Strategy | Behavior | Risk / Use Case |
|---|---|---|
| `BUFFER` | Buffer items in memory until consumer catches up | Unbounded memory growth if consistently slow |
| `DROP` | Discard items when downstream cannot keep up | Acceptable for non-critical metrics / telemetry |
| `LATEST` | Keep only the most recent item, drop older ones | Real-time price feeds where stale data has no value |
| `ERROR` | Signal error when buffer is exhausted | Fail-fast approach to force the issue upstream |

---

### 5. JDBC vs R2DBC — Honest Comparison

| Dimension | JDBC (Blocking) | R2DBC (Reactive) |
|---|---|---|
| Thread model | 1 thread blocked per DB connection | Non-blocking, event-loop based |
| Data loading | All rows fetched eagerly into heap | Fetched on demand, subscriber-driven |
| Backpressure | None — no demand signalling to DB | Built into `Flux` / Reactive Streams protocol |
| Memory usage | Heap spike proportional to result set | Bounded — constant regardless of result set size |
| Concurrency | Thread pool exhaustion risk at scale | Handles many concurrent queries cheaply |
| Ecosystem maturity | Very mature, all DBs supported | Catching up — fewer drivers, less tooling |
| Spring Data support | Spring Data JPA / JDBC | Spring Data R2DBC |
| When to prefer | CRUD-heavy apps, simple queries | High-volume streaming, event-driven pipelines |

---

### 6. Financial Services Relevance

- **Trade history queries:** Result sets of millions of rows can be streamed reactively without heap spikes, processed and forwarded to downstream systems
- **Risk aggregation pipelines:** Reading positions across all accounts reactively, backpressuring if aggregation is slower than the DB read
- **Audit log streaming:** Continuous DB reads fed into Kafka — backpressure prevents the Kafka producer from being overwhelmed if the broker is slow
- **Real-time P&L:** DB reads feeding a WebFlux SSE stream — if the browser client is slow, backpressure propagates all the way back to the database fetch rate

---

### Key Takeaway

> Backpressure is a demand-driven flow control signal defined in the Reactive Streams specification. It allows a downstream consumer to tell an upstream producer how many items it is ready to receive, preventing the producer from overwhelming the consumer. This is distinct from parallelism — parallel API calls reduce latency, backpressure ensures stability under load.
>
> With JDBC, there is no backpressure mechanism. `findAll()` pulls the entire result set into heap memory. With R2DBC, the repository returns a `Flux` — a cold publisher — nothing is fetched until someone subscribes. The subscriber drives fetch rate through demand signals, so the database only produces what downstream processing can consume. Memory consumption stays bounded and predictable regardless of result set size.
>
> The backpressure signal is **end-to-end** — a slow HTTP client slows the WebFlux layer, which slows R2DBC, which slows the database. No component in the chain is overwhelmed. This is critical for high-volume financial data pipelines where result set sizes are unpredictable.

---

## Q3. What is OpenTelemetry and how does a trace flow from the UI through the API layer to the database?

### Overview

OpenTelemetry (OTEL) is a vendor-neutral, CNCF-graduated observability framework that standardizes how distributed systems collect, process, and export telemetry data. The key skills to demonstrate: the internal propagation mechanism, the collector architecture, sampling strategies, and how the DB layer specifically benefits from trace-level isolation of query latency.

---

### 1. The Three Pillars of Observability

| Signal | What it answers | OTEL component |
|---|---|---|
| Traces | What path did this request take, and how long did each hop take? | SDK + Exporter + Collector |
| Metrics | How is the system behaving in aggregate right now? | `MeterProvider` + OTLP |
| Logs | What happened at a specific point in time? | `LoggerProvider` (still maturing) |

**Key value proposition:** You instrument once using the OTEL SDK and export to any backend — Datadog, Splunk, Jaeger, Grafana Tempo, Honeycomb — by changing only the exporter configuration. No code change required. This eliminates vendor lock-in at the instrumentation layer.

---

### 2. Core Concepts

#### Trace

A trace is the complete record of a single request's journey across all services and infrastructure, represented as a tree of spans. Each trace has a globally unique `traceId` (16-byte / 128-bit hex string) shared across every span, regardless of which service generated it.

#### Span

A span is a single unit of work within a trace. Each span carries:

| Field | Description |
|---|---|
| `traceId` | Shared with all other spans in the same trace |
| `spanId` | Unique identifier for this specific span (8 bytes) |
| `parentSpanId` | The `spanId` of the caller — used to build the tree structure |
| `name` | e.g., `GET /api/trades` or `SELECT trades` |
| `startTime` / `endTime` | Nanosecond precision timestamps |
| `status` | `OK`, `ERROR`, or `UNSET` |
| `attributes` | Key-value pairs: HTTP method, DB query, user ID |
| `events` | Timestamped annotations within a span (e.g., `cache miss`, `retry attempt 2`) |
| `links` | References to related spans across traces |

#### TraceContext and W3C Propagation

Trace identity travels across process boundaries via HTTP headers defined in the **W3C Trace Context** specification:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

Format: `version` - `traceId (32 hex)` - `parentSpanId (16 hex)` - `flags (01 = sampled)`

```
tracestate: vendor1=value1,vendor2=value2
```

`tracestate` carries vendor-specific data alongside the standard `traceparent`. The receiving service reads `traceparent`, extracts the `traceId` and parent `spanId`, creates its own child span, and injects updated headers into any outbound calls it makes.

#### Context Propagation

Propagation is the mechanism of injecting trace context into outbound requests and extracting it from inbound ones. OTEL provides propagators for:

- HTTP headers — W3C `traceparent` / `tracestate` (default), B3 (Zipkin legacy)
- Kafka message headers — trace context travels with the message
- gRPC metadata — binary propagation
- RabbitMQ / ActiveMQ message properties

---

### 3. The End-to-End Trace Flow

```
Browser / Mobile App
   |  HTTP Request (no traceparent, or OTEL JS SDK generates one)
   v
API Gateway / Load Balancer           [Span A — root span]
   |  Injects traceparent into forwarded request
   v
Spring Boot Microservice              [Span B — child of A]
   |
   |--- WebClient → External API      [Span C — child of B]
   |    traceparent injected into outbound HTTP headers
   |
   |--- R2DBC / JDBC DB query         [Span D — child of B]
   |    db.statement, db.system, net.peer.name captured
   |
   |--- Redis cache lookup            [Span E — child of B]
   v
All spans share the same traceId, linked by parentSpanId chain
```

#### What the waterfall view shows

In Datadog or Jaeger, the waterfall view reconstructs this tree. You can see:

- Total request duration (Span B)
- External API call duration isolated (Span C)
- DB query duration isolated from network and application time (Span D)
- Whether the DB query ran sequentially or in parallel with the API call
- Exactly which SQL was executed and how long it took

---

### 4. Spring Boot Instrumentation

#### Auto-instrumentation via Micrometer Tracing

Spring Boot 3.x includes Micrometer Tracing as the abstraction layer, with an OTEL bridge. Add these dependencies and most instrumentation is automatic:

```xml
<!-- Micrometer OTEL bridge -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>
<!-- OTLP exporter to send to Collector -->
<dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-exporter-otlp</artifactId>
</dependency>
```

**What gets auto-instrumented without any code changes:**

- Incoming HTTP requests — root span created, `traceparent` header extracted
- Outbound `RestTemplate` / `WebClient` calls — child span created, `traceparent` injected
- JDBC queries via `spring-jdbc` — SQL text, DB name, operation type captured
- R2DBC queries — same as JDBC but non-blocking
- Spring Kafka — trace context injected into / extracted from Kafka message headers
- `@Scheduled` methods — span created per execution
- `@Async` methods — span context propagated across thread boundaries

#### Manual instrumentation for business context

```java
@Autowired
Tracer tracer;

public TradeResult executeTrade(TradeRequest request) {
    Span span = tracer.nextSpan()
        .name("execute-trade")
        .tag("trade.symbol", request.getSymbol())
        .tag("trade.quantity", String.valueOf(request.getQuantity()))
        .tag("trade.account", request.getAccountId())
        .start();

    try (Tracer.SpanInScope ws = tracer.withSpan(span)) {
        return tradeService.process(request);
    } catch (Exception e) {
        span.error(e);
        throw e;
    } finally {
        span.end();
    }
}
```

Auto-instrumentation captures infrastructure-level context. Manual instrumentation adds **business-level context** — trade symbols, account IDs, risk flags — that is not visible at the infrastructure level.

#### Context propagation in reactive pipelines

In WebFlux / Project Reactor, Spring's `ThreadLocal`-based context does not work because operations execute across different threads. Spring Boot 3 uses Reactor Context for propagation:

```java
// Context propagates automatically in WebFlux with Spring Boot 3
return tradeRepository.findAll()
    .flatMap(trade -> riskService.evaluate(trade))  // traceId flows here automatically
    .collectList();
```

Under the hood, Micrometer Tracing uses Reactor's `contextWrite` / `contextCapture` to propagate the active span across reactive operator boundaries.

---

### 5. The Database Layer in Detail

#### What OTEL captures for DB spans

DB spans automatically capture semantic attributes defined in the OTEL semantic conventions:

| Attribute | Example Value |
|---|---|
| `db.system` | `postgresql` / `mysql` / `oracle` / `h2` |
| `db.name` | Name of the database |
| `db.statement` | SQL query (bind parameter names, not actual values — for security) |
| `db.operation` | `SELECT` / `INSERT` / `UPDATE` / `DELETE` |
| `net.peer.name` | Hostname of the DB server |
| `net.peer.port` | Port number |
| `db.connection_string` | Sanitized connection URL |

#### Why DB span isolation is valuable

Without tracing, a slow API endpoint could be slow because of: slow SQL, slow network to the DB, slow Java object mapping, slow downstream service, or slow business logic. These are indistinguishable from the outside. With tracing, each is a **separate span with a separate duration**. You can immediately see: *"DB span took 2ms, but the parent span took 800ms — the problem is in the Java processing layer, not the SQL."*

#### N+1 query detection via traces

If a single trace shows 500 DB spans for one HTTP request, that is a classic N+1 query problem made **immediately visible**. Without tracing, N+1 problems are discovered only when they cause production incidents.

---

### 6. The OTEL Collector Architecture

#### Why not export directly to Datadog

Exporting spans directly from your application to Datadog or Splunk creates several problems:

- Vendor coupling in application code — changing observability backend requires code changes
- Network latency on the hot path — exporting spans synchronously adds request latency
- No PII scrubbing layer — sensitive data in span attributes goes directly to the vendor
- No batching control — individual span exports at high RPS are expensive

#### Collector as the central processing layer

```
Spring Boot App                Spring Boot App
      |                               |
      |  OTLP gRPC (port 4317)        |  OTLP HTTP (port 4318)
      v                               v
                 OTEL Collector
          (sidecar per pod in Kubernetes)
                      |
         _____________|_____________
        |             |             |
   Datadog       Splunk HEC     Jaeger
   Exporter       Exporter      Exporter
  (production)  (compliance)   (local dev)
```

#### What the Collector does

- **Receives** — accepts OTLP gRPC and HTTP, Jaeger, Zipkin, Prometheus formats
- **Processes** — batches spans, retries on failure, filters noise, scrubs PII from attributes
- **Exports** — fans out to multiple backends simultaneously with different sampling rates
- **Resource detection** — automatically adds Kubernetes pod name, namespace, node, and cloud region to every span

---

### 7. Sampling — The Part Most Candidates Miss

#### Why sampling is necessary

A high-traffic system may process 10,000 requests per second. Sending traces for every request means 10,000 trace exports per second — expensive in both network bandwidth and observability backend cost. Sampling reduces this to a manageable volume while ensuring you still capture the traces that matter.

#### Head-based sampling

The sampling decision is made at the **start of the trace** when the root span is created. A percentage (e.g., 1%) of traces are selected for export.

**Critical flaw:** The 1% might exclude the one trace that contained the critical error you are trying to debug.

#### Tail-based sampling — the production approach

The OTEL Collector buffers the **complete trace** and makes the sampling decision only **after the trace is finished**. This allows rules based on the actual outcome:

- Always keep traces where any span has `status ERROR`
- Always keep traces where total duration exceeds 2 seconds
- Always keep traces involving a specific customer account (for compliance)
- Sample 0.1% of successful sub-100ms traces (healthy, less interesting)

This means you capture **100% of failure and anomalous traces** while aggressively sampling out normal successful traffic. For a financial services system processing trade orders, this is essential — every failed trade execution must be reconstructable.

#### Probabilistic vs rule-based sampling

| Strategy | Behavior |
|---|---|
| Probabilistic | Keep X% of all traces uniformly — simple but blind to outcomes |
| Rate-limiting | Keep at most N traces per second — protects cost regardless of traffic spikes |
| Rule-based (tail) | Keep based on attributes — error status, latency threshold, user tier |

---

### 8. Distributed Context in Kafka-based Architectures

In event-driven architectures, the trace context must travel with the Kafka message. Spring Kafka with OTEL auto-instrumentation handles this automatically:

- **Producer side:** Trace context injected as Kafka message headers (`traceparent`, `tracestate`)
- **Consumer side:** Trace context extracted from headers and used as the parent span for consumer processing
- **Result:** The full trace shows: HTTP request → Kafka produce → Kafka consume → downstream processing

Without this, Kafka creates an **invisible boundary** in your traces — you can see producer and consumer traces separately but cannot connect them. With OTEL propagation across Kafka, the entire async flow is visible in a single trace.

---

### Key Takeaway

> OpenTelemetry is a CNCF-graduated, vendor-neutral observability framework that standardizes collection of traces, metrics, and logs. Vendor-neutral means you instrument once and route to any backend by changing exporter configuration, not application code.
>
> A trace is the complete journey of one request across all systems, represented as a tree of spans. Each span is one unit of work with its own timing, status, and attributes. The trace identity travels across service boundaries via W3C `traceparent` headers. Spring Boot 3 auto-instruments incoming HTTP requests, `WebClient` outbound calls, JDBC/R2DBC DB queries, and Kafka producers/consumers — all without code changes.
>
> The DB layer is particularly valuable because it isolates query latency from network latency from application processing time within the same trace. Without this, a slow endpoint could be slow for any of five different reasons. With tracing, each reason is a separate span with a separate duration. N+1 query problems also become immediately visible — 500 DB spans in a single trace is the signature.
>
> In production, spans are exported to an OTEL Collector — not directly to the observability vendor. The Collector handles batching, retry, PII scrubbing, and fan-out to multiple backends simultaneously. **Tail-based sampling** in the Collector ensures you capture 100% of error traces and slow traces while aggressively sampling normal traffic — critical for financial systems where every failed trade execution must be reconstructable.

---

*End of Interview Preparation Document*
