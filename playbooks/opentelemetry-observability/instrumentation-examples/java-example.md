# Example: Java Spring Boot with OpenTelemetry

## Dependencies (Maven)

```xml
<dependencies>
    <!-- Spring Boot -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>

    <!-- OpenTelemetry -->
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-api</artifactId>
        <version>1.32.0</version>
    </dependency>
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-sdk</artifactId>
        <version>1.32.0</version>
    </dependency>
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-exporter-otlp</artifactId>
        <version>1.32.0</version>
    </dependency>
</dependencies>
```

## Auto-Instrumentation (Recommended)

Download OpenTelemetry Java Agent:

```bash
wget https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar
```

Run application with agent:

```bash
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.service.name=my-java-app \
  -Dotel.exporter.otlp.endpoint=http://otel-collector:4317 \
  -Dotel.resource.attributes=deployment.environment=production \
  -jar myapp.jar
```

## Manual Instrumentation

```java
// OpenTelemetryConfig.java
package com.example.demo.config;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.propagation.ContextPropagators;
import io.opentelemetry.exporter.otlp.trace.OtlpGrpcSpanExporter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.BatchSpanProcessor;
import io.opentelemetry.semconv.resource.attributes.ResourceAttributes;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenTelemetryConfig {

    @Value("${otel.exporter.otlp.endpoint:http://otel-collector:4317}")
    private String otlpEndpoint;

    @Value("${otel.service.name:my-java-app}")
    private String serviceName;

    @Bean
    public OpenTelemetry openTelemetry() {
        Resource resource = Resource.create(
            Attributes.builder()
                .put(ResourceAttributes.SERVICE_NAME, serviceName)
                .put(ResourceAttributes.SERVICE_VERSION, "1.0.0")
                .put("deployment.environment", "production")
                .build()
        );

        OtlpGrpcSpanExporter spanExporter = OtlpGrpcSpanExporter.builder()
            .setEndpoint(otlpEndpoint)
            .build();

        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
            .addSpanProcessor(BatchSpanProcessor.builder(spanExporter).build())
            .setResource(resource)
            .build();

        return OpenTelemetrySdk.builder()
            .setTracerProvider(tracerProvider)
            .setPropagators(ContextPropagators.create(W3CTraceContextPropagator.getInstance()))
            .buildAndRegisterGlobal();
    }
}

// UserController.java
package com.example.demo.controller;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api")
public class UserController {

    private final Tracer tracer;

    @Autowired
    public UserController(OpenTelemetry openTelemetry) {
        this.tracer = openTelemetry.getTracer("example-app");
    }

    @GetMapping("/users")
    public List<String> getUsers() {
        Span span = tracer.spanBuilder("get_users").startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            // Add custom attributes
            span.setAttribute("http.route", "/api/users");
            span.setAttribute("user.count", 10);

            // Simulate DB query
            fetchFromDatabase();

            return List.of("Alice", "Bob", "Charlie");
        } finally {
            span.end();
        }
    }

    private void fetchFromDatabase() {
        Span dbSpan = tracer.spanBuilder("db.query.users").startSpan();
        
        try (Scope scope = dbSpan.makeCurrent()) {
            dbSpan.setAttribute("db.system", "postgresql");
            dbSpan.setAttribute("db.name", "userdb");
            dbSpan.setAttribute("db.statement", "SELECT * FROM users");
            
            // Simulate query
            Thread.sleep(50);
        } catch (InterruptedException e) {
            dbSpan.recordException(e);
            throw new RuntimeException(e);
        } finally {
            dbSpan.end();
        }
    }
}
```

## Dockerfile

```dockerfile
FROM maven:3.9-eclipse-temurin-17 AS builder

WORKDIR /app
COPY pom.xml .
COPY src ./src

RUN mvn clean package -DskipTests

FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# Copy OTel Java agent
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar /app/

COPY --from=builder /app/target/*.jar app.jar

ENV JAVA_OPTS="-javaagent:/app/opentelemetry-javaagent.jar"

EXPOSE 8080

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

## application.properties

```properties
otel.service.name=my-java-app
otel.exporter.otlp.endpoint=http://otel-collector:4317
otel.resource.attributes=deployment.environment=production

# Optional: customize sampling
otel.traces.sampler=traceidratio
otel.traces.sampler.arg=0.1
```

## Kubernetes Deployment Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: java-app
  template:
    metadata:
      labels:
        app: java-app
    spec:
      containers:
      - name: app
        image: myregistry/java-app:latest
        env:
        - name: OTEL_SERVICE_NAME
          value: "my-java-app"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector.observability.svc.cluster.local:4317"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=production,service.version=1.0.0"
        ports:
        - containerPort: 8080
```
