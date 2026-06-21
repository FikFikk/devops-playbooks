FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY app.py .

# Run as non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Environment variables (override via Kubernetes)
ENV VAULT_ADDR=http://vault.vault.svc.cluster.local:8200
ENV VAULT_AUTH_METHOD=kubernetes
ENV VAULT_ROLE=myapp

CMD ["python", "app.py"]
