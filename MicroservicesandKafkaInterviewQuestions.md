# Microservices & Kafka — Senior Interview Guide
### 10 Questions · Calibrated for 16 Years Experience

---

## Table of Contents

1. [Database-per-Service Pattern and Tradeoffs](#q1)
2. [API Gateway vs Service Discovery vs Service Mesh](#q2)
3. [API Gateway Only vs Introducing a Service Mesh](#q3)
4. [Service Discovery in Cloud-Native Architecture](#q4)
5. [Kafka Handling Overwhelmed Consumers](#q5)
6. [Consumer Lag — Definition and Troubleshooting](#q6)
7. [Strategies to Improve Kafka Consumer Throughput](#q7)
8. [Optimizing Kafka Brokers for Performance and Scalability](#q8)
9. [Kafka Message Ordering and Its Limitations](#q9)
10. [Impact of Partitions, Replication, Batching, and Acknowledgements](#q10)

---

<a name="q1"></a>
## Q1. Explain the database-per-service pattern and its tradeoffs

### TL;DR
Each microservice owns exactly one database, accessed only through that service's API. No cross-DB joins. Coordination happens via events or APIs.

### Why interviewers ask this at senior level
At senior level, interviewers want you to go beyond the definition — they want real production pain: saga patterns, eventual consistency costs, and when you would actually break this rule.

### Full Answer

**The pattern:** Every service owns its schema and rejects direct DB access from other services. An Order Service cannot SELECT from the Customer DB — it calls the Customer Service API or listens to `CustomerCreated` events.

**Why it matters:** It enforces the bounded context principle. Without it, teams end up with a "distributed monolith" — microservice topology with monolith coupling. Schema changes in one service silently break three others.

**The real tradeoffs at scale:**

*Data consistency:* You lose ACID across services. A payment that deducts inventory must use a Saga (orchestration or choreography). Rollback means compensating transactions — complex to implement and test.

*Cross-service queries:* There is no JOIN across service boundaries. You either use API Composition (aggregate at the gateway/BFF) or maintain denormalized read models via CQRS. Both add complexity.

*Operational overhead:* 30 services = 30 database instances to monitor, patch, back up, and size. Polyglot persistence (Postgres here, Cassandra there) multiplies the skill requirement across your SRE team.

*When to pragmatically violate this:* A shared read-only reference DB (e.g., currency codes, country list) shared by all services is a reasonable pragmatic exception. The rule is about write ownership, not read isolation.

### Key Concepts to Mention
`Bounded context` · `Saga pattern` · `CQRS` · `Eventual consistency` · `Polyglot persistence` · `API Composition` · `Compensating transactions`

### Common Pitfall at This Experience Level
> ⚠️ Do not just list benefits. Interviewers at senior level expect you to articulate the saga/distributed transaction problem with clarity. Mention compensating transactions explicitly.

### Production Example
E-commerce: Order Service (Postgres) → emits `OrderPlaced` event → Inventory Service (Redis) decrements stock → Payment Service (Postgres) charges card. Each step must compensate on failure.

---

<a name="q2"></a>
## Q2. Compare API Gateway, Service Discovery, and Service Mesh — when to use each

### TL;DR
API Gateway = external front door. Service Discovery = internal address book. Service Mesh = cross-cutting infrastructure for internal traffic.

### Why interviewers ask this at senior level
Senior engineers are expected to reason about architectural layers, not just describe tools. Interviewers probe whether you understand that these three solve different problems at different layers.

### Full Answer

**API Gateway** sits at the perimeter. It handles concerns external clients care about: routing, auth/authz, SSL termination, rate limiting, request aggregation. It does NOT know about service-to-service health or retries inside your cluster. Examples: Kong, Spring Cloud Gateway, AWS API Gateway.

**Service Discovery** answers the question "where is service X right now?" Services register themselves on startup with metadata (host, port, health). Callers query the registry and load-balance across live instances. Kubernetes handles this natively via CoreDNS — `http://order-service` resolves to healthy pods automatically. Explicit registries like Consul or Eureka are more relevant in non-Kubernetes environments.

**Service Mesh** is a dedicated infrastructure layer for east-west (service-to-service) traffic. Each service gets a sidecar proxy (Envoy in Istio/Linkerd). The mesh handles mTLS, retries, circuit breaking, traffic splitting, and distributed tracing — transparently, without code changes. It's powerful but operationally heavy.

**They are complementary, not alternatives.** A production system typically uses all three: API Gateway at the edge, Kubernetes DNS for discovery, and optionally a service mesh for zero-trust security or canary deployments.

| Component | Traffic Direction | Problems Solved | Examples |
|---|---|---|---|
| API Gateway | North-South (client→service) | Auth, rate limiting, routing, SSL | Kong, AWS API Gateway, Spring Cloud Gateway |
| Service Discovery | East-West (service→service) | Dynamic IPs, scaling, failover | CoreDNS, Eureka, Consul |
| Service Mesh | East-West (service→service) | mTLS, retries, tracing, traffic shaping | Istio, Linkerd, Consul Connect |

### Key Concepts to Mention
`Kong` · `Istio` · `Consul` · `Envoy sidecar` · `mTLS` · `CoreDNS` · `North-south vs east-west traffic`

### Common Pitfall at This Experience Level
> ⚠️ Never conflate API Gateway with Service Mesh. They operate at different layers. An API Gateway handles north-south traffic (client→service); a service mesh handles east-west traffic (service→service).

### Production Example
Client → API Gateway (JWT validation, rate limit) → Order Service. Order Service → [Kubernetes DNS lookup] → Inventory Service. That traffic passes through Istio sidecar proxies → mTLS enforced automatically.

---

<a name="q3"></a>
## Q3. When do you choose only an API Gateway vs. introducing a Service Mesh?

### TL;DR
Start with API Gateway only. Introduce a service mesh when you have 20+ services, need zero-trust mTLS, or require canary/traffic-splitting automation.

### Why interviewers ask this at senior level
This is a design judgment question. Interviewers want to see that you can reason about cost vs. complexity vs. operational maturity — not just pattern name-drop.

### Full Answer

**API Gateway only is the right call when:**
- Fewer than ~20 services
- Simple inter-service communication (no retries, no circuit breakers needed beyond Resilience4j)
- Team has limited Kubernetes/infra expertise
- Compliance requirements do not mandate mTLS between internal services
- A startup shipping an MVP with 5 services has no business running Istio

**Introduce a Service Mesh when:**
- Grown to 50+ services and manually adding Resilience4j, logging, tracing, and retry config to every service creates inconsistency
- Zero-trust networking is required (PCI DSS, HIPAA contexts)
- Canary deployments or traffic splitting (send 5% to v2) are needed without code changes
- A uniform observability layer is needed — consistent distributed tracing and metrics across all services regardless of language/framework

**The hidden cost of a Service Mesh:**
Every pod gets a sidecar (Envoy). In a cluster with 200 pods, that is 200 additional proxy processes. Memory footprint increases ~50–100MB per pod. Control plane (Istiod) adds complexity. Debugging service mesh issues requires a separate skill set. Misconfigurations in mTLS policies can silently break connectivity.

**The pragmatic path:** Start with API Gateway + circuit breakers in code (Resilience4j). Add a service mesh only when you have a dedicated platform/SRE team who will own it.

### Key Concepts to Mention
`Resilience4j` · `Zero-trust networking` · `Canary deployment` · `Envoy sidecar overhead` · `Platform/SRE team ownership` · `Operational maturity`

### Common Pitfall at This Experience Level
> ⚠️ Do not recommend a service mesh for small architectures just because you know about them. Demonstrate architectural judgment — more technology is not always better.

### Production Example
A fintech platform at 100+ services with PCI-DSS compliance: service mesh (Istio) is justified for mTLS. An internal tool team with 8 services: API Gateway + Resilience4j annotations is sufficient and far simpler.

---

<a name="q4"></a>
## Q4. How does service discovery work in a cloud-native microservices architecture?

### TL;DR
Services register their location on startup; callers look up live instances at runtime rather than using hardcoded IPs. Kubernetes makes this invisible via CoreDNS.

### Why interviewers ask this at senior level
Interviewers want to hear you explain client-side vs server-side discovery, and why Kubernetes eliminates most of the problem you solved with Eureka in the Spring Cloud era.

### Full Answer

**The problem:** In a dynamic cluster, service instances get new IPs on every deployment, crash, or scale event. Hard-coding IPs breaks immediately. Service discovery solves this by maintaining a live registry of where each service is.

**Registration:** When a service starts, it registers itself — either self-registration (the service calls Consul/Eureka) or third-party registration (the orchestrator registers it, as Kubernetes does). The entry includes IP, port, and health endpoint. A heartbeat/TTL mechanism removes dead entries.

**Client-side discovery (Eureka model):** The calling service queries the registry, gets a list of live instances, and load-balances itself (e.g., Ribbon, Spring Cloud LoadBalancer). More control, but the client library must know how to talk to the registry.

**Server-side discovery (Kubernetes model):** The client calls a stable DNS name (`order-service`). Kubernetes DNS (CoreDNS) resolves it to a ClusterIP. `kube-proxy` routes to healthy pods via iptables/IPVS. The service does not know discovery is happening — it just makes an HTTP call to a name.

**In practice today:** If you are on Kubernetes, CoreDNS + Services handles discovery transparently. Consul or Eureka are only relevant in hybrid environments (VMs + containers) or legacy Spring Cloud architectures. Kubernetes health checks (`readinessProbe`) ensure only healthy pods receive traffic.

| Type | Who Resolves | Examples | When to Use |
|---|---|---|---|
| Client-side | The calling service | Eureka + Ribbon, Consul | Legacy Spring Cloud, non-K8s |
| Server-side | Load balancer / DNS | Kubernetes CoreDNS, AWS ELB | Kubernetes-native (standard today) |

### Key Concepts to Mention
`CoreDNS` · `Eureka` · `Consul` · `kube-proxy` · `readinessProbe` · `ClusterIP` · `Client-side vs server-side discovery`

### Common Pitfall at This Experience Level
> ⚠️ Do not describe only the Eureka/Ribbon model from Spring Cloud days. In 2025 interviews, Kubernetes-native discovery is the expected baseline. Mention CoreDNS and readinessProbe.

### Production Example
Order Service calls `http://inventory-service/api/stock`. Kubernetes DNS resolves `inventory-service` to its ClusterIP. kube-proxy forwards to one of 3 healthy Inventory pods. If a pod fails its `readinessProbe`, kube-proxy removes it from rotation within seconds.

---

<a name="q5"></a>
## Q5. How does Kafka handle consumers overwhelmed by events — unable to keep up with producers?

### TL;DR
Kafka is a pull-based, durable log. Producers never block waiting for consumers. Consumers read at their own pace using offsets. Lag is visible and manageable.

### Why interviewers ask this at senior level
This tests whether you understand Kafka's pull model vs. push-based messaging. It's a common pitfall where candidates confuse Kafka's backpressure semantics with RabbitMQ's push model.

### Full Answer

**Kafka's fundamental design:** Producers write to a durable, append-only log on the broker. Consumers pull records using stored offsets. Producers and consumers are completely decoupled — a slow consumer does not slow down or block the producer in any way.

**What happens when consumers fall behind:** Consumer lag increases. The consumer offset pointer simply moves more slowly than the latest offset. Records remain stored on the broker per the retention policy (time-based or size-based). This is deliberate — Kafka is designed to absorb production spikes and let consumers catch up when capacity is available.

**The real risk:** Retention is finite. If lag grows so large that the unconsumed messages age out under the retention policy (e.g., 7-day default), those messages are deleted before the consumer reads them. From the consumer's perspective, this is data loss — the offset jumps forward past deleted segments.

**Mitigation strategies:**
- Increase retention time or size for critical topics
- Add more consumer instances (up to partition count)
- Increase `max.poll.records` and process in batches
- Use consumer `pause()`/`resume()` to self-throttle
- Route repeatedly failing messages to a Dead Letter Queue (DLQ)
- Monitor consumer lag via `kafka-consumer-groups.sh` or tools like Burrow, Confluent Control Center

### Key Concepts to Mention
`Pull model` · `Consumer offset` · `Retention policy` · `Consumer lag` · `Dead Letter Queue` · `kafka-consumer-groups.sh` · `Burrow`

### Common Pitfall at This Experience Level
> ⚠️ A common mistake: saying "Kafka pushes messages to consumers." It does not. Consumers poll. This distinction matters — it is the reason Kafka has no built-in flow control and why retention is the real backpressure mechanism.

### Production Example
Black Friday: 10,000 order events/sec produced. Consumers process 6,000/sec. Lag grows to ~500K messages. As long as lag resolves within the retention window (7 days), no data loss occurs. Traffic spike ends; consumers drain lag within hours. No producer impact throughout.

---

<a name="q6"></a>
## Q6. What is consumer lag in Kafka and how would you troubleshoot it?

### TL;DR
Consumer lag = latest offset − consumer committed offset for each partition. Troubleshoot by layering: measure → consumer metrics → broker metrics → partition count → rebalance activity.

### Why interviewers ask this at senior level
This is a practical ops question. At 16 years experience, you should be able to walk through a systematic RCA process, not just list monitoring commands.

### Full Answer

**Definition:** Lag is calculated per partition: `(Log End Offset) − (Consumer Committed Offset)`. Total group lag = sum across all partitions. A healthy system has lag close to zero. Persistent or growing lag signals consumers cannot keep up.

**Systematic troubleshooting approach:**

**Step 1 — Confirm and quantify:**
Run `kafka-consumer-groups.sh --describe --group <name>` to see per-partition lag. Use Prometheus + Grafana or Confluent Control Center for historical trending. Determine whether lag is growing, stable-high, or spiky.

**Step 2 — Consumer-side diagnosis:**
Check processing time per record. If the consumer is spending 200ms per message on a downstream DB call, this is your bottleneck. Check poll interval — if processing time exceeds `max.poll.interval.ms`, the consumer is kicked out of the group, triggering a rebalance that makes things worse.

**Step 3 — Rebalance storms:**
Frequent rebalances are a common hidden cause. Check consumer logs for "Rebalancing..." events. Causes: long GC pauses, slow processing exceeding poll interval, rolling deployments without cooperative rebalancing configured. Enable `partition.assignment.strategy=CooperativeStickyAssignor` to minimize rebalance disruption.

**Step 4 — Broker-side diagnosis:**
Check if brokers are under CPU/disk pressure. Under-replicated partitions indicate broker stress. Network saturation can throttle consumer fetch rate.

**Step 5 — Partition count:**
Consumer group throughput is bounded by partition count. If you have 3 partitions and 10 consumers, 7 consumers are idle. Add partitions (with care — it cannot be undone easily) or verify consumer count ≤ partition count.

### Key Metrics to Monitor
| Metric | Alarm Threshold |
|---|---|
| `records-lag-max` | > sustained threshold (topic-specific) |
| `fetch-rate` | Dropping unexpectedly |
| `rebalance-rate` | Non-zero over time |
| Under-replicated partitions | Any non-zero value |
| Consumer processing time | Approaching `max.poll.interval.ms` |

### Key Concepts to Mention
`kafka-consumer-groups.sh` · `max.poll.interval.ms` · `Rebalance storms` · `Burrow` · `Under-replicated partitions` · `CooperativeStickyAssignor`

### Common Pitfall at This Experience Level
> ⚠️ Interviewers love the rebalance storm scenario — it is a non-obvious but common root cause. Mentioning `max.poll.interval.ms` and cooperative rebalancing signals real production experience.

### Production Example
Alert fires: consumer lag at 2M. Investigation: processing time spiked from 20ms to 800ms per message (downstream DB started timing out). This caused `max.poll.interval.ms` breaches → rebalances → partial paralysis. Fix: circuit-break the DB call, route failures to DLQ, resolve DB issue, resume normal consumption.

---

<a name="q7"></a>
## Q7. What strategies improve Kafka consumer throughput and handle backpressure?

### TL;DR
Parallelism (partitions + consumers), poll tuning (`max.poll.records`, `fetch.min.bytes`), batch processing, async workers, and consumer `pause()`/`resume()` for self-throttling.

### Why interviewers ask this at senior level
This tests depth of Kafka consumer tuning knowledge. Senior engineers are expected to name specific config parameters, not just say "add more consumers."

### Full Answer

**Increase parallelism first:**
Partition count is the ceiling on consumer parallelism. If you have 6 partitions, maximum useful consumers per group = 6. Scale out by increasing partitions (plan ahead — safe limit ~100 per broker for metadata overhead) and adding consumer instances.

**Tune poll configuration:**
- `max.poll.records` (default 500): controls how many records are returned per poll. Increasing it means fewer round trips but more memory per batch.
- `fetch.min.bytes`: the broker waits to send a fuller batch, improving throughput at the cost of latency.
- `fetch.max.wait.ms`: maximum wait time for `fetch.min.bytes` to be satisfied.

**Batch processing:**
Process the entire poll batch together rather than one record at a time. If each record triggers a DB write, batching into a single JDBC batch insert reduces DB round trips by 100x. Commit offset once per batch, not per record.

**Asynchronous processing with a worker pool:**
Poll on one thread, dispatch to a thread pool for processing, commit only after all workers complete. Careful: you must track per-partition watermarks to avoid committing offsets for records still in flight.

**Consumer pause/resume:**
If a downstream system (DB, API) signals it is overloaded, call `consumer.pause(partitions)` to stop fetching temporarily, process the in-flight batch, then call `consumer.resume(partitions)`. This prevents unbounded in-memory buffering.

**Dead Letter Queue (DLQ):**
Records that repeatedly fail (poison pills) should be routed to a DLQ topic rather than blocking the entire partition. One bad message can halt an entire partition indefinitely without a DLQ.

### Key Concepts to Mention
`max.poll.records` · `fetch.min.bytes` · `Consumer pause/resume` · `Batch commits` · `DLQ pattern` · `Worker pool` · `Poison pill`

### Common Pitfall at This Experience Level
> ⚠️ Do not forget the DLQ pattern. Interviewers with Kafka production experience will probe whether you have encountered poison-pill messages. It is a critical reliability pattern often omitted by candidates.

### Production Example
Payment event consumer: poll 500 records, dispatch to 20-thread pool for parallel DB writes, commit offset after pool drains. Throughput improved from 800/sec to 12,000/sec. DLQ introduced for malformed events that failed 3x retries — prevents one bad message from blocking the partition.

---

<a name="q8"></a>
## Q8. How do you optimize Kafka brokers for performance and scalability?

### TL;DR
Storage (SSDs, dedicated disks), partition count tuning, compression, network buffers, producer batching at source, horizontal scaling, and proactive monitoring of under-replicated partitions and request handler idle ratios.

### Why interviewers ask this at senior level
Senior engineers are expected to reason about Kafka as infrastructure — not just application code. Broker tuning shows infra depth and real production ownership.

### Full Answer

**Storage is the bottleneck most often:**
Kafka is I/O bound. Use SSDs — throughput improvements over spinning disks can be 5–10x. Critically, separate the Kafka log directory from the OS disk. OS page cache is central to Kafka's performance (it caches segment files). Competing I/O from the OS degrades throughput significantly. Ensure `log.dirs` points to dedicated disks.

**Partition count and leader distribution:**
More partitions = more parallelism, but each partition has a leader broker. Broker CPU scales with leader count (replication, fetch handling). A practical rule: keep total partitions per broker under ~4,000 for stable metadata management. Distribute leaders evenly with `kafka-leader-election.sh` or `auto.leader.rebalance.enable=true`.

**Producer-side compression:**
Enable compression at the producer — `lz4` for speed, `zstd` for ratio. Compression happens at the producer, rides compressed through the broker (no decompress/recompress), and decompresses at the consumer. This reduces network and disk usage simultaneously. `compression.type=lz4` is a safe default for most workloads.

**Broker thread tuning:**
- `num.network.threads` (default 3): handles network I/O — increase for high-throughput clusters
- `num.io.threads` (default 8): handles disk I/O — increase for high-partition-count clusters
- `socket.send.buffer.bytes` / `socket.receive.buffer.bytes`: should match OS TCP buffer settings

**Scaling out:**
Add brokers and use `kafka-reassign-partitions.sh` to redistribute partitions. This is the primary scaling mechanism — Kafka scales horizontally well. After adding brokers, new partitions will NOT automatically rebalance to new brokers; you must run a reassignment plan.

**What to monitor proactively:**

| Metric | Alarm Condition |
|---|---|
| Under-replicated partitions | Any non-zero value |
| Request handler idle ratio | Below 20% = saturated |
| Network processor avg idle | Below 30% = saturated |
| Disk utilization | Above 70% = plan expansion |
| Controller election rate | Non-zero outside maintenance = instability |

### Key Concepts to Mention
`SSD + dedicated disk` · `lz4/zstd compression` · `num.io.threads` · `Partition reassignment` · `Under-replicated partitions` · `Page cache` · `kafka-reassign-partitions.sh`

### Common Pitfall at This Experience Level
> ⚠️ The page cache point is subtle but signals deep knowledge. Kafka's performance model is built on OS page cache — any I/O competition on the same disk destroys this assumption. Many candidates miss this.

### Production Example
A 10-broker cluster running at 70% disk utilization. Actions taken: moved `log.dirs` to dedicated NVMe SSDs (2x throughput), enabled `lz4` compression (reduced disk write by 40%), increased `num.io.threads` from 8 to 16, ran partition reassignment to balance leaders. Result: p99 produce latency dropped from 120ms to 18ms.

---

<a name="q9"></a>
## Q9. How does Kafka maintain message ordering and what are the limitations?

### TL;DR
Ordering is guaranteed strictly within a partition, never across partitions. Use a stable partition key to route related events to the same partition. Idempotent producers prevent retry-induced reordering.

### Why interviewers ask this at senior level
This is a deceptively simple question. Senior engineers must articulate exactly where ordering holds, where it breaks, and the design pattern to preserve it in practice.

### Full Answer

**The guarantee:**
Within a single partition, Kafka is an ordered, append-only log. Record at offset 5 is always consumed before record at offset 6. This is an absolute guarantee — it is the core design invariant of Kafka's log abstraction.

**The limitation — cross-partition:**
There is NO ordering guarantee across partitions. A topic with 12 partitions is 12 independent logs. If an `OrderCreated` and `OrderShipped` event for the same order land in different partitions, consumers may process `OrderShipped` before `OrderCreated`. This is not a bug — it is a deliberate design for scalability.

**The solution — partition keys:**
Route all events for the same entity to the same partition via a consistent key. For order events, use `orderId` as the key. For user events, use `userId`. Kafka hashes the key to determine the partition. As long as partition count does not change, the same key always maps to the same partition, preserving order for that entity's events.

**The retry reordering risk:**
Without idempotent producers, a failed produce followed by a retry can create duplicates or reordering if in-flight batches were partially committed. Enable `enable.idempotence=true` (default since Kafka 3.0) to eliminate this. The broker assigns a sequence number per producer session and deduplicates retries.

**Repartitioning hazard:**
If you increase partition count, the hash mapping changes. Events for `orderId=123` may now go to partition 5 instead of partition 2. Old events are in partition 2, new events in partition 5 — consumer sees them out of order. Plan partition counts carefully and avoid resizing hot topics.

### Key Concepts to Mention
`Partition key` · `Idempotent producer` · `enable.idempotence=true` · `Hash routing` · `Partition resize hazard` · `Append-only log`

### Common Pitfall at This Experience Level
> ⚠️ The partition resize breaking ordering is a production gotcha that experienced engineers know. Mentioning it clearly differentiates you from candidates who only know the basic guarantee.

### Production Example
E-commerce order FSM: `OrderCreated` → `PaymentProcessed` → `OrderShipped` → `OrderDelivered`. All events keyed on `orderId`. With 24 partitions, all events for `orderId=abc123` always land in partition 7. Consumers see them in exact FSM sequence. No global ordering across orders — which is intentional and fine.

---

<a name="q10"></a>
## Q10. Explain the impact of partitions, replication, batching, and acknowledgements on Kafka performance and reliability

### TL;DR
The four levers trade throughput vs. durability: partitions (scale), replication (fault tolerance), batching (efficiency), acks (durability commitment). Production systems tune all four together.

### Why interviewers ask this at senior level
This is a synthesis question. Interviewers want to see that you can reason about the interactions between these four levers, not just describe each in isolation.

### Full Answer

**Partitions — the scalability lever:**
Each partition can be consumed by one consumer in a group. More partitions = higher parallel throughput. Cost: metadata overhead (each partition = a metadata record in KRaft), more leader elections on failure, longer consumer group rebalance time. Rule of thumb: `partitions = throughput_target / throughput_per_partition`. Do not over-partition prematurely — excess partitions waste resources and slow controller operations.

**Replication — the durability lever:**
Each partition has one leader and N-1 followers (replication factor). Every write to the leader is replicated to followers before (`acks=all`) or after (`acks=1`) acknowledging the producer. Higher replication factor = higher write latency + more network traffic + more disk usage. RF=3 is the production minimum for critical topics.

**Batching — the throughput lever:**
Producer batching groups multiple records before sending.
- `batch.size` (default 16KB): max batch bytes
- `linger.ms` (default 0): how long to wait for a fuller batch

Increase both for throughput-sensitive, latency-tolerant workloads. Batching amortizes network overhead — 1 network request for 500 records vs. 500 requests. On the consumer side, `max.poll.records` and `fetch.min.bytes` control read-path batch size.

**Acknowledgements — the commitment lever:**

| `acks` value | Behaviour | Durability | Throughput |
|---|---|---|---|
| `0` | Fire and forget | None | Maximum |
| `1` | Leader acknowledges | Leader only (data loss if leader crashes before replication) | High |
| `all` / `-1` | All ISR acknowledge | Highest (no loss while ≥1 ISR alive) | Lower |

**The critical interaction — acks=all is not enough alone:**
`acks=all` with RF=1 is equivalent to `acks=1` — there is only one replica to acknowledge. The safe config is: `acks=all` + `RF=3` + `min.insync.replicas=2`. This means at least 2 replicas must acknowledge before the produce is confirmed. If only 1 ISR remains (broker failure), produces will fail rather than silently lose data.

**The synthesis — all four interact:**
These are not independent knobs. `acks=all` with `RF=3` and large `batch.size` gives high durability and throughput but higher per-message latency. `acks=0` with `RF=1` and no batching gives minimum latency but zero reliability. Every production configuration is a conscious point on the throughput/durability/latency surface.

### Configuration Reference

| Use Case | acks | RF | min.insync.replicas | batch.size | linger.ms |
|---|---|---|---|---|---|
| Financial events / payments | `all` | 3 | 2 | 64KB | 5ms |
| Application logs / metrics | `0` or `1` | 1 | — | 16KB | 0 |
| User activity events | `1` | 2 | 1 | 32KB | 1ms |
| Audit trail | `all` | 3 | 2 | 16KB | 0 |

### Key Concepts to Mention
`acks=all` · `min.insync.replicas` · `batch.size` · `linger.ms` · `ISR (In-Sync Replicas)` · `RF=3` · `Throughput/durability/latency surface`

### Common Pitfall at This Experience Level
> ⚠️ The `acks=all` + `min.insync.replicas` interaction is a classic senior-level trap. `acks=all` with RF=1 is NOT safe. You must set `min.insync.replicas=2` AND `RF=3` together. Knowing this nuance signals genuine production depth.

### Production Example
**Payments topic config:** `RF=3`, `acks=all`, `min.insync.replicas=2`, `batch.size=64KB`, `linger.ms=5`. Guarantees: zero data loss on single-broker failure, 64KB batches for throughput efficiency, 5ms extra latency accepted for batch fill.

**Metrics topic config:** `RF=1`, `acks=0`, no linger. Metrics loss is acceptable; maximum throughput is the priority.

---

*Guide covers: MicroservicesandKafkaInterviewQuestions.md — atulbkumar/InterviewQuestions*
