import os
import random
import time
import logging
from flask import Flask, jsonify, request
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Setup OpenTelemetry
resource = Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "demo-flask-app"),
    "service.version": "1.0.0",
    "deployment.environment": os.getenv("OTEL_RESOURCE_ATTRIBUTES", "docker"),
})

trace.set_tracer_provider(TracerProvider(resource=resource))
tracer = trace.get_tracer(__name__)

# OTLP Exporter
otlp_exporter = OTLPSpanExporter(
    endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317"),
    insecure=True
)

trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(otlp_exporter)
)

# Create Flask app
app = Flask(__name__)

# Auto-instrument Flask
FlaskInstrumentor().instrument_app(app)
RequestsInstrumentor().instrument()

# Simulated database
USERS_DB = [
    {"id": 1, "name": "Alice", "email": "alice@example.com"},
    {"id": 2, "name": "Bob", "email": "bob@example.com"},
    {"id": 3, "name": "Charlie", "email": "charlie@example.com"},
]

ORDERS_DB = [
    {"id": 101, "user_id": 1, "product": "Laptop", "amount": 1200},
    {"id": 102, "user_id": 2, "product": "Mouse", "amount": 25},
    {"id": 103, "user_id": 1, "product": "Keyboard", "amount": 75},
]

def simulate_db_query(query_name, duration_ms=None):
    """Simulate database query with configurable latency"""
    if duration_ms is None:
        duration_ms = random.randint(10, 100)
    
    with tracer.start_as_current_span(f"db.query.{query_name}") as span:
        span.set_attribute("db.system", "postgresql")
        span.set_attribute("db.name", "demo_db")
        span.set_attribute("db.statement", f"SELECT * FROM {query_name}")
        span.set_attribute("db.operation", "SELECT")
        
        time.sleep(duration_ms / 1000.0)
        span.set_attribute("db.rows_returned", len(USERS_DB) if query_name == "users" else len(ORDERS_DB))
        
        logger.info(f"Executed query: {query_name}, duration: {duration_ms}ms")

@app.route("/")
def home():
    with tracer.start_as_current_span("home_page") as span:
        span.set_attribute("http.route", "/")
        logger.info("Home page accessed")
        return jsonify({
            "message": "OpenTelemetry Demo App",
            "endpoints": [
                "/api/users",
                "/api/orders",
                "/api/user/<id>",
                "/api/slow",
                "/api/error"
            ]
        })

@app.route("/api/users")
def get_users():
    with tracer.start_as_current_span("get_users") as span:
        span.set_attribute("http.route", "/api/users")
        span.set_attribute("user.count", len(USERS_DB))
        
        simulate_db_query("users")
        
        logger.info(f"Returning {len(USERS_DB)} users")
        return jsonify(USERS_DB)

@app.route("/api/user/<int:user_id>")
def get_user(user_id):
    with tracer.start_as_current_span("get_user_by_id") as span:
        span.set_attribute("http.route", "/api/user/:id")
        span.set_attribute("user.id", user_id)
        
        simulate_db_query("users", duration_ms=random.randint(20, 80))
        
        user = next((u for u in USERS_DB if u["id"] == user_id), None)
        
        if user:
            span.set_attribute("user.found", True)
            logger.info(f"User {user_id} found: {user['name']}")
            return jsonify(user)
        else:
            span.set_attribute("user.found", False)
            span.set_status(trace.Status(trace.StatusCode.ERROR, "User not found"))
            logger.warning(f"User {user_id} not found")
            return jsonify({"error": "User not found"}), 404

@app.route("/api/orders")
def get_orders():
    with tracer.start_as_current_span("get_orders") as span:
        span.set_attribute("http.route", "/api/orders")
        
        # Simulate fetching orders (with nested span)
        simulate_db_query("orders", duration_ms=random.randint(30, 150))
        
        # Calculate total revenue
        with tracer.start_as_current_span("calculate_revenue") as calc_span:
            total_revenue = sum(order["amount"] for order in ORDERS_DB)
            calc_span.set_attribute("revenue.total", total_revenue)
            logger.info(f"Total revenue calculated: ${total_revenue}")
        
        span.set_attribute("orders.count", len(ORDERS_DB))
        
        return jsonify({
            "orders": ORDERS_DB,
            "total_revenue": total_revenue
        })

@app.route("/api/slow")
def slow_endpoint():
    """Simulates a slow endpoint (>1s) untuk trigger sampling policy"""
    with tracer.start_as_current_span("slow_operation") as span:
        span.set_attribute("http.route", "/api/slow")
        
        # Simulate heavy computation
        duration = random.randint(1000, 3000)
        span.set_attribute("operation.duration_ms", duration)
        
        logger.warning(f"Slow operation started, will take {duration}ms")
        time.sleep(duration / 1000.0)
        
        return jsonify({
            "message": "Slow operation completed",
            "duration_ms": duration
        })

@app.route("/api/error")
def error_endpoint():
    """Simulates error untuk trigger error sampling policy"""
    with tracer.start_as_current_span("error_operation") as span:
        span.set_attribute("http.route", "/api/error")
        
        # Random error
        if random.random() < 0.7:  # 70% chance of error
            error_msg = "Simulated database connection error"
            span.set_status(trace.Status(trace.StatusCode.ERROR, error_msg))
            span.record_exception(Exception(error_msg))
            logger.error(error_msg)
            return jsonify({"error": error_msg}), 500
        else:
            logger.info("Error endpoint succeeded (lucky!)")
            return jsonify({"message": "Success (lucky!)"})

@app.route("/health")
def health():
    """Health check endpoint (tidak perlu tracing)"""
    return jsonify({"status": "healthy"}), 200

if __name__ == "__main__":
    logger.info("Starting Flask app with OpenTelemetry instrumentation")
    app.run(host="0.0.0.0", port=5000, debug=False)
