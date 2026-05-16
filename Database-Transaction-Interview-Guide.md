# Database Transaction Interview Guide

This guide compiles core concepts, architectural trade-offs, and high-frequency interview questions concerning database internals, Spring Framework transactions, distributed caching, and multi-application concurrency.

## Section 1: Database Locking Foundations

### Q1: What is the fundamental difference between a Shared Lock (S) and an Exclusive Lock (X)?
- **Shared Lock (S):** Acquired for read operations. Multiple transactions can hold shared locks on the same resource concurrently. No transaction can modify the data until all shared locks are released.
- **Exclusive Lock (X):** Acquired for data modification (INSERT, UPDATE, DELETE). Only one transaction can hold an exclusive lock on a resource. It blocks all other transactions from both reading and writing to that resource.

### Q2: Explain Lock Granularity and how it impacts database performance.
- **Granularity** refers to the physical size of the resource wrapped by a lock.
- **Row-Level:** Highest concurrency, lowest chance of conflicts, but consumes substantial CPU and memory overhead to manage thousands of tracking tokens.
- **Page/Block Level:** Medium concurrency; locks a chunk of disk blocks containing multiple rows.
- **Table-Level:** Lowest concurrency, lowest memory overhead; blocks access to an entire dataset.
- **Lock Escalation:** If an application acquires too many row-level locks, the database engine automatically converts them into a single table lock to save system memory. This can unexpectedly stall concurrent operations.

### Q3: Compare Pessimistic Locking vs. Optimistic Locking. When would you use each?
| Feature | Pessimistic Locking | Optimistic Locking |
|---|---|---|
| Mechanism | Uses physical database locks (FOR UPDATE) to block access immediately upon querying. | Uses an application-level token (version number or timestamp) to validate state at commit time. |
| Best For | High-contention environments where data conflicts are highly frequent. | Low-contention or read-heavy applications where conflicts are rare. |
| Overhead | High database connection and lock table overhead. | Minimal database overhead; costs a minor version-validation step. |
| Failure Behavior | Transactions wait in a queue until a timeout occurs. | Fails fast by throwing an exception if a conflict is detected. |

## Section 2: Spring Boot and the @Transactional Ecosystem

### Q4: How does Spring Boot's @Transactional annotation interact with a physical database?
- Spring uses Aspect-Oriented Programming (AOP) proxies.
- When a method annotated with `@Transactional` is called, Spring intercepts the call.
- The proxy opens a standard JDBC connection and disables auto-commit.
- The proxy configures the isolation level and read-only flags on that specific connection session.
- If the method completes successfully, the proxy issues a JDBC `commit()`. If a runtime exception occurs, it issues a `rollback()`.

### Q5: How do Spring's Isolation Levels translate to database-level locks?
- `READ_UNCOMMITTED`: No read locks applied; vulnerable to dirty reads.
- `READ_COMMITTED` (Default for PostgreSQL, Oracle, SQL Server): Shared locks are released as soon as the individual SQL query completes execution.
- `REPEATABLE_READ` (Default for MySQL): Shared locks are held on all queried rows until the entire Java transaction commits.
- `SERIALIZABLE`: Range/predicate locks are held across entire datasets, preventing concurrent insertion of new matching rows (phantom reads).

### Q6: What does `readOnly = true` do under the hood?
- **Hibernate/JPA Layer:** Disables entity dirty-checking. Hibernate will not track state changes or generate automatic `UPDATE` queries, conserving CPU and memory.
- **Database Layer:** Instructs the database connection session to reject any write operations, allowing engines like MySQL or Oracle to optimize query execution paths and skip internal write-intent lock tables.

### Q7: Explain the difference between `Propagation.REQUIRED` and `Propagation.REQUIRES_NEW`.
- **REQUIRED (Default):** Joins the existing transaction if one is present. If Method A calls Method B, they share the same physical database connection. Any locks acquired by Method B remain held until Method A finishes and commits.
- **REQUIRES_NEW:** Always suspends the existing transaction and opens a completely new, independent database connection. Method B acquires its own locks, commits or rolls back, and releases those locks immediately upon exiting, independent of Method A's ultimate outcome.

## Section 3: Introducing the Cache Layer

### Q8: Why do database locks fail to protect data consistency once a cache layer is introduced?
- Database locks require traffic to pass through the database engine to be enforced.
- A cache layer (like Redis or Caffeine) sits in front of the database.
- When an application fetches data via a cache-hit, the request never reaches the database.
- Consequently, no database-level shared or exclusive locks are generated, leaving the system vulnerable to stale reads and out-of-order writes.

### Q9: What is a Cache Stampede (Thundering Herd) and how does Spring mitigate it?
- **Problem:** When a high-traffic cache key expires, hundreds of concurrent application threads encounter a cache miss at the exact same millisecond. They all execute identical heavy database queries simultaneously, overwhelming the database connection pool and spiking lock contention.
- **Mitigation:** Setting `@Cacheable(sync = true)`. This introduces a local JVM-level lock on the thread execution. Only one thread is allowed to bypass the cache to query the database and update the cache; all other matching threads are blocked locally and cleanly served from the cache the moment it is re-populated.

### Q10: Why should you evict a cache after a database transaction commits, rather than before?
- If you execute a cache eviction (`@CacheEvict`) before the database transaction commits:
  - App Thread 1 deletes the cache key and updates the database row.
  - Before Thread 1's transaction commits, App Thread 2 experiences a cache miss.
  - Thread 2 queries the database, reads the old uncommitted data, and saves that stale data back into the cache.
  - Thread 1 finishes committing its changes.
- **Result:** The database now has the new data, but the cache is permanently locked with stale data until the next eviction cycle.
- **Best Practice:** Use `TransactionSynchronizationManager.registerSynchronization` in Spring to trigger cache eviction strictly within the `afterCommit()` lifecycle hook.

## Section 4: Multi-Application Shared Architecture

### Q11: Why do local JVM synchronization blocks or Spring’s `sync = true` fail in a multi-instance microservices environment?
- Local synchronization mechanisms (like `synchronized` blocks, `ReentrantLock`, or `@Cacheable(sync = true)`) are constrained entirely within the memory space of a single Java Virtual Machine.
- If you run multiple instances of an application behind a load balancer, Instance 1 cannot visibility-check or block threads running on Instance 2.
- They will execute queries concurrently, bypassing local locks completely.

### Q12: How do you design an application to prevent race conditions when multiple microservices share the same cache and database?
You must elevate locking to a centralized component using one of three patterns:
- **Distributed Locking (Application-Level Optimization):** Implement a cluster-wide distributed lock manager using Redis (via Redisson) or ZooKeeper. Applications must request and acquire a shared global token (`lock.tryLock()`) before querying or writing to the resource.
- **Database Pessimistic Locking (Fallback Strategy):** Enforce locking at the data tier using explicit SQL statements (`SELECT ... FOR UPDATE`). This blocks any external application at the database driver level, forcing them to queue up regardless of what language or platform they are built on.
- **Optimistic Versioning (Safety Net):** Map an integer `@Version` column on the database entities. Even if apps bypass the cache and hit the database concurrently, the engine will safely reject the slower update step with an `OptimisticLockingFailureException`, protecting the data from silent corruption.

## Section 5: Scenario-Based / Architectural Questions

### Q13: A financial microservice must process wallet balance transfers across multiple scaled instances. Performance is a priority, but balance corruption is unacceptable. What architecture do you choose?
- Use a Distributed Lock (Redisson) tied to the specific user wallet ID (`lock:wallet:123`). This keeps locks lightweight and memory-bound inside Redis, preventing instances from spamming the database with lock requests.
- Pair this with database-level Optimistic Locking (`@Version`) as a fallback safety net. If a distributed lock slips or times out unexpectedly, the database version check will catch the collision and abort the transaction before saving invalid financial states.

### Q14: You have an application written in Spring Boot and a legacy system written in Go. Both read and write to the exact same PostgreSQL database. How do you handle concurrency safely?
- Because you cannot share Java-specific libraries (like Redisson) or Spring frameworks with a legacy Go application, locking must be pushed to the infrastructure tier.
- Implement hard Database Pessimistic Locking (`@Lock(LockModeType.PESSIMISTIC_WRITE)`) in Spring, and use equivalent explicit `SELECT ... FOR UPDATE` syntax within the Go application.
- Rely on the database engine to serve as the single, language-agnostic source of truth for concurrency control.

## Next Step
To practice implementing these strategies in code, I can provide a complete runnable project snippet showing either Spring Data JPA Pessimistic Locking or a Redisson Distributed Lock implementation. Let me know which coding example you would like to explore next.
