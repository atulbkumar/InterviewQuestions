Microservices and Kafka Interview Questions
1. Explain the microservice per datasource (database-per-service) pattern and its tradeoffs.
Definition

The Database-per-Service pattern is a microservices architecture pattern where each service owns and manages its own database. No other service is allowed to directly access that database. Communication between services occurs through APIs, events, or messaging systems.

Benefits
Loose coupling between services.
Services can use different database technologies (polyglot persistence).
Independent deployment and scaling.
Improved fault isolation.
Enables autonomous teams.
Tradeoffs
Complex cross-service queries.
Data duplication may be required.
Distributed transactions become difficult.
Eventual consistency often replaces strong consistency.
Increased operational complexity.
Example

An e-commerce system may have:

Order Service → Orders DB
Customer Service → Customers DB
Inventory Service → Inventory DB

Services exchange information through APIs or Kafka events rather than directly querying each other's databases.

2. Compare API Gateway, Service Discovery, and Service Mesh. Explain when to use each and what problems they solve.
Component	Purpose	Problems Solved	Typical Users
API Gateway	Single entry point for clients	Routing, authentication, rate limiting, API aggregation	External clients
Service Discovery	Allows services to find each other dynamically	Dynamic IPs, scaling, failover	Internal services
Service Mesh	Manages service-to-service communication	Security, observability, retries, traffic control	Internal services
API Gateway

Acts as the front door for external consumers.

Functions

Authentication and authorization
SSL termination
Request routing
Rate limiting
API aggregation

Examples

Kong
NGINX
Spring Cloud Gateway
AWS API Gateway
Service Discovery

Maintains a registry of service instances.

Functions

Dynamic endpoint resolution
Load balancing
Health-aware routing

Examples

Kubernetes DNS
Eureka
Consul
Service Mesh

Provides a dedicated infrastructure layer for service-to-service communication.

Functions

Mutual TLS (mTLS)
Retries
Circuit breaking
Traffic shaping
Distributed tracing

Examples

Istio
Linkerd
Consul Connect
Typical Architecture

Client → API Gateway → Microservices

Microservices → Service Discovery

Microservices ↔ Service Mesh

3. Explain scenarios where you would choose only an API Gateway versus introducing a Service Mesh.
Use Only an API Gateway When
Small number of services (e.g., less than 20)
Simple communication patterns
Limited operational resources
Security requirements are moderate
Minimal need for traffic management
Example

A startup with:

User Service
Product Service
Order Service

An API Gateway may be sufficient.

Introduce a Service Mesh When
Large microservice ecosystem
Complex service-to-service traffic
Need for mTLS everywhere
Advanced observability requirements
Canary deployments and traffic splitting
Consistent retry and circuit-breaker policies
Example

A platform with 100+ microservices requiring:

Zero-trust networking
Distributed tracing
Fine-grained traffic management
Tradeoff
API Gateway Only	Service Mesh
Simpler	More complex
Lower cost	Higher operational overhead
Easier maintenance	Advanced networking capabilities
Suitable for smaller systems	Suitable for large-scale systems
4. How does service discovery work in a cloud-native microservices architecture?
Registration

When a service starts:

It receives an IP address.
Registers itself with a discovery mechanism.
Publishes metadata such as:
Host
Port
Health status
Discovery

When another service needs to communicate:

It queries the registry.
Receives available instances.
Selects one instance through load balancing.
Kubernetes Example
Pods are created dynamically.
Kubernetes Service provides a stable endpoint.
CoreDNS resolves service names.
Traffic is routed to healthy pods.
Benefits
Dynamic scaling
Fault tolerance
Load balancing
Simplified service communication
Types
Client-Side Discovery

Client performs lookup.

Examples:

Netflix Eureka
Consul
Server-Side Discovery

Load balancer performs lookup.

Examples:

Kubernetes Services
AWS Elastic Load Balancer
5. Explain how Kafka handles situations where consumers are overwhelmed with events and unable to keep up with producers.

Kafka naturally supports different producer and consumer speeds through durable log storage.

How It Works

Producers write records to Kafka partitions.

Consumers read at their own pace using offsets.

If consumers slow down:

Messages remain stored in Kafka.
Producers continue writing.
Consumer lag increases.
Kafka's Backpressure Characteristics

Kafka does not directly push data to consumers.

Consumers pull data when ready.

This prevents producers from being blocked by slow consumers.

Protection Mechanisms
Retention policies preserve messages.
Consumer groups distribute workload.
Partitioning enables parallel consumption.
Horizontal scaling allows additional consumers.
Risks

If lag grows beyond retention:

Older messages may be deleted before consumption.
Data loss from the consumer perspective may occur.
6. What is consumer lag in Apache Kafka and how would you troubleshoot it?
Definition

Consumer lag is the difference between:

Latest offset − Consumer committed offset

A high lag indicates consumers are falling behind producers.

Causes
Slow message processing
Insufficient consumer instances
Too few partitions
Network bottlenecks
Consumer rebalances
Large message sizes
Troubleshooting Steps
Measure Lag

Use:

kafka-consumer-groups.sh --describe
Check Consumer Metrics

Look for:

Processing latency
Poll frequency
Commit delays
Check Broker Metrics

Look for:

CPU utilization
Disk throughput
Network saturation
Verify Partition Count

Consumers cannot scale beyond partition count.

Review Rebalance Activity

Frequent rebalances can reduce throughput significantly.

Monitoring Metrics
Records Lag
Records Lag Max
Consumer Fetch Rate
Processing Time
Rebalance Count
7. What strategies can be used to improve Kafka consumer throughput and handle backpressure?
Increase Parallelism

Add more partitions.

Add more consumer instances.

Tune Consumer Configuration

Increase:

max.poll.records
fetch.min.bytes
fetch.max.wait.ms
Batch Processing

Process records in batches rather than one at a time.

Benefits:

Fewer commits
Better CPU efficiency
Asynchronous Processing

Use worker pools or asynchronous frameworks.

Scale Consumers

Add more consumers within the consumer group.

Optimize Business Logic

Common bottlenecks:

Database writes
External API calls
Serialization overhead
Backpressure Strategies
Pause consumer partitions temporarily
Buffer events
Apply rate limiting
Use Dead Letter Queues (DLQs)
Autoscale consumer workloads
8. Explain how Kafka brokers can be optimized for performance and scalability.
Storage Optimization
Use SSDs
Separate Kafka logs from OS disks
Ensure adequate disk throughput
Increase Partition Count

More partitions:

Improve parallelism
Increase throughput

However:

Excessive partitions increase metadata overhead
Network Optimization
High-bandwidth networking
Compression (Snappy, LZ4, ZSTD)
Optimize MTU and network buffers
Producer Tuning

Increase batching:

batch.size
linger.ms
compression.type
Broker Configuration

Tune:

num.network.threads
num.io.threads
socket.send.buffer.bytes
socket.receive.buffer.bytes
Scale Horizontally

Add brokers and redistribute partitions.

Monitoring

Track:

Disk usage
Request latency
Under-replicated partitions
Network throughput
Controller activity
9. How does Kafka maintain message ordering and what are the limitations of ordering guarantees?
Ordering Guarantee

Kafka guarantees ordering only within a partition.

Messages written to the same partition are stored sequentially.

Example

Partition 0:

Event1
Event2
Event3

Consumers read in the same order.

Limitations
Multiple Partitions

No global ordering exists across partitions.

Example:

Partition 0 → A1 A2
Partition 1 → B1 B2

Kafka cannot guarantee whether A2 occurs before B1 globally.

Multiple Producers

Without proper configuration, retries may create ordering issues.

Best Practices
Use a stable partition key.
Ensure related events go to the same partition.
Enable idempotent producers.
Avoid unnecessary repartitioning.
10. Explain the impact of partitions, replication, batching, and acknowledgements on Kafka performance and reliability.
Partitions
Benefits
Parallelism
Scalability
Higher throughput
Drawbacks
Increased metadata
More leader elections
Higher operational complexity
Replication
Benefits
Fault tolerance
High availability
Drawbacks
Additional storage
More network traffic
Slightly higher write latency

Example:

Replication Factor = 3

One leader and two replicas store each record.

Batching
Benefits
Higher throughput
Reduced network overhead
Better disk utilization
Drawbacks
Increased latency while waiting for batch formation

Common producer settings:

batch.size
linger.ms
Acknowledgements (acks)
acks=0
Highest throughput
Lowest durability
acks=1
Leader acknowledges write
Balanced performance and reliability
acks=all
All in-sync replicas acknowledge
Highest durability
Increased latency
Tradeoff Summary
Feature	Performance Impact	Reliability Impact
More Partitions	Higher throughput	Neutral
More Replicas	Lower throughput	Higher durability
Larger Batches	Higher throughput	Slightly higher latency
acks=0	Highest throughput	Lowest reliability
acks=1	Balanced	Balanced
acks=all	Lower throughput	Highest reliability
Interview Takeaway

Kafka scalability primarily comes from partitioning, reliability from replication, efficiency from batching, and durability from acknowledgement settings. Successful Kafka architectures balance all four based on business requirements.