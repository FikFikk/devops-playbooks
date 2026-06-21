FROM node:18-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci --only=production

# Copy application
COPY app.js ./

# Run as non-root user
RUN adduser -D -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Environment variables
ENV VAULT_ADDR=http://vault.vault.svc.cluster.local:8200
ENV VAULT_AUTH_METHOD=kubernetes
ENV VAULT_ROLE=myapp

CMD ["node", "app.js"]
