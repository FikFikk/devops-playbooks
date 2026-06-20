# Example: Node.js Application with OpenTelemetry

## Dependencies

```bash
npm install --save \
  @opentelemetry/api \
  @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc
```

## Code Example (Express)

```javascript
// tracing.js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'my-node-app',
    [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
    'deployment.environment': process.env.NODE_ENV || 'development',
  }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://otel-collector:4317',
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('Tracing terminated'))
    .catch((error) => console.log('Error terminating tracing', error))
    .finally(() => process.exit(0));
});

module.exports = sdk;

// app.js
require('./tracing'); // Must be first!

const express = require('express');
const { trace, context } = require('@opentelemetry/api');

const app = express();
const tracer = trace.getTracer('example-app');

app.get('/api/users', async (req, res) => {
  const span = trace.getActiveSpan();
  
  // Add custom attributes
  span?.setAttribute('user.count', 10);
  span?.setAttribute('http.route', '/api/users');

  // Create custom child span
  await tracer.startActiveSpan('fetch_users_from_db', async (dbSpan) => {
    try {
      dbSpan.setAttribute('db.system', 'postgresql');
      dbSpan.setAttribute('db.operation', 'SELECT');
      
      // Simulate DB query
      await new Promise(resolve => setTimeout(resolve, 50));
      
      dbSpan.setStatus({ code: 1 }); // OK
    } finally {
      dbSpan.end();
    }
  });

  res.json({ users: ['Alice', 'Bob'] });
});

app.listen(3000, () => {
  console.log('Server listening on port 3000');
});
```

## Environment Variables

```bash
export OTEL_SERVICE_NAME="my-node-service"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4317"
export NODE_ENV="production"
```

## Dockerfile

```dockerfile
FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY . .

EXPOSE 3000
CMD ["node", "app.js"]
```

## package.json

```json
{
  "name": "otel-node-example",
  "version": "1.0.0",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "@opentelemetry/api": "^1.7.0",
    "@opentelemetry/sdk-node": "^0.45.0",
    "@opentelemetry/auto-instrumentations-node": "^0.39.0",
    "@opentelemetry/exporter-trace-otlp-grpc": "^0.45.0"
  }
}
```
