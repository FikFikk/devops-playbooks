#!/bin/bash

set -e

echo "======================================"
echo "OpenTelemetry Demo Stack Startup"
echo "======================================"
echo ""

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null; then
    echo "Error: docker-compose not found. Please install docker-compose first."
    exit 1
fi

echo "Starting OpenTelemetry observability stack..."
docker-compose up -d

echo ""
echo "Waiting for services to be ready..."
sleep 10

# Check health
echo ""
echo "Checking service health..."
echo -n "OTel Collector: "
curl -s http://localhost:13133/ > /dev/null && echo "✓ Healthy" || echo "✗ Unhealthy"

echo -n "Prometheus: "
curl -s http://localhost:9090/-/healthy > /dev/null && echo "✓ Healthy" || echo "✗ Unhealthy"

echo -n "Tempo: "
curl -s http://localhost:3200/ready > /dev/null && echo "✓ Healthy" || echo "✗ Unhealthy"

echo -n "Loki: "
curl -s http://localhost:3100/ready > /dev/null && echo "✓ Healthy" || echo "✗ Unhealthy"

echo -n "Grafana: "
curl -s http://localhost:3000/api/health > /dev/null && echo "✓ Healthy" || echo "✗ Unhealthy"

echo -n "Demo App: "
curl -s http://localhost:5000/health > /dev/null && echo "✓ Healthy" || echo "✗ Unhealthy"

echo ""
echo "======================================"
echo "Services Ready!"
echo "======================================"
echo ""
echo "Access Points:"
echo "  Grafana:    http://localhost:3000  (login: admin/admin)"
echo "  Prometheus: http://localhost:9090"
echo "  Demo App:   http://localhost:5000"
echo ""
echo "To view logs:"
echo "  docker-compose logs -f"
echo ""
echo "To stop:"
echo "  docker-compose down"
echo ""
echo "To view traces in Grafana:"
echo "  1. Open http://localhost:3000"
echo "  2. Go to Explore → Select 'Tempo' datasource"
echo "  3. Run TraceQL query: {service.name=\"demo-flask-app\"}"
echo ""
