# Spring Boot + Postgres Sidecar in Kubernetes

Here's a thorough breakdown of how sidecars work in Kubernetes, and then a specific use case with Postgres.

## The sidecar pattern

In Kubernetes, every Pod can run multiple containers that share the same network namespace and can optionally share volumes. The sidecar pattern exploits this — you have a primary container (your app) and one or more sidecar containers that run alongside it, augmenting it without being baked into the same image.

Common sidecar uses: log shippers (Fluentd), service mesh proxies (Envoy/Istio), secrets injectors, monitoring agents — and databases for local/embedded use.

## Key things to understand from the diagram

- The Spring Boot container connects to Postgres via `localhost:5432` — not a service name, not a cluster IP. Because both containers share the Pod's network namespace, `localhost` just works. No inter-Pod networking involved.

## Health check mechanics with sidecars

Kubernetes manages health independently per-container, but Pod readiness is the aggregate of all containers. Here's how it plays out:

- Pod readiness is the AND of all containers. The Service only routes traffic to the Pod once every container's readiness probe passes. So if Postgres is still initializing, Spring Boot is effectively unreachable even if it's ready itself — which is usually desirable.
- Liveness failures restart only the failed container. If Postgres crashes, Kubernetes restarts only the `postgres` container. Spring Boot keeps running but will start throwing connection errors — which is why Spring Boot's datasource should have retry logic configured.
- Containers in a Pod start in parallel by default. Postgres needs a few seconds to initialize before accepting connections. Your Spring Boot app may attempt to connect during startup and fail unless you handle ordering.

### Three ways to handle startup ordering (in order of preference)

1. initContainer — runs a `pg_isready` loop before any main container starts (clean and explicit).
2. `startupProbe` with a high `failureThreshold` on Spring Boot — gives it time to retry while Kubernetes waits for startup to succeed.
3. Configure HikariCP to not fail fast: `spring.datasource.hikari.initializationFailTimeout=-1` — lets connection acquisition retry in the background.

## The actual YAML

Below is a complete, production-grade manifest for this use case. Embed this spec in a `Deployment` or use as a `Pod` for simple scenarios.

```yaml
apiVersion: v1
kind: Pod   # or embed this spec in a Deployment
metadata:
  name: my-app
spec:
  # ─── Init container: ensures PG is ready before Spring Boot starts ───
  initContainers:
    - name: wait-for-postgres
      image: postgres:16-alpine
      command:
        - sh
        - -c
        - |
          until pg_isready -h localhost -U postgres; do
            echo "waiting for postgres..."; sleep 2;
          done

  containers:
    # ─── Primary: Spring Boot ───────────────────────────────────────────
    - name: spring-boot-app
      image: your-registry/my-spring-app:latest
      ports:
        - containerPort: 8080
      env:
        - name: SPRING_DATASOURCE_URL
          value: "jdbc:postgresql://localhost:5432/mydb"
        - name: SPRING_DATASOURCE_USERNAME
          value: postgres
        - name: SPRING_DATASOURCE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: pg-secret
              key: password

      # startupProbe: gives Spring Boot time to connect & migrate (Flyway etc.)
      startupProbe:
        httpGet:
          path: /actuator/health
          port: 8080
        failureThreshold: 30     # 30 × 10s = 5 minutes max
        periodSeconds: 10

      # readinessProbe: removes Pod from Service endpoints when unhealthy
      readinessProbe:
        httpGet:
          path: /actuator/health/readiness
          port: 8080
        initialDelaySeconds: 0
        periodSeconds: 10
        failureThreshold: 3

      # livenessProbe: restarts container if it deadlocks
      livenessProbe:
        httpGet:
          path: /actuator/health/liveness
          port: 8080
        initialDelaySeconds: 0
        periodSeconds: 15
        failureThreshold: 3

    # ─── Sidecar: Postgres ──────────────────────────────────────────────
    - name: postgres
      image: postgres:16-alpine
      ports:
        - containerPort: 5432
      env:
        - name: POSTGRES_DB
          value: mydb
        - name: POSTGRES_USER
          value: postgres
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: pg-secret
              key: password
      volumeMounts:
        - name: pg-data
          mountPath: /var/lib/postgresql/data

      # readinessProbe: Pod won't be Ready until PG accepts connections
      readinessProbe:
        exec:
          command: ["pg_isready", "-U", "postgres"]
        initialDelaySeconds: 5
        periodSeconds: 5
        failureThreshold: 5

      # livenessProbe: restarts Postgres if it gets stuck
      livenessProbe:
        exec:
          command: ["pg_isready", "-U", "postgres"]
        initialDelaySeconds: 30
        periodSeconds: 15
        failureThreshold: 3

  volumes:
    - name: pg-data
      emptyDir: {}          # ephemeral — use a PVC for persistence
      # If you need persistence:
      # persistentVolumeClaim:
      #   claimName: pg-pvc

---
apiVersion: v1
kind: Secret
metadata:
  name: pg-secret
type: Opaque
stringData:
  password: "your-secure-password"
```

## Spring Boot Actuator split probes

Use `/actuator/health/liveness` for `livenessProbe` and `/actuator/health/readiness` for `readinessProbe` — not just `/actuator/health`. This maps to Spring Boot's `ApplicationAvailability` model and gives you fine-grained control. Add this to your `application.yml`:

```yaml
management:
  endpoint:
    health:
      probes:
        enabled: true
  health:
    livenessState:
      enabled: true
    readinessState:
      enabled: true
```

## Critical things to understand about health checks in sidecars

- Pod readiness is the AND of all containers. The Service only routes traffic to the Pod once every container's readiness probe passes. So if Postgres is still initializing, Spring Boot is also effectively unreachable even if it's ready itself — which is usually what you want.
- Liveness failures restart only the failed container. If Postgres crashes, Kubernetes restarts only the `postgres` container. Spring Boot keeps running but will throw connection errors — so configure Spring Boot's datasource with retry logic (e.g. Hikari settings, retry-on-connect).
- The startup ordering problem: containers start in parallel by default. Use an `initContainer`, `startupProbe`, or Hikari configuration to handle this.

## A note on Postgres as a sidecar

This pattern works well for local dev, testing, or when the database is truly scoped to one app instance. For production, a separate Postgres `Deployment` or managed service (RDS, Cloud SQL) with a PVC is usually the right choice — because with a sidecar, if the Pod is rescheduled, your `emptyDir` data is gone. If you go the sidecar route in production, use a `PersistentVolumeClaim` for durability.

---

If you'd like, I can:

- Convert the Pod into a `Deployment` with a `PersistentVolumeClaim` example.
- Add a `ConfigMap` / `Secret` handling example for credentials.
- Generate a small `README` with quick `kubectl` apply commands.

