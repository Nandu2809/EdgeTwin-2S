# Multi-stage production container for EdgeTwin-2S
FROM python:3.11-slim as base

# Prevent Python from writing .pyc files and enable unbuffered logging
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

# Install minimal system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Install pinned Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy repository contents
COPY . .

# Warm up models and verify test suites
RUN python -c "from scripts.ml.predict import warmup; warmup(50); print('EdgeTwin-2S models successfully warmed.')"

# Default container command runs the full pytest test suite
CMD ["pytest", "tests/", "-v"]
