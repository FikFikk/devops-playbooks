FROM golang:1.21-alpine AS builder

WORKDIR /app

# Install dependencies
COPY go.mod go.sum ./
RUN go mod download

# Copy source
COPY main.go ./

# Build
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o app .

# Runtime image
FROM alpine:latest

RUN apk --no-cache add ca-certificates
WORKDIR /root/

# Copy binary
COPY --from=builder /app/app .

# Run as non-root user
RUN adduser -D -u 1000 appuser && chown appuser:appuser /root/app
USER appuser

# Environment variables
ENV VAULT_ADDR=http://vault.vault.svc.cluster.local:8200
ENV VAULT_AUTH_METHOD=kubernetes
ENV VAULT_ROLE=myapp

CMD ["./app"]
