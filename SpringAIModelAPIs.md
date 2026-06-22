
# AI Model Routing in Spring Boot — A Complete Guide

> A comprehensive reference covering architecture, Spring Boot components, alternative frameworks, and gateway patterns for calling AI models through APIs with runtime model switching.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Config-Driven Model Definitions](#config-driven-model-definitions)
4. [Spring Boot Components Used](#spring-boot-components-used)
5. [Core Implementation](#core-implementation)
6. [Runtime Fallback Strategies](#runtime-fallback-strategies)
7. [Alternative Frameworks Beyond Spring](#alternative-frameworks-beyond-spring)
8. [AI Gateway vs Traditional Gateway](#ai-gateway-vs-traditional-gateway)
9. [Choosing the Right Approach](#choosing-the-right-approach)

---

## Overview

The use case is: calling AI models through HTTP GET APIs, where each model has a different path or query parameter structure, the model to invoke is decided from a config file, and switching to a different model at runtime is required when response times exceed a threshold.

The core flow:

```
Incoming request
      ↓
ModelSelectionService   ← evaluates data + business conditions
      ↓
ModelConfigRegistry     ← reads from application.yml
      ↓
AiInferenceClient       ← WebClient with dynamic URL + timeout
      ↓
  [Model A / B / C]
      ↓
  Timeout exceeded? → switch to fallback model
      ↓
Caller response
```

---

## Architecture

### Three layers of concern

| Layer | Responsibility |
|---|---|
| **Selection** | Which model should handle this request (business logic) |
| **Invocation** | Build the right URL, call it non-blocking, enforce SLA |
| **Resilience** | What happens when the model is slow, failing, or overloaded |

Keeping these three separate is critical — selection logic changes frequently (A/B tests, new models), invocation is stable boilerplate, and resilience is infrastructure concern.

---

## Config-Driven Model Definitions

All model-specific details live in `application.yml`. Adding a new model requires zero code changes.

```yaml
ai:
  models:
    - id: model-a
      baseUrl: https://ai-gateway.internal
      path: /v1/infer
      queryParam: m
      queryValue: A
      timeoutMs: 800
      priority: 1
      enabled: true

    - id: model-b
      baseUrl: https://ai-gateway.internal
      path: /api/b/predict
      timeoutMs: 1200
      priority: 2
      enabled: true

    - id: model-c
      baseUrl: https://model-c.internal
      path: /model-c/run
      timeoutMs: 600
      priority: 3
      enabled: true
      fallbackFor:
        - model-a
        - model-b
```

### Config binding class

```java
@ConfigurationProperties(prefix = "ai")
@Configuration
public class ModelProperties {

    private List<ModelConfig> models = new ArrayList<>();

    public List<ModelConfig> getModels() { return models; }
    public void setModels(List<ModelConfig> models) { this.models = models; }

    @Data
    public static class ModelConfig {
        private String id;
        private String baseUrl;
        private String path;
        private String queryParam;    // null if path-based routing
        private String queryValue;
        private long timeoutMs;
        private int priority;
        private boolean enabled = true;
        private List<String> fallbackFor = new ArrayList<>();
    }
}
```

---

## Spring Boot Components Used

### Config binding layer

| Component | Role |
|---|---|
| `@ConfigurationProperties` | Binds `ai.models[]` list from YAML into a typed Java class |
| `@EnableConfigurationProperties` | Activates the binding class at startup |

### Service layer

| Component | Role |
|---|---|
| `@Service` | Marks `ModelSelectionService` as a Spring-managed singleton |
| `@Autowired` | Constructor injection of the config bean |
| `@PostConstruct` | Builds the runtime `Map<String, ModelConfig>` registry once after injection |
| `@ConditionalOnProperty` | Gates a model bean on a flag (`ai.models.model-a.enabled=false`) |
| `@Profile` | Environment split — test uses mock model, prod uses real endpoint |

### HTTP client layer (Project Reactor + WebFlux)

| Component | Role |
|---|---|
| `WebClient.Builder` | Non-blocking HTTP client, auto-configured by `spring-boot-starter-webflux` |
| `UriComponentsBuilder` | Constructs URLs at runtime from path + optional query params |
| `bodyToMono()` | Async response deserialization |
| `Mono.timeout()` | Per-call SLA deadline |
| `onErrorResume()` | Fallback on timeout — switches to fallback model lazily |
| `Mono.firstWithValue()` | Race variant — fires multiple models, takes the first response |

### Resilience and observability

| Component | Role |
|---|---|
| `Resilience4j` | Circuit breaker + retry — stops hammering a degraded model |
| `Micrometer Timer` | Per-model latency metrics, exposed to Prometheus/Grafana |
| `Actuator /health` | Custom `HealthIndicator` for model availability probes |

---

## Core Implementation

### Model selection service

```java
@Service
public class ModelSelectionService {

    private final Map<String, ModelConfig> registry;

    public ModelSelectionService(ModelProperties props) {
        this.registry = props.getModels().stream()
            .filter(ModelConfig::isEnabled)
            .collect(Collectors.toMap(ModelConfig::getId, m -> m));
    }

    public ModelConfig selectModel(InferenceRequest request) {
        // Business rules — replace with your own logic
        if (request.isHighPriority()) return registry.get("model-a");
        if (request.isLargePayload()) return registry.get("model-b");
        return registry.get("model-c");
    }

    public ModelConfig getFallback(String modelId) {
        return registry.values().stream()
            .filter(m -> m.getFallbackFor().contains(modelId))
            .findFirst()
            .orElseThrow(() -> new NoFallbackException(modelId));
    }
}
```

### AI inference client with timeout + fallback

```java
@Service
public class AiInferenceClient {

    private final WebClient.Builder wcBuilder;
    private final ModelSelectionService selector;

    public AiInferenceClient(WebClient.Builder wcBuilder, ModelSelectionService selector) {
        this.wcBuilder = wcBuilder;
        this.selector = selector;
    }

    public Mono<InferenceResponse> invoke(InferenceRequest request) {
        ModelConfig model = selector.selectModel(request);

        return callModel(model, request)
            .timeout(Duration.ofMillis(model.getTimeoutMs()))
            .onErrorResume(TimeoutException.class, ex -> {
                log.warn("Model {} timed out after {}ms, switching to fallback",
                    model.getId(), model.getTimeoutMs());
                ModelConfig fallback = selector.getFallback(model.getId());
                return callModel(fallback, request);
            });
    }

    private Mono<InferenceResponse> callModel(ModelConfig model, InferenceRequest req) {
        WebClient client = wcBuilder.baseUrl(model.getBaseUrl()).build();

        return client.get()
            .uri(uriBuilder -> {
                UriBuilder b = uriBuilder.path(model.getPath());
                if (model.getQueryParam() != null) {
                    b = b.queryParam(model.getQueryParam(), model.getQueryValue());
                }
                return b.build();
            })
            .retrieve()
            .bodyToMono(InferenceResponse.class);
    }
}
```

---

## Runtime Fallback Strategies

Different scenarios call for different Reactor operators:

| Scenario | Reactor approach |
|---|---|
| Hard timeout → switch model | `.timeout(dur).onErrorResume(TimeoutException.class, ...)` |
| Race two models, take fastest | `Mono.firstWithValue(callA(req), callB(req))` |
| Retry same model before fallback | `.retry(2).timeout(dur).onErrorResume(...)` |
| Circuit breaker on repeated failures | `ReactorResilience4j.circuitBreaker(cb, mono)` |
| Retry with exponential backoff | `.retryWhen(Retry.backoff(3, Duration.ofMillis(200)))` |

### Circuit breaker with Resilience4j

```java
@Bean
public CircuitBreaker modelABreaker(CircuitBreakerRegistry registry) {
    return registry.circuitBreaker("model-a", CircuitBreakerConfig.custom()
        .failureRateThreshold(50)
        .waitDurationInOpenState(Duration.ofSeconds(30))
        .build());
}

// In the client:
public Mono<InferenceResponse> invokeWithBreaker(InferenceRequest req) {
    ModelConfig model = selector.selectModel(req);
    Mono<InferenceResponse> call = callModel(model, req)
        .timeout(Duration.ofMillis(model.getTimeoutMs()));

    return ReactorResilience4j
        .circuitBreaker(circuitBreaker, call)
        .onErrorResume(CallNotPermittedException.class, ex ->
            callModel(selector.getFallback(model.getId()), req));
}
```

---

## Alternative Frameworks Beyond Spring

### Java-native (same JVM)

| Framework | What it adds | Best for |
|---|---|---|
| **Spring AI** | `ChatClient` abstraction, built-in retry/fallback via advisors | Teams already in Spring wanting minimal overhead |
| **LangChain4j** | Chains, agents, memory, RAG, `AiServices` interface-based calling | Complex multi-step reasoning workflows |
| **Semantic Kernel (Java SDK)** | Microsoft's `Kernel` + planner, plugin orchestration | Azure OpenAI, enterprise structured orchestration |
| **Quarkus LangChain4j ext.** | LangChain4j wired into Quarkus CDI + GraalVM native | Low cold-start latency requirements |
| **Jlama** | Local LLM inference in-JVM via Panama API | Offline/on-premise inference, no external API calls |

### Python-native (run as a sidecar, call via REST)

| Framework | What it adds | Best for |
|---|---|---|
| **LangGraph** | Stateful graph of nodes + edges, cycles, branching | Complex routing logic with state and retry loops |
| **LiteLLM** | Single OpenAI-compatible proxy for 100+ model APIs | Routing across many providers with zero code change |
| **RouteLLM** | ML classifier picks strong vs weak model by query complexity | Data-driven model selection at runtime |
| **DSPy** | Programmatic prompt optimization + model selection | Optimizing which model handles which query class |
| **Haystack** | Pipeline DAG with built-in routers | RAG pipelines with conditional model routing |
| **CrewAI** | Multi-agent crews with role-based task assignment | Multi-model collaboration on a single task |
| **Semantic Router** | Embedding-based input classification for routing | Route by meaning of the input, not hard-coded rules |

### Gateway/infrastructure layer (language-agnostic)

| Tool | What it does | Best for |
|---|---|---|
| **OpenRouter** | Single endpoint routing to many providers | Ops-managed routing without code changes |
| **Portkey** | AI gateway with routing, retry, observability | Production observability + cost tracking |
| **MCP** | Model Context Protocol — standard for tool + context passing | Standardized tool-calling across models |
| **KServe** | Kubernetes-native model serving | Self-hosted models on K8s |
| **BentoML** | ML model server with REST API | Packaging and serving custom ML models |
| **Triton** | NVIDIA inference server, gRPC interface | GPU-accelerated inference at scale |

### Choosing the right fit

| Your requirement | Best fit |
|---|---|
| Stay fully in Spring Boot JVM | Spring AI or LangChain4j |
| Stateful routing graph with cycles | LangGraph sidecar |
| Route 100+ external model APIs with zero code | LiteLLM |
| Route by query complexity (data-driven) | RouteLLM |
| Ops team manages routing config, not devs | Portkey or OpenRouter |

---

## AI Gateway vs Traditional Gateway

### What a traditional gateway does

A classic API gateway (Spring Cloud Gateway, Kong, NGINX) solves a structural routing problem — which backend service handles this request, based on path prefix, HTTP verb, or header value.

- **Routing unit:** URL path / HTTP verb
- **Latency:** 10–200ms
- **Response size:** KB, predictable and bounded
- **Timeout:** fixed, simple
- **Retry:** safe — downstream services are usually idempotent
- **Caching:** keyed on exact URL
- **Rate limiting:** requests per second

### What changes with AI models

#### Token is the new byte

Every LLM interaction is measured in tokens, not bytes or requests. Rate limits from providers are in tokens/minute. The gateway must count tokens in both the prompt (input) and response (output) and enforce limits on that unit.

#### Retry is dangerous

In a normal gateway, retrying a failed call to `OrderService` is cheap. In an AI gateway, a retry re-sends the full prompt — if the prompt is 2,000 tokens, an aggressive retry policy can multiply cost by 10x in seconds. AI gateways implement smarter retry: exponential backoff, retry only on 429/503, never on model-generated errors.

#### Fallback means switching models, not instances

Normal gateway fallback routes to a different instance of the same service. AI gateway fallback switches to a completely different model — different provider, different context window, different pricing, different quality. The gateway must understand model capabilities, not just health checks.

#### Caching is semantic, not exact

A URL-keyed cache is useless for AI. "What is the capital of France?" and "Tell me the capital city of France" should return the same cached answer. AI gateways cache on prompt embeddings — embed the incoming prompt as a vector and check for semantic similarity against cached prompts above a cosine-similarity threshold.

#### Responses stream

Normal APIs send one response body. LLMs stream tokens as they generate via Server-Sent Events (SSE). The gateway must act as a streaming proxy — buffering the full response would defeat streaming and balloon latency. Timeout handling also changes: timeout on *time to first token*, not time to full response.

#### Non-determinism changes validation

A normal gateway checks "did the service return 200?" and calls it success. With AI, a 200 with a hallucinated or off-topic response is still a failure. AI gateways add response validation — output guardrails, schema checking, content filtering — before returning to the caller.

### Side-by-side comparison

| Dimension | Traditional gateway | AI gateway |
|---|---|---|
| Routing key | URL path / verb | Model capability + semantic content |
| Rate limit unit | Requests/second | Tokens/minute |
| Response size | Bounded (KB) | Unbounded (tokens) |
| Latency | 10–200ms | 500ms–30s |
| Caching strategy | Exact URL match | Semantic similarity (embedding) |
| Retry safety | Usually safe | Expensive — costs tokens per retry |
| Fallback target | Same service, different instance | Different model entirely |
| Response format | Fixed schema | Streaming SSE, non-deterministic |
| Validation | HTTP status code | Content guardrails, schema checks |
| Cost dimension | Infrastructure only | Per-token cost per provider |

### Practical integration from Spring Boot

With a gateway like **LiteLLM** or **Portkey** in front of model providers, your Spring Boot app makes a single `WebClient` call to the gateway endpoint. The gateway handles:

- Which model actually gets called (routing rules in config)
- Token counting and cost attribution
- Fallback if the primary model times out
- Semantic caching of repeated prompts
- PII scrubbing before the prompt leaves your network
- Observability — latency histograms, cost per model, error rates

Your Spring Boot code stays clean — `ModelSelectionService` encodes business-level selection logic, while the gateway handles operational complexity of managing multiple model providers.

---

## Maven Dependencies

```xml
<!-- WebFlux + Reactor for non-blocking model calls -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>

<!-- Config properties binding -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-configuration-processor</artifactId>
    <optional>true</optional>
</dependency>

<!-- Circuit breaker -->
<dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-spring-boot3</artifactId>
    <version>2.2.0</version>
</dependency>
<dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-reactor</artifactId>
    <version>2.2.0</version>
</dependency>

<!-- Metrics -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>

<!-- Actuator -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>

<!-- Optional: Spring AI for higher-level abstraction -->
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-openai-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
```

---

*Generated from a technical discussion on AI model routing patterns in the Spring Boot ecosystem.*
