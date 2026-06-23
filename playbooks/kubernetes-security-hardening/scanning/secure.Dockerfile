# secure.Dockerfile
# Contoh Dockerfile yang aman menggunakan prinsip:
# 1. Multi-stage build (kurangi attack surface)
# 2. Non-root user
# 3. Minimal base image (distroless)
# 4. Tidak ada unnecessary packages
# 5. Verifikasi checksums

## === Stage 1: Build ===
FROM golang:1.22-alpine AS builder

# Install hanya dependency yang diperlukan untuk build
RUN apk add --no-cache git ca-certificates tzdata && \
    update-ca-certificates

# Buat user non-root untuk build (best practice)
RUN adduser -D -g '' appuser

WORKDIR /build

# Copy go modules dulu (layer caching optimization)
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source code
COPY . .

# Build binary yang fully static (tidak butuh libc)
RUN CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    go build \
    -ldflags='-w -s -extldflags "-static"' \
    -a \
    -o /build/app \
    ./cmd/server

## === Stage 2: Runtime (Distroless) ===
# gcr.io/distroless/static: TANPA shell, TANPA package manager
# Sangat kecil, sangat aman
FROM gcr.io/distroless/static:nonroot

# Salin certificates untuk HTTPS calls
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Salin binary dari build stage
COPY --from=builder /build/app /app

# JANGAN jalankan sebagai root!
# nonroot user di distroless = UID 65532
USER nonroot:nonroot

# Expose port > 1024 (non-privileged)
EXPOSE 8080

# Entrypoint langsung ke binary (tidak via shell)
ENTRYPOINT ["/app"]

# === CATATAN KEAMANAN ===
# 1. Tidak ada shell di final image (distroless) - cegah RCE via shell
# 2. Tidak ada package manager - tidak bisa install tools exploit
# 3. User nonroot (UID 65532) - tidak bisa escalate ke root
# 4. Binary static - tidak ada dependency runtime
# 5. Scan image ini dengan: trivy image <image-name>
