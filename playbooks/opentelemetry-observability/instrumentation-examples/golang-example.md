# Example: Go Application with OpenTelemetry

## Dependencies

```bash
go get go.opentelemetry.io/otel
go get go.opentelemetry.io/otel/sdk/trace
go get go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc
go get go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

## Code Example

```go
package main

import (
    "context"
    "log"
    "net/http"
    "os"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

var tracer = otel.Tracer("example-go-app")

func initTracer() func() {
    ctx := context.Background()

    // OTLP exporter
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")),
        otlptracegrpc.WithInsecure(),
    )
    if err != nil {
        log.Fatal(err)
    }

    // Resource with service info
    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(os.Getenv("OTEL_SERVICE_NAME")),
            semconv.ServiceVersion("1.0.0"),
            attribute.String("environment", "production"),
        ),
    )
    if err != nil {
        log.Fatal(err)
    }

    // Trace provider
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1))),
    )
    otel.SetTracerProvider(tp)

    return func() {
        if err := tp.Shutdown(ctx); err != nil {
            log.Fatal(err)
        }
    }
}

func handler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    
    // Create custom span
    _, span := tracer.Start(ctx, "handle_request")
    defer span.End()

    // Add attributes
    span.SetAttributes(
        attribute.String("http.route", "/api/data"),
        attribute.String("user.id", "123"),
    )

    // Simulate work
    time.Sleep(100 * time.Millisecond)

    w.Write([]byte("Hello, OpenTelemetry!"))
}

func main() {
    cleanup := initTracer()
    defer cleanup()

    // Wrap handler with otelhttp for auto-instrumentation
    http.Handle("/api/data", otelhttp.NewHandler(
        http.HandlerFunc(handler),
        "api_data",
    ))

    log.Println("Server starting on :8080")
    log.Fatal(http.ListenAndServe(":8080", nil))
}
```

## Environment Variables

```bash
export OTEL_SERVICE_NAME="my-go-service"
export OTEL_EXPORTER_OTLP_ENDPOINT="otel-collector:4317"
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production"
```

## Dockerfile

```dockerfile
FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o main .

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/main .

EXPOSE 8080
CMD ["./main"]
```
