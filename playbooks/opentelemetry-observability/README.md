# OpenTelemetry Observability Stack

## Pengantar

OpenTelemetry (OTel) adalah framework observability cloud-native yang menyediakan standar terbuka untuk collection, processing, dan export telemetry data (traces, metrics, logs). Proyek ini merupakan merger dari OpenTracing dan OpenCensus, dan kini menjadi standar de facto untuk observability modern.

## Masalah yang Diselesaikan

### 1. **Vendor Lock-in**
Solusi observability proprietary (Datadog, New Relic, Dynatrace) menciptakan ketergantungan vendor yang mahal dan sulit untuk migrasi.

### 2. **Fragmentasi Data**
Tim sering menggunakan tool berbeda untuk tracing (Jaeger), metrics (Prometheus), dan logging (ELK) yang tidak terintegrasi, menyulitkan correlation dan troubleshooting.

### 3. **Biaya Tinggi**
SaaS observability bisa mencapai $50-500/host/bulan. Untuk 100+ servers, ini berarti $60K-600K/tahun.

### 4. **Lack of Context**
Tanpa distributed tracing, debugging microservices adalah nightmare — sulit melacak request flow lintas service.

### 5. **Instrumentation Hell**
Setiap library/framework butuh instrumentasi berbeda, dan migrasi vendor = re-instrumentation seluruh codebase.

## Solusi: OpenTelemetry Stack

OpenTelemetry + backend open-source (Tempo, Prometheus, Loki) memberikan:
- **Portabilitas**: Tukar backend tanpa ubah code
- **Standarisasi**: Satu SDK untuk semua telemetry signals
- **Cost-Effective**: Self-hosted dengan total cost ~$5K-15K/tahun (infra only)
- **Full Context**: Korelasi traces-metrics-logs dalam satu dashboard
- **Auto-instrumentation**: Zero-code instrumentation untuk banyak framework

---

## Arsitektur Sistem

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  App A   │  │  App B   │  │  App C   │  │  App D   │   │
│  │ (Python) │  │  (Go)    │  │ (Node.js)│  │  (Java)  │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       │ OTel SDK    │ OTel SDK    │ OTel SDK    │ OTel SDK│
│       └─────────────┴─────────────┴─────────────┘          │
└───────────────────────┬─────────────────────────────────────┘
                        │ OTLP (gRPC/HTTP)
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              OpenTelemetry Collector                         │
│  ┌────────────┐  ┌───────────┐  ┌────────────┐            │
│  │ Receivers  │→ │ Processors│→ │ Exporters  │            │
│  │ (OTLP)     │  │ (batch,   │  │ (Tempo,    │            │
│  │            │  │  filter)  │  │  Prom,     │            │
│  └────────────┘  └───────────┘  │  Loki)     │            │
│                                  └────────────┘            │
└────────────┬──────────────┬──────────────┬─────────────────┘
             │              │              │
             ▼              ▼              ▼
┌─────────────┐  ┌──────────────┐  ┌──────────────┐
│   Grafana   │  │  Prometheus  │  │   Grafana    │
│   Tempo     │  │  (Metrics)   │  │     Loki     │
│  (Traces)   │  └──────────────┘  │    (Logs)    │
└─────────────┘                     └──────────────┘
             │              │              │
             └──────────────┴──────────────┘
                        │
                        ▼
             ┌──────────────────────┐
             │   Grafana Dashboard  │
             │  (Unified Interface) │
             └──────────────────────┘
```

### Komponen Utama

1. **OpenTelemetry SDK**: Library yang di-embed di aplikasi untuk generate telemetry
2. **OTel Collector**: Agent/gateway untuk receive, process, export telemetry
3. **Grafana Tempo**: Backend untuk distributed tracing (alternatif Jaeger)
4. **Prometheus**: Time-series database untuk metrics
5. **Grafana Loki**: Log aggregation (seperti ELK tapi lebih lightweight)
6. **Grafana**: Unified dashboard untuk visualisasi

---

## Implementasi Step-by-Step

### Prerequisites

- Kubernetes cluster (minimal 3 nodes, 8GB RAM/node) ATAU
- Docker Compose untuk local/single-server setup
- kubectl & helm (untuk K8s deployment)
- Domain/subdomain untuk Grafana (optional tapi recommended)

### 1. Deploy OpenTelemetry Collector

#### Option A: Kubernetes (Recommended untuk Production)

```bash
# Install cert-manager (required untuk OTel Operator)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Install OpenTelemetry Operator
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.91.0/opentelemetry-operator.yaml

# Deploy collector
kubectl apply -f otel-collector-k8s.yaml
```

Lihat `otel-collector-k8s.yaml` untuk konfigurasi lengkap.

#### Option B: Docker Compose (Development/Testing)

```bash
# Clone repo ini dan masuk ke folder
cd playbooks/opentelemetry-observability/

# Start stack
docker-compose up -d

# Verify
docker-compose ps
```

Lihat `docker-compose.yaml` untuk setup lengkap.

### 2. Deploy Backend Storage

#### Grafana Tempo (Traces)

```bash
# Helm install
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install tempo grafana/tempo \
  --namespace observability \
  --create-namespace \
  -f tempo-values.yaml

# Verify
kubectl get pods -n observability | grep tempo
```

#### Prometheus (Metrics)

```bash
# Install Prometheus Operator (includes Grafana)
helm install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability \
  -f prometheus-values.yaml

# Verify
kubectl get servicemonitor -n observability
```

#### Grafana Loki (Logs)

```bash
helm install loki grafana/loki-stack \
  --namespace observability \
  -f loki-values.yaml

# Verify
kubectl get pods -n observability | grep loki
```

### 3. Instrument Aplikasi

#### Python (Flask/Django/FastAPI)

```python
# requirements.txt
opentelemetry-api==1.21.0
opentelemetry-sdk==1.21.0
opentelemetry-instrumentation-flask==0.42b0
opentelemetry-exporter-otlp==1.21.0

# app.py
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource

# Setup
resource = Resource.create({"service.name": "my-python-app"})
trace.set_tracer_provider(TracerProvider(resource=resource))

otlp_exporter = OTLPSpanExporter(
    endpoint="http://otel-collector:4317",
    insecure=True
)
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(otlp_exporter)
)

# Auto-instrument Flask
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

# Manual span example
tracer = trace.get_tracer(__name__)

@app.route("/api/data")
def get_data():
    with tracer.start_as_current_span("fetch_database"):
        data = db.query("SELECT * FROM users")
        
        # Add custom attributes
        span = trace.get_current_span()
        span.set_attribute("db.rows", len(data))
        span.set_attribute("user.id", current_user.id)
        
    return jsonify(data)
```

Lihat `instrumentation-examples/` untuk bahasa lain (Go, Node.js, Java).

#### Auto-Instrumentation di Kubernetes

```yaml
# Annotate pod untuk auto-inject OTel agent
apiVersion: v1
kind: Pod
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-python: "true"
spec:
  containers:
  - name: app
    image: myapp:latest
    env:
    - name: OTEL_SERVICE_NAME
      value: "my-service"
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: "http://otel-collector:4317"
```

### 4. Setup Grafana Dashboard

```bash
# Forward Grafana port
kubectl port-forward -n observability svc/prometheus-stack-grafana 3000:80

# Login (default admin/prom-operator)
# Buka http://localhost:3000
```

**Tambah Data Sources:**

1. Tempo: `http://tempo:3100`
2. Prometheus: `http://prometheus-operated:9090`
3. Loki: `http://loki:3100`

**Import Dashboards:**
- Dashboard ID 15983 (OpenTelemetry APM)
- Dashboard ID 13639 (Kubernetes Monitoring)
- Dashboard ID 15141 (Loki Logs)

Atau gunakan pre-configured dashboard di `grafana-dashboards/`.

### 5. Konfigurasi Alerting

#### Prometheus AlertManager Rules

```yaml
# alertrules.yaml
groups:
- name: latency
  rules:
  - alert: HighLatency
    expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 2
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High latency detected on {{ $labels.service_name }}"
      description: "P95 latency is {{ $value }}s (threshold: 2s)"

- name: errors
  rules:
  - alert: HighErrorRate
    expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.05
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Error rate >5% on {{ $labels.service_name }}"
```

Apply dengan:
```bash
kubectl apply -f alertrules.yaml -n observability
```

#### Notifikasi Slack/PagerDuty

Edit ConfigMap `alertmanager-config`:

```yaml
receivers:
- name: 'slack'
  slack_configs:
  - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
    channel: '#alerts'
    title: "Alert: {{ .GroupLabels.alertname }}"
    text: "{{ range .Alerts }}{{ .Annotations.description }}{{ end }}"

route:
  receiver: 'slack'
  routes:
  - match:
      severity: critical
    receiver: 'pagerduty'
```

---

## Best Practices

### 1. **Sampling Strategy**

Jangan trace 100% traffic di production (expensive). Gunakan intelligent sampling:

```yaml
# otel-collector config
processors:
  probabilistic_sampler:
    sampling_percentage: 10  # Sample 10% traffic

  tail_sampling:
    policies:
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}  # Always sample errors
      
      - name: slow-requests
        type: latency
        latency: {threshold_ms: 1000}  # Sample slow requests
      
      - name: probabilistic
        type: probabilistic
        probabilistic: {sampling_percentage: 5}
```

### 2. **Resource Attributes**

Selalu set resource attributes untuk identifikasi service:

```python
Resource.create({
    "service.name": "checkout-service",
    "service.version": "1.2.3",
    "deployment.environment": "production",
    "cloud.provider": "aws",
    "cloud.region": "us-east-1",
    "k8s.cluster.name": "prod-cluster",
    "k8s.namespace.name": "ecommerce"
})
```

### 3. **Semantic Conventions**

Ikuti [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/):

```python
# HTTP spans
span.set_attribute("http.method", "GET")
span.set_attribute("http.url", "https://api.example.com/users/123")
span.set_attribute("http.status_code", 200)
span.set_attribute("http.response.body.size", 1024)

# Database spans
span.set_attribute("db.system", "postgresql")
span.set_attribute("db.name", "userdb")
span.set_attribute("db.statement", "SELECT * FROM users WHERE id = $1")
span.set_attribute("db.operation", "SELECT")

# Custom business logic
span.set_attribute("user.id", user_id)
span.set_attribute("cart.total", cart_total)
span.set_attribute("payment.method", "credit_card")
```

### 4. **Context Propagation**

Pastikan trace context di-propagate antar service:

```python
# Outgoing HTTP request dengan trace context
from opentelemetry.propagate import inject

headers = {}
inject(headers)  # Inject W3C TraceContext headers

response = requests.get(
    "http://downstream-service/api",
    headers=headers
)
```

### 5. **Cardinality Management**

JANGAN gunakan high-cardinality values sebagai label/attribute:

```python
# ❌ BAD - Akan create jutaan metric series
span.set_attribute("user.email", user_email)  
span.set_attribute("request.id", uuid4())

# ✅ GOOD - Low-cardinality attributes
span.set_attribute("user.tier", "premium")  # limited values
span.set_attribute("endpoint", "/api/users")
```

### 6. **Span Naming**

Gunakan nama span yang konsisten dan bermakna:

```python
# ❌ BAD
with tracer.start_as_current_span(f"query_{uuid4()}"):
    ...

# ✅ GOOD
with tracer.start_as_current_span("GET /api/users/:id"):
    ...
```

### 7. **Resource Limits**

Set resource limits untuk OTel Collector:

```yaml
resources:
  limits:
    memory: 2Gi
    cpu: 1000m
  requests:
    memory: 512Mi
    cpu: 200m

# Memory limiter processor
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 1500
    spike_limit_mib: 512
```

---

## Pitfalls to Avoid

### 1. **Forgotten Instrumentation**

**Masalah**: Developer lupa instrument HTTP client libraries, sehingga ada "dark spans" di trace.

**Solusi**: Gunakan auto-instrumentation libraries:
```bash
# Python
pip install opentelemetry-bootstrap
opentelemetry-bootstrap -a install

# Java (via agent)
java -javaagent:opentelemetry-javaagent.jar -jar myapp.jar
```

### 2. **Excessive Spans**

**Masalah**: Terlalu banyak spans (e.g., 1 span per DB query dalam loop) → bloat storage.

**Solusi**: Batch operations dalam 1 span:
```python
# ❌ BAD
for user_id in user_ids:
    with tracer.start_as_current_span(f"fetch_user_{user_id}"):
        fetch_user(user_id)

# ✅ GOOD
with tracer.start_as_current_span("fetch_users_batch"):
    span = trace.get_current_span()
    span.set_attribute("batch.size", len(user_ids))
    results = batch_fetch_users(user_ids)
```

### 3. **Storage Explosion**

**Masalah**: Traces menghabiskan disk dalam beberapa hari.

**Solusi**: 
- Set retention policy di Tempo (default 14 hari):
  ```yaml
  storage:
    trace:
      backend: s3
      s3:
        bucket: tempo-traces
        retention: 168h  # 7 days
  ```
- Gunakan object storage (S3/GCS) untuk long-term storage

### 4. **Lost Context di Async Code**

**Masalah**: Trace context hilang di async/background tasks.

**Solusi**: Propagate context explicitly:
```python
from opentelemetry import context

# Celery/RQ task
@celery_app.task
def process_order(order_id):
    # Restore context from task metadata
    ctx = context.attach(task_context)
    
    with tracer.start_as_current_span("process_order"):
        ...
    
    context.detach(ctx)
```

### 5. **Collector Single Point of Failure**

**Masalah**: Jika collector down, aplikasi nunggu timeout (blocking).

**Solusi**: 
- Deploy collector sebagai DaemonSet (1 per node)
- Set timeout pendek di SDK:
  ```python
  OTLPSpanExporter(
      endpoint="http://localhost:4317",
      timeout=5  # 5 seconds timeout
  )
  ```

### 6. **Mixing Observability Tools**

**Masalah**: Tetap pakai Datadog untuk metrics, Jaeger untuk traces, ELK untuk logs → tidak ada correlation.

**Solusi**: Migrate semua ke OTel stack secara bertahap:
1. Start dengan tracing (paling high-value)
2. Tambah metrics via OTel SDK
3. Terakhir migrate logs ke Loki

### 7. **Sensitive Data di Traces**

**Masalah**: Accidentally log passwords/tokens di span attributes.

**Solusi**: Filter di collector:
```yaml
processors:
  attributes:
    actions:
      - key: http.request.header.authorization
        action: delete
      - key: db.statement
        action: update
        value: "[REDACTED]"
        pattern: "password\\s*=\\s*'[^']*'"
```

---

## Monitoring & Troubleshooting

### Health Checks

```bash
# OTel Collector health
curl http://otel-collector:13133/

# Tempo health
curl http://tempo:3200/ready

# Prometheus targets
kubectl port-forward -n observability svc/prometheus 9090:9090
# Visit http://localhost:9090/targets
```

### Debug Trace Drop

Jika traces tidak muncul di Grafana:

1. **Check Collector logs:**
   ```bash
   kubectl logs -n observability -l app=opentelemetry-collector
   ```

2. **Verify OTLP endpoint:**
   ```bash
   # Test from app pod
   kubectl exec -it my-app-pod -- curl -v http://otel-collector:4317
   ```

3. **Enable debug logging di SDK:**
   ```python
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter
   
   # Add console exporter for debugging
   trace.get_tracer_provider().add_span_processor(
       BatchSpanProcessor(ConsoleSpanExporter())
   )
   ```

4. **Check sampling:**
   - Span bisa di-drop karena sampling. Cek attribute `sampled=true`

### Slow Query Debugging

```promql
# Top 10 slowest endpoints (P99 latency)
topk(10,
  histogram_quantile(0.99,
    rate(http_server_duration_bucket[5m])
  )
) by (http_route)
```

Kemudian query traces di Tempo dengan filter:
```
{http.route="/api/checkout"} && duration > 2s
```

### High Memory Usage

```bash
# Check collector memory
kubectl top pod -n observability | grep otel-collector

# If high, adjust batch processor:
processors:
  batch:
    send_batch_size: 512  # Reduce from 1024
    timeout: 1s
    send_batch_max_size: 1024
```

---

## Cost Estimation

### Self-Hosted OpenTelemetry Stack

**Infrastructure (AWS example):**
- 3x t3.large for K8s control plane: $0.0832/hr × 3 × 730hr = **$182/month**
- 5x t3.xlarge for worker nodes: $0.1664/hr × 5 × 730hr = **$607/month**
- EBS storage (1TB traces): $0.10/GB × 1000 = **$100/month**
- S3 storage (long-term, 5TB): $0.023/GB × 5000 = **$115/month**
- Load Balancer: **$30/month**
- Data transfer (estimate): **$50/month**

**Total: ~$1,084/month atau $13,000/year**

Ini untuk monitoring ~100 services dengan 10M requests/day.

### Managed Alternative (Grafana Cloud)

- Traces: $0.50/GB ingested (50GB/month) = **$300/month**
- Metrics: $8/month per 10K series (100K series) = **$80/month**
- Logs: $0.50/GB ingested (20GB/month) = **$100/month**

**Total: ~$480/month atau $5,760/year**

### SaaS Comparison

- Datadog APM: $31/host/month × 100 = **$3,100/month** ($37K/year)
- New Relic: $0.30/GB ingested × 200GB = **$600/month** ($7.2K/year)
- Lightstep: $0.15/span × 100M spans = **$1,500/month** ($18K/year)

**ROI**: Self-hosted OTel stack saves $24K-44K/year vs SaaS!

---

## Migration Strategy

### Phase 1: Pilot (2-4 minggu)

1. Deploy OTel stack di staging
2. Instrument 2-3 critical services
3. Validate traces/metrics/logs
4. Train team

### Phase 2: Gradual Rollout (1-3 bulan)

1. Instrument semua production services (via auto-instrumentation)
2. Parallel run dengan existing observability (Datadog/New Relic)
3. Compare data quality & coverage
4. Build runbooks & dashboards

### Phase 3: Full Migration (1 bulan)

1. Switch primary observability to OTel
2. Update alerts & on-call workflows
3. Decomission old tools
4. Post-mortem & documentation

---

## Tools & Resources

### Essential Tools

1. **OTel Demo App**: https://opentelemetry.io/docs/demo/
   - Sample microservices app dengan full instrumentation
   
2. **OTel Collector Contrib**: https://github.com/open-telemetry/opentelemetry-collector-contrib
   - 200+ receivers, processors, exporters

3. **Grafana Faro**: https://grafana.com/oss/faro/
   - Real User Monitoring (RUM) via OTel

4. **Tracetest**: https://tracetest.io/
   - Trace-based testing framework

### Learning Resources

- [OpenTelemetry Official Docs](https://opentelemetry.io/docs/)
- [Grafana Observability Guide](https://grafana.com/docs/grafana/latest/fundamentals/intro-observability/)
- [Distributed Tracing in Practice (O'Reilly)](https://www.oreilly.com/library/view/distributed-tracing-in/9781492056638/)
- [OTel Community Slack](https://cloud-native.slack.com)

### Commercial Support

- [Grafana Labs](https://grafana.com/products/cloud/) - Managed Tempo/Loki/Grafana
- [Honeycomb](https://honeycomb.io) - OTel-native observability platform
- [AWS X-Ray](https://aws.amazon.com/xray/) - Supports OTLP ingestion
- [Google Cloud Trace](https://cloud.google.com/trace) - Supports OTLP

---

## Next Steps

1. **Run docker-compose demo**: Deploy lokal untuk explore UI
2. **Instrument sample app**: Tambah OTel SDK ke aplikasi internal
3. **Compare dengan existing tools**: Validasi feature parity
4. **Estimate cost savings**: Hitung ROI untuk production rollout
5. **Plan migration**: Buat timeline & risk mitigation plan

---

## Kesimpulan

OpenTelemetry adalah future of observability. Dengan menstandarkan instrumentation dan menggunakan open-source backend, tim DevOps dapat:

- **Hemat biaya**: $20K-40K/year savings vs SaaS
- **Avoid vendor lock-in**: Swap backend tanpa re-instrumentation
- **Better context**: Unified traces-metrics-logs correlation
- **Community support**: Backed by CNCF dengan 200+ contributors

Trade-off utama adalah operational overhead (manage storage, scaling, upgrades), tapi untuk tim dengan mature DevOps practices, ini sangat manageable dan worthwhile investment.

**Mulai dari mana?** Deploy `docker-compose.yaml` di repo ini, instrument 1 service, dan explore Grafana dashboard. Dalam 1 jam, Anda akan paham kenapa OTel adalah game-changer untuk modern observability.
